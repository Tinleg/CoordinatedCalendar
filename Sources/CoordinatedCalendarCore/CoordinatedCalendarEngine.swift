import EventKit
import Foundation

public final class CoordinatedCalendarEngine: @unchecked Sendable {
    public typealias ProgressHandler = @Sendable (Double, String) -> Void

    public let store: any CalendarEventStore
    private let ledger: MappingLedger
    /// Copies a dry run would re-link, by the copy ID they would be given, so the same dry run reports
    /// them as updated rather than as a deletion plus a creation. Reset at the start of every run.
    private var dryRunRelinks: [String: any StoredEvent] = [:]
    /// Mappings a dry run would move to their event's new start (see `followMovedEvents`), by new ID.
    private var dryRunMoves: [String: EventMapping] = [:]

    public init(store: any CalendarEventStore = EventKitStore(), ledger: MappingLedger) {
        self.store = store
        self.ledger = ledger
    }

    public func requestAccess() async throws -> Bool {
        try await store.requestAccess()
    }

    public func authorizationStatus() -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    public func calendars() -> [CalendarIdentity] {
        store.eventCalendars()
            .map(\.identity)
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    public func calendar(for identityKey: String) -> (any StoredCalendar)? {
        store.eventCalendars().first { $0.identity.stableKey == identityKey }
    }

    /// All events in the window. EventKit matches at most four years per predicate and silently drops the
    /// rest, so this fetches in slices and drops the duplicates of events that span a slice boundary.
    public func events(from start: Date, to end: Date, calendars: [any StoredCalendar]) -> [any StoredEvent] {
        var seen = Set<String>()
        var events: [any StoredEvent] = []
        for slice in Self.fetchSlices(from: start, to: end) {
            for event in store.events(from: slice.start, to: slice.end, in: calendars) {
                let key = "\(event.eventIdentifier ?? event.calendarItemIdentifier)|\(event.startDate.timeIntervalSince1970)"
                if seen.insert(key).inserted {
                    events.append(event)
                }
            }
        }
        return events
    }

    /// Consecutive windows of at most one year covering `start..<end`.
    public static func fetchSlices(from start: Date, to end: Date) -> [(start: Date, end: Date)] {
        let calendar = Calendar(identifier: .gregorian)
        var slices: [(start: Date, end: Date)] = []
        var sliceStart = start
        while sliceStart < end {
            let next = calendar.date(byAdding: .year, value: 1, to: sliceStart) ?? end
            let sliceEnd = min(next, end)
            slices.append((sliceStart, sliceEnd))
            sliceStart = sliceEnd
        }
        return slices
    }

    public func validate(settings: BridgeSettings) throws -> (any StoredCalendar, any StoredCalendar) {
        guard settings.endDate > settings.startDate else { throw BridgeError.dateWindowInvalid }
        guard let sourceKey = settings.sourceCalendarKey else { throw BridgeError.sourceCalendarMissing }
        guard let destinationKey = settings.destinationCalendarKey else { throw BridgeError.destinationCalendarMissing }
        guard sourceKey != destinationKey else { throw BridgeError.sameSourceAndDestination }
        guard let source = calendar(for: sourceKey) else { throw BridgeError.sourceCalendarMissing }
        guard let destination = calendar(for: destinationKey) else { throw BridgeError.destinationCalendarMissing }
        guard destination.allowsContentModifications else {
            throw BridgeError.destinationCalendarReadOnly(destination.identity.displayName)
        }
        return (source, destination)
    }

    public func run(settings: BridgeSettings, progress: ProgressHandler? = nil) async -> SyncResult {
        var result = SyncResult()
        dryRunRelinks = [:]
        dryRunMoves = [:]

        do {
            let (source, destination) = try validate(settings: settings)
            let sourceKey = source.identity.stableKey
            let destinationKey = destination.identity.stableKey
            let allEvents = self.events(from: settings.startDate, to: settings.endDate, calendars: [source]).sorted { $0.startDate < $1.startDate }
            result.scanned = allEvents.count
            // Non-blocking events are treated as absent, so deletion cleanup also removes their existing copies.
            let events = allEvents.filter { event in
                guard let reason = nonBlockingReason(for: event, settings: settings) else { return true }
                result.skipped += 1
                result.previews.append(SyncEventPreview(
                    id: UUID().uuidString,
                    sourceTitle: event.title ?? "Untitled",
                    destinationTitle: nil,
                    startDate: event.startDate,
                    action: .skipDuplicate,
                    message: "Skipped: \(reason)",
                    sourceCalendarName: calendarDisplayName(for: sourceKey),
                    destinationCalendarName: calendarDisplayName(for: destinationKey)
                ))
                return false
            }

            enforceCopyShape(
                sourceCalendarKey: sourceKey,
                destinationCalendarKey: destinationKey,
                destinationCalendar: destination,
                settings: settings,
                result: &result
            )

            if settings.reconcileDeletions {
                reconcileDeletedCopies(
                    sourceEvents: events,
                    sourceCalendarKey: sourceKey,
                    destinationCalendarKey: destinationKey,
                    settings: settings,
                    result: &result
                )
            }

            for (index, sourceEvent) in events.enumerated() {
                if Task.isCancelled {
                    break
                }

                progress?(Double(index) / Double(max(events.count, 1)), sourceEvent.title ?? "Untitled")
                process(
                    sourceEvent: sourceEvent,
                    sourceCalendarKey: sourceKey,
                    destinationCalendarKey: destinationKey,
                    destinationCalendar: destination,
                    settings: settings,
                    result: &result
                )
            }

            if !settings.dryRun {
                try ledger.save()
            }
            progress?(1, "Done")
        } catch {
            result.failed += 1
            result.previews.append(SyncEventPreview(
                id: UUID().uuidString,
                sourceTitle: "CoordinatedCalendar",
                destinationTitle: nil,
                startDate: Date(),
                action: .error,
                message: error.localizedDescription
            ))
        }

        return result
    }

    public func reconcileDeletedCopies(settings: BridgeSettings, progress: ProgressHandler? = nil) async -> SyncResult {
        var result = SyncResult()

        do {
            let (source, destination) = try validate(settings: settings)
            let sourceKey = source.identity.stableKey
            let destinationKey = destination.identity.stableKey
            let events = self.events(from: settings.startDate, to: settings.endDate, calendars: [source]).sorted { $0.startDate < $1.startDate }
            result.scanned = events.count
            progress?(0, "Reconciling deletions")
            reconcileDeletedCopies(
                sourceEvents: events,
                sourceCalendarKey: sourceKey,
                destinationCalendarKey: destinationKey,
                settings: settings,
                result: &result
            )
            if !settings.dryRun {
                try ledger.save()
            }
            progress?(1, "Done")
        } catch {
            result.failed += 1
            result.previews.append(SyncEventPreview(
                id: UUID().uuidString,
                sourceTitle: "CoordinatedCalendar",
                destinationTitle: nil,
                startDate: Date(),
                action: .error,
                message: error.localizedDescription
            ))
        }

        return result
    }

    public func deleteCopies(settings: BridgeSettings, progress: ProgressHandler? = nil) async -> SyncResult {
        var result = SyncResult()

        do {
            let (source, destination) = try validate(settings: settings)
            let sourceKey = source.identity.stableKey
            let destinationKey = destination.identity.stableKey
            let events = self.events(from: settings.startDate, to: settings.endDate, calendars: [source]).sorted { $0.startDate < $1.startDate }
            result.scanned = events.count

            for (index, sourceEvent) in events.enumerated() {
                if Task.isCancelled {
                    break
                }

                progress?(Double(index) / Double(max(events.count, 1)), sourceEvent.title ?? "Untitled")
                deleteDestinationCopy(
                    sourceEvent: sourceEvent,
                    sourceCalendarKey: sourceKey,
                    destinationCalendarKey: destinationKey,
                    settings: settings,
                    result: &result
                )
            }

            if !settings.dryRun {
                try ledger.save()
            }
            progress?(1, "Done")
        } catch {
            result.failed += 1
            result.previews.append(SyncEventPreview(
                id: UUID().uuidString,
                sourceTitle: "CoordinatedCalendar",
                destinationTitle: nil,
                startDate: Date(),
                action: .error,
                message: error.localizedDescription
            ))
        }

        return result
    }

    /// The window "remove everything" covers: far enough back and ahead to include any copy a sync could
    /// have made. It is fetched in one-year slices like every other window.
    public static func removalWindow(now: Date = Date()) -> (start: Date, end: Date) {
        let calendar = Calendar(identifier: .gregorian)
        return (
            calendar.date(byAdding: .year, value: -10, to: now) ?? now,
            calendar.date(byAdding: .year, value: 10, to: now) ?? now
        )
    }

    /// Removes every event this app created, in every writable calendar, and clears the ledger after a real
    /// run. An event counts as created by the app only when it carries the app's notes marker or the ledger
    /// maps it as a copy; nothing else is touched.
    public func removeAllCopies(
        from startDate: Date,
        to endDate: Date,
        dryRun: Bool,
        progress: ProgressHandler? = nil
    ) async -> SyncResult {
        var result = SyncResult()
        let calendars = store.eventCalendars().filter(\.allowsContentModifications)

        for (index, calendar) in calendars.enumerated() {
            if Task.isCancelled {
                break
            }
            let identity = calendar.identity
            progress?(Double(index) / Double(max(calendars.count, 1)), identity.displayName)
            var removedSeries = Set<String>()

            for event in events(from: startDate, to: endDate, calendars: [calendar]) {
                result.scanned += 1
                let mapped = event.eventIdentifier.map {
                    ledger.mappingForDestinationEvent(calendarKey: identity.stableKey, eventIdentifier: $0) != nil
                } ?? false
                guard BridgeEventMetadata.parse(from: event.notes) != nil || mapped else {
                    continue
                }
                if event.hasRecurrenceRules {
                    guard removedSeries.insert(event.calendarItemIdentifier).inserted else { continue }
                }
                result.deleted += 1
                result.previews.append(SyncEventPreview(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    sourceTitle: event.title ?? "Untitled",
                    destinationTitle: nil,
                    startDate: event.startDate,
                    action: .delete,
                    message: dryRun ? "Would remove CoordinatedCalendar copy" : "Removed CoordinatedCalendar copy",
                    sourceCalendarName: identity.displayName,
                    destinationCalendarName: nil
                ))
                guard !dryRun else {
                    continue
                }
                do {
                    try store.remove(event, futureEvents: event.hasRecurrenceRules)
                } catch {
                    result.failed += 1
                    result.previews.append(SyncEventPreview(
                        id: event.eventIdentifier ?? UUID().uuidString,
                        sourceTitle: event.title ?? "Untitled",
                        destinationTitle: nil,
                        startDate: event.startDate,
                        action: .error,
                        message: "Removal failed: \(error.localizedDescription)",
                        sourceCalendarName: identity.displayName,
                        destinationCalendarName: nil
                    ))
                }
            }
        }

        if !dryRun, result.failed == 0 {
            ledger.removeAll()
            do {
                try ledger.save()
            } catch {
                result.failed += 1
                result.previews.append(SyncEventPreview(
                    id: UUID().uuidString,
                    sourceTitle: "CoordinatedCalendar",
                    destinationTitle: nil,
                    startDate: Date(),
                    action: .error,
                    message: "Copies were removed, but the ledger could not be cleared: \(error.localizedDescription)"
                ))
            }
        }
        progress?(1, "Done")
        return result
    }

    private func process(
        sourceEvent: any StoredEvent,
        sourceCalendarKey: String,
        destinationCalendarKey: String,
        destinationCalendar: any StoredCalendar,
        settings: BridgeSettings,
        result: inout SyncResult
    ) {
        let sourceTitle = sourceEvent.title ?? "Untitled"
        let sourceCalendarName = calendarDisplayName(for: sourceCalendarKey)
        let destinationCalendarName = calendarDisplayName(for: destinationCalendarKey)
        let originCalendarName = originCalendarName(forSourceEvent: sourceEvent, sourceCalendarKey: sourceCalendarKey)
        let destinationTitle = settings.transform.destinationTitle(
            for: sourceTitle,
            sourceCalendarName: sourceCalendarName,
            originCalendarName: originCalendarName
        )
        let sourceIdentity = BridgeEventMetadata.makeSourceIdentity(
            sourceCalendarName: sourceCalendarName,
            sourceEventExternalIdentifier: sourceEvent.calendarItemExternalIdentifier,
            sourceEventIdentifier: sourceEvent.eventIdentifier,
            sourceStartDate: sourceEvent.startDate
        )
        let copyMode = settings.transform.copyAsFreeBusyOnly ? "freeBusy" : "details"
        let copyID = BridgeEventMetadata.makeCopyID(
            sourceIdentity: sourceIdentity,
            destinationCalendarName: destinationCalendarName,
            copyMode: copyMode
        )
        let transformationSummary = transformationSummary(
            transform: settings.transform,
            sourceTitle: sourceTitle,
            destinationTitle: destinationTitle
        )
        let resultingAvailability = availabilityDisplayName(
            eventAvailability(
                for: settings.transform.destinationAvailability,
                sourceEvent: sourceEvent,
                destinationCalendar: destinationCalendar
            )
        )
        let sourceAvailability = sourceAvailabilityDisplayName(for: sourceEvent)
        let fingerprint = EventFingerprint.fingerprint(
            event: sourceEvent,
            sourceCalendarKey: sourceCalendarKey,
            transform: settings.transform,
            sourceCalendarName: sourceCalendarName,
            originCalendarName: originCalendarName
        )

        if settings.skipBridgeCreatedSourceEvents,
           (ledger.isBridgeCreatedDestination(calendarKey: sourceCalendarKey, eventIdentifier: sourceEvent.eventIdentifier)
            || BridgeEventMetadata.parse(from: sourceEvent.notes) != nil) {
            result.skipped += 1
            result.previews.append(SyncEventPreview(
                id: UUID().uuidString,
                sourceTitle: sourceTitle,
                destinationTitle: nil,
                startDate: sourceEvent.startDate,
                action: .skipDuplicate,
                message: "Skipped CoordinatedCalendar-created event",
                sourceCalendarName: sourceCalendarName,
                destinationCalendarName: destinationCalendarName,
                sourceAvailability: sourceAvailability,
                resultingAvailability: resultingAvailability,
                transformationSummary: transformationSummary
            ))
            return
        }

        if settings.skipWhenSourceOriginMatchesDestination,
           sourceOriginMatchesDestination(sourceEvent: sourceEvent, sourceCalendarKey: sourceCalendarKey, destinationCalendarKey: destinationCalendarKey) {
            result.skipped += 1
            result.previews.append(SyncEventPreview(
                id: UUID().uuidString,
                sourceTitle: sourceTitle,
                destinationTitle: nil,
                startDate: sourceEvent.startDate,
                action: .skipDuplicate,
                message: "Skipped copy back to original calendar",
                sourceCalendarName: sourceCalendarName,
                destinationCalendarName: destinationCalendarName,
                sourceAvailability: sourceAvailability,
                resultingAvailability: resultingAvailability,
                transformationSummary: transformationSummary
            ))
            return
        }

        if let destinationEvent = findExistingCopyBySyncedMetadata(
            copyIDs: [copyID],
            sourceEvent: sourceEvent,
            destinationCalendar: destinationCalendar
        ) ?? (settings.dryRun ? dryRunRelinks[copyID] : nil) {
            let metadata = metadataForCopy(
                copyID: copyID,
                sourceIdentity: sourceIdentity,
                sourceCalendarName: sourceCalendarName,
                destinationCalendarName: destinationCalendarName,
                originCalendarName: originCalendarName ?? sourceCalendarName,
                originCalendarKey: originCalendarKey(forSourceEvent: sourceEvent, fallback: sourceCalendarKey),
                copyMode: copyMode,
                fingerprint: fingerprint,
                sourceEvent: sourceEvent,
                transform: settings.transform
            )
            let existingMetadata = BridgeEventMetadata.parse(from: destinationEvent.notes)

            if existingMetadata?.fingerprint == fingerprint, existingMetadata?.copyID == copyID,
               !needsSourceReference(existingMetadata, copyMode: copyMode) {
                result.skipped += 1
                result.previews.append(SyncEventPreview(
                    id: copyID,
                    sourceTitle: sourceTitle,
                    destinationTitle: destinationEvent.title,
                    startDate: sourceEvent.startDate,
                    action: .skipDuplicate,
                    message: "Already copied on another CoordinatedCalendar host",
                    sourceCalendarName: sourceCalendarName,
                    destinationCalendarName: destinationCalendarName,
                    sourceAvailability: sourceAvailability,
                    resultingAvailability: resultingAvailability,
                    transformationSummary: transformationSummary
                ))
                if !settings.dryRun {
                    upsertLedgerMapping(
                        sourceEvent: sourceEvent,
                        sourceCalendarKey: sourceCalendarKey,
                        destinationCalendarKey: destinationCalendarKey,
                        destinationEvent: destinationEvent,
                        fingerprint: fingerprint,
                        copyMode: copyMode
                    )
                }
                return
            }

            if settings.updateExistingCopies {
                result.updated += 1
                result.previews.append(SyncEventPreview(
                    id: copyID,
                    sourceTitle: sourceTitle,
                    destinationTitle: destinationTitle,
                    startDate: sourceEvent.startDate,
                    action: .update,
                    message: settings.dryRun ? "Would update copy found from synced metadata" : "Updated copy found from synced metadata",
                    sourceCalendarName: sourceCalendarName,
                    destinationCalendarName: destinationCalendarName,
                    sourceAvailability: sourceAvailability,
                    resultingAvailability: resultingAvailability,
                    transformationSummary: transformationSummary
                ))
                if !settings.dryRun {
                    apply(
                        sourceEvent: sourceEvent,
                        to: destinationEvent,
                        destinationCalendar: destinationCalendar,
                        transform: settings.transform,
                        sourceCalendarName: sourceCalendarName,
                        originCalendarName: originCalendarName,
                        metadata: metadata
                    )
                    do {
                        try store.save(destinationEvent)
                        upsertLedgerMapping(
                            sourceEvent: sourceEvent,
                            sourceCalendarKey: sourceCalendarKey,
                            destinationCalendarKey: destinationCalendarKey,
                            destinationEvent: destinationEvent,
                            fingerprint: fingerprint,
                            copyMode: copyMode
                        )
                    } catch {
                        result.failed += 1
                        result.previews.append(SyncEventPreview(
                            id: UUID().uuidString,
                            sourceTitle: sourceTitle,
                            destinationTitle: destinationTitle,
                            startDate: sourceEvent.startDate,
                            action: .error,
                            message: "Update failed: \(error.localizedDescription)",
                            sourceCalendarName: sourceCalendarName,
                            destinationCalendarName: destinationCalendarName
                        ))
                    }
                }
            } else {
                result.blocked += 1
                result.previews.append(SyncEventPreview(
                    id: copyID,
                    sourceTitle: sourceTitle,
                    destinationTitle: destinationEvent.title,
                    startDate: sourceEvent.startDate,
                    action: .blocked,
                    message: BridgeError.existingCopyNeedsUpdate(sourceTitle).localizedDescription,
                    sourceCalendarName: sourceCalendarName,
                    destinationCalendarName: destinationCalendarName,
                    sourceAvailability: sourceAvailability,
                    resultingAvailability: resultingAvailability,
                    transformationSummary: transformationSummary
                ))
            }
            return
        }

        if let existing = ledger.mapping(
            sourceCalendarKey: sourceCalendarKey,
            destinationCalendarKey: destinationCalendarKey,
            sourceEventIdentifier: sourceEvent.eventIdentifier,
            sourceStartDate: sourceEvent.startDate
        ) ?? (settings.dryRun ? dryRunMoves[EventMapping.makeID(
            sourceCalendarKey: sourceCalendarKey,
            destinationCalendarKey: destinationCalendarKey,
            sourceEventIdentifier: sourceEvent.eventIdentifier,
            sourceStartDate: sourceEvent.startDate
        )] : nil) {
            guard let destinationEvent = store.event(withIdentifier: existing.destinationEventIdentifier) else {
                appendCreatePreview(
                    sourceEvent: sourceEvent,
                    destinationTitle: destinationTitle,
                    sourceCalendarName: sourceCalendarName,
                    destinationCalendarName: destinationCalendarName,
                    sourceAvailability: sourceAvailability,
                    resultingAvailability: resultingAvailability,
                    transformationSummary: transformationSummary,
                    result: &result
                )
                if !settings.dryRun {
                    createCopy(
                        sourceEvent: sourceEvent,
                        sourceCalendarKey: sourceCalendarKey,
                        destinationCalendarKey: destinationCalendarKey,
                        destinationCalendar: destinationCalendar,
                        fingerprint: fingerprint,
                        sourceCalendarName: sourceCalendarName,
                        originCalendarName: originCalendarName,
                        copyID: copyID,
                        sourceIdentity: sourceIdentity,
                        settings: settings,
                        result: &result
                    )
                }
                return
            }

            if existing.fingerprint == fingerprint {
                let storedMetadata = BridgeEventMetadata.parse(from: destinationEvent.notes)
                if storedMetadata?.copyID != copyID || needsSourceReference(storedMetadata, copyMode: copyMode) {
                    result.updated += 1
                    result.previews.append(SyncEventPreview(
                        id: existing.id,
                        sourceTitle: sourceTitle,
                        destinationTitle: destinationTitle,
                        startDate: sourceEvent.startDate,
                        action: .update,
                        message: settings.dryRun ? "Would refresh CoordinatedCalendar metadata" : "Refreshed CoordinatedCalendar metadata",
                        sourceCalendarName: sourceCalendarName,
                        destinationCalendarName: destinationCalendarName,
                        sourceAvailability: sourceAvailability,
                        resultingAvailability: resultingAvailability,
                        transformationSummary: transformationSummary
                    ))
                    if !settings.dryRun {
                        apply(
                            sourceEvent: sourceEvent,
                            to: destinationEvent,
                            destinationCalendar: destinationCalendar,
                            transform: settings.transform,
                            sourceCalendarName: sourceCalendarName,
                            originCalendarName: originCalendarName,
                            metadata: metadataForCopy(
                                copyID: copyID,
                                sourceIdentity: sourceIdentity,
                                sourceCalendarName: sourceCalendarName,
                                destinationCalendarName: destinationCalendarName,
                                originCalendarName: originCalendarName ?? sourceCalendarName,
                                originCalendarKey: originCalendarKey(forSourceEvent: sourceEvent, fallback: sourceCalendarKey),
                                copyMode: copyMode,
                                fingerprint: fingerprint,
                                sourceEvent: sourceEvent,
                                transform: settings.transform
                            )
                        )
                        do {
                            try store.save(destinationEvent)
                            var updated = existing
                            updated.updatedAt = Date()
                            ledger.upsert(updated)
                        } catch {
                            result.failed += 1
                            result.previews.append(SyncEventPreview(
                                id: UUID().uuidString,
                                sourceTitle: sourceTitle,
                                destinationTitle: destinationTitle,
                                startDate: sourceEvent.startDate,
                                action: .error,
                                message: "Update failed: \(error.localizedDescription)",
                                sourceCalendarName: sourceCalendarName,
                                destinationCalendarName: destinationCalendarName
                            ))
                        }
                    }
                    return
                }

                result.skipped += 1
                result.previews.append(SyncEventPreview(
                    id: existing.id,
                    sourceTitle: sourceTitle,
                    destinationTitle: destinationEvent.title,
                    startDate: sourceEvent.startDate,
                    action: .skipDuplicate,
                    message: "Already copied",
                    sourceCalendarName: sourceCalendarName,
                    destinationCalendarName: destinationCalendarName,
                    sourceAvailability: sourceAvailability,
                    resultingAvailability: resultingAvailability,
                    transformationSummary: transformationSummary
                ))
                return
            }

            if settings.updateExistingCopies {
                result.updated += 1
                result.previews.append(SyncEventPreview(
                    id: existing.id,
                    sourceTitle: sourceTitle,
                    destinationTitle: destinationTitle,
                    startDate: sourceEvent.startDate,
                    action: .update,
                    message: settings.dryRun ? "Would update previous copy" : "Updated previous copy",
                    sourceCalendarName: sourceCalendarName,
                    destinationCalendarName: destinationCalendarName,
                    sourceAvailability: sourceAvailability,
                    resultingAvailability: resultingAvailability,
                    transformationSummary: transformationSummary
                ))
                if !settings.dryRun {
                    apply(
                        sourceEvent: sourceEvent,
                        to: destinationEvent,
                        destinationCalendar: destinationCalendar,
                        transform: settings.transform,
                        sourceCalendarName: sourceCalendarName,
                        originCalendarName: originCalendarName,
                        metadata: metadataForCopy(
                            copyID: copyID,
                            sourceIdentity: sourceIdentity,
                            sourceCalendarName: sourceCalendarName,
                            destinationCalendarName: destinationCalendarName,
                            originCalendarName: originCalendarName ?? sourceCalendarName,
                            originCalendarKey: originCalendarKey(forSourceEvent: sourceEvent, fallback: sourceCalendarKey),
                            copyMode: copyMode,
                            fingerprint: fingerprint,
                            sourceEvent: sourceEvent,
                            transform: settings.transform
                        )
                    )
                    do {
                        try store.save(destinationEvent)
                        var updated = existing
                        updated.fingerprint = fingerprint
                        updated.sourceLastModifiedDate = sourceEvent.lastModifiedDate
                        updated.updatedAt = Date()
                        ledger.upsert(updated)
                    } catch {
                        result.failed += 1
                        result.previews.append(SyncEventPreview(
                            id: UUID().uuidString,
                            sourceTitle: sourceTitle,
                            destinationTitle: destinationTitle,
                            startDate: sourceEvent.startDate,
                            action: .error,
                            message: "Update failed: \(error.localizedDescription)",
                            sourceCalendarName: sourceCalendarName,
                            destinationCalendarName: destinationCalendarName
                        ))
                    }
                }
            } else {
                result.blocked += 1
                result.previews.append(SyncEventPreview(
                    id: existing.id,
                    sourceTitle: sourceTitle,
                    destinationTitle: destinationEvent.title,
                    startDate: sourceEvent.startDate,
                    action: .blocked,
                    message: BridgeError.existingCopyNeedsUpdate(sourceTitle).localizedDescription,
                    sourceCalendarName: sourceCalendarName,
                    destinationCalendarName: destinationCalendarName,
                    sourceAvailability: sourceAvailability,
                    resultingAvailability: resultingAvailability,
                    transformationSummary: transformationSummary
                ))
            }
            return
        }

        appendCreatePreview(
            sourceEvent: sourceEvent,
            destinationTitle: destinationTitle,
            sourceCalendarName: sourceCalendarName,
            destinationCalendarName: destinationCalendarName,
            sourceAvailability: sourceAvailability,
            resultingAvailability: resultingAvailability,
            transformationSummary: transformationSummary,
            result: &result
        )
        if !settings.dryRun {
            createCopy(
                sourceEvent: sourceEvent,
                sourceCalendarKey: sourceCalendarKey,
                destinationCalendarKey: destinationCalendarKey,
                destinationCalendar: destinationCalendar,
                fingerprint: fingerprint,
                sourceCalendarName: sourceCalendarName,
                originCalendarName: originCalendarName,
                copyID: copyID,
                sourceIdentity: sourceIdentity,
                settings: settings,
                result: &result
            )
        }
    }

    /// Cleans up this route's existing copies before the sync: removes duplicate copies of the same source
    /// event (which two Macs can create before their calendars sync), removes recurring copies so the sync
    /// recreates them as single occurrences, and strips free/busy copies down to what FreeBusyCompliance
    /// allows. Only events carrying this route's CoordinatedCalendar marker are touched.
    private func enforceCopyShape(
        sourceCalendarKey: String,
        destinationCalendarKey: String,
        destinationCalendar: any StoredCalendar,
        settings: BridgeSettings,
        result: inout SyncResult
    ) {
        let sourceCalendarName = calendarDisplayName(for: sourceCalendarKey)
        let destinationCalendarName = calendarDisplayName(for: destinationCalendarKey)
        let freeBusy = settings.transform.copyAsFreeBusyOnly
        let copyMode = freeBusy ? "freeBusy" : "details"
        let expectedTitle = settings.transform.includeOriginCalendarInFreeBusyTitle
            ? nil
            : settings.transform.destinationTitle(for: "")
        var removedSeries = Set<String>()
        let routeCopies: [(event: any StoredEvent, metadata: BridgeEventMetadata)] = events(
            from: settings.startDate,
            to: settings.endDate,
            calendars: [destinationCalendar]
        )
        .sorted(by: { $0.startDate < $1.startDate })
        .compactMap { event in
            guard let metadata = BridgeEventMetadata.parse(from: event.notes),
                  metadata.copyMode == copyMode,
                  BridgeEventMetadata.storedName(metadata.sourceCalendarName, matches: sourceCalendarName),
                  BridgeEventMetadata.storedName(metadata.destinationCalendarName, matches: destinationCalendarName)
            else {
                return nil
            }
            return (event, metadata)
        }

        let duplicates = Self.duplicateCopies(in: routeCopies.filter { !$0.event.hasRecurrenceRules }.map { copy in
            DuplicateCandidate(
                copyID: copy.metadata.copyID,
                creationDate: copy.event.creationDate,
                externalIdentifier: copy.event.calendarItemExternalIdentifier,
                eventIdentifier: copy.event.eventIdentifier ?? copy.event.calendarItemIdentifier
            )
        })
        for (event, metadata) in routeCopies
        where duplicates.contains(event.eventIdentifier ?? event.calendarItemIdentifier) {
            result.deleted += 1
            result.previews.append(SyncEventPreview(
                id: metadata.copyID,
                sourceTitle: event.title ?? "Untitled",
                destinationTitle: event.title,
                startDate: event.startDate,
                action: .delete,
                message: settings.dryRun
                    ? "Would remove duplicate copy (another copy of the same source event is kept)"
                    : "Removed duplicate copy (another copy of the same source event is kept)",
                sourceCalendarName: sourceCalendarName,
                destinationCalendarName: destinationCalendarName
            ))
            guard !settings.dryRun else {
                continue
            }
            do {
                try store.remove(event, futureEvents: false)
            } catch {
                result.failed += 1
                result.previews.append(SyncEventPreview(
                    id: metadata.copyID,
                    sourceTitle: event.title ?? "Untitled",
                    destinationTitle: nil,
                    startDate: event.startDate,
                    action: .error,
                    message: "Duplicate removal failed: \(error.localizedDescription)",
                    sourceCalendarName: sourceCalendarName,
                    destinationCalendarName: destinationCalendarName
                ))
            }
        }

        for (event, metadata) in routeCopies
        where !duplicates.contains(event.eventIdentifier ?? event.calendarItemIdentifier) {
            var violations = freeBusy
                ? FreeBusyCompliance.violations(of: event, expectedTitle: expectedTitle)
                : (event.hasRecurrenceRules ? ["recurrence"] : [])
            // An alert can arrive after the copy was made: some accounts add a default one to every new
            // event. The fingerprint covers only the source, so this is checked on the copy itself.
            if !freeBusy, !settings.transform.copyAlarms, !(event.alarms ?? []).isEmpty {
                violations.append("alerts")
            }
            if metadata.hasPlainCalendarNames {
                // Markers from before calendar names were hashed; rewriting the notes hashes them.
                violations.append("marker")
            }
            guard !violations.isEmpty else {
                continue
            }

            let recurring = event.hasRecurrenceRules
            if recurring {
                guard removedSeries.insert(event.calendarItemIdentifier).inserted else {
                    continue
                }
                result.deleted += 1
            } else {
                result.updated += 1
            }
            let stripped = violations.joined(separator: ", ")
            let message = recurring
                ? (settings.dryRun ? "Would remove recurring copy (\(stripped)) for single-occurrence recreation" : "Removed recurring copy (\(stripped)) for single-occurrence recreation")
                : freeBusy
                    ? (settings.dryRun ? "Would strip free/busy copy: \(stripped)" : "Stripped free/busy copy: \(stripped)")
                    : (settings.dryRun ? "Would rewrite copy: \(stripped)" : "Rewrote copy: \(stripped)")
            result.previews.append(SyncEventPreview(
                id: metadata.copyID,
                sourceTitle: event.title ?? "Untitled",
                destinationTitle: freeBusy ? (expectedTitle ?? event.title) : event.title,
                startDate: event.startDate,
                action: recurring ? .delete : .update,
                message: message,
                sourceCalendarName: sourceCalendarName,
                destinationCalendarName: destinationCalendarName
            ))

            guard !settings.dryRun else {
                continue
            }

            do {
                if recurring {
                    try store.remove(event, futureEvents: true)
                } else if freeBusy {
                    FreeBusyCompliance.strip(event, metadata: metadata, expectedTitle: expectedTitle)
                    if settings.transform.markFreeBusyEventsPrivate {
                        event.markPrivateIfSupported()
                    }
                    try store.save(event)
                } else {
                    if violations.contains("alerts") {
                        event.alarms = nil
                    }
                    event.notes = BridgeEventMetadata.notesByAddingMarker(to: event.notes, metadata: metadata)
                    try store.save(event)
                }
            } catch {
                result.failed += 1
                result.previews.append(SyncEventPreview(
                    id: metadata.copyID,
                    sourceTitle: event.title ?? "Untitled",
                    destinationTitle: nil,
                    startDate: event.startDate,
                    action: .error,
                    message: "Copy cleanup failed: \(error.localizedDescription)",
                    sourceCalendarName: sourceCalendarName,
                    destinationCalendarName: destinationCalendarName
                ))
            }
        }
    }

    public struct DuplicateCandidate: Equatable, Sendable {
        public var copyID: String
        public var creationDate: Date?
        public var externalIdentifier: String?
        public var eventIdentifier: String

        public init(copyID: String, creationDate: Date?, externalIdentifier: String?, eventIdentifier: String) {
            self.copyID = copyID
            self.creationDate = creationDate
            self.externalIdentifier = externalIdentifier
            self.eventIdentifier = eventIdentifier
        }
    }

    /// Event identifiers of surplus copies: for each copy ID with more than one copy, all but the keeper.
    /// Every Mac must pick the same keeper, so it is the earliest created, then the smallest cross-device
    /// identifier, both of which are the same on every Mac once calendars have synced.
    public static func duplicateCopies(in candidates: [DuplicateCandidate]) -> Set<String> {
        var surplus = Set<String>()
        for group in Dictionary(grouping: candidates, by: \.copyID).values where group.count > 1 {
            let ordered = group.sorted { lhs, rhs in
                let lhsDate = lhs.creationDate ?? .distantFuture
                let rhsDate = rhs.creationDate ?? .distantFuture
                if lhsDate != rhsDate {
                    return lhsDate < rhsDate
                }
                return (lhs.externalIdentifier ?? lhs.eventIdentifier) < (rhs.externalIdentifier ?? rhs.eventIdentifier)
            }
            surplus.formUnion(ordered.dropFirst().map(\.eventIdentifier))
        }
        return surplus
    }

    private func reconcileDeletedCopies(
        sourceEvents: [any StoredEvent],
        sourceCalendarKey: String,
        destinationCalendarKey: String,
        settings: BridgeSettings,
        result: inout SyncResult
    ) {
        let sourceCalendarName = calendarDisplayName(for: sourceCalendarKey)
        let destinationCalendarName = calendarDisplayName(for: destinationCalendarKey)
        let copyMode = settings.transform.copyAsFreeBusyOnly ? "freeBusy" : "details"
        let currentMappingIDs = Set(sourceEvents.map {
            EventMapping.makeID(
                sourceCalendarKey: sourceCalendarKey,
                destinationCalendarKey: destinationCalendarKey,
                sourceEventIdentifier: $0.eventIdentifier,
                sourceStartDate: $0.startDate
            )
        })
        let currentSourceIdentities = Set(sourceEvents.map {
            BridgeEventMetadata.makeSourceIdentity(
                sourceCalendarName: sourceCalendarName,
                sourceEventExternalIdentifier: $0.calendarItemExternalIdentifier,
                sourceEventIdentifier: $0.eventIdentifier,
                sourceStartDate: $0.startDate
            )
        })
        let trackedMappings = ledger.mappings(
            sourceCalendarKey: sourceCalendarKey,
            destinationCalendarKey: destinationCalendarKey,
            startDate: settings.startDate,
            endDate: settings.endDate
        )
        var reconciledDestinationIdentifiers = followMovedEvents(
            staleMappings: trackedMappings.filter { !currentMappingIDs.contains($0.id) },
            sourceEvents: sourceEvents,
            settings: settings
        )

        for mapping in trackedMappings where !currentMappingIDs.contains(mapping.id) {
            if reconciledDestinationIdentifiers.contains(mapping.destinationEventIdentifier) {
                continue
            }
            guard let destinationEvent = store.event(withIdentifier: mapping.destinationEventIdentifier) else {
                result.skipped += 1
                result.previews.append(SyncEventPreview(
                    id: mapping.id,
                    sourceTitle: "Deleted source event",
                    destinationTitle: nil,
                    startDate: mapping.sourceStartDate,
                    action: .skipDuplicate,
                    message: settings.dryRun ? "Destination copy is already missing" : "Removed stale mapping for missing destination copy",
                    sourceCalendarName: sourceCalendarName,
                    destinationCalendarName: destinationCalendarName
                ))
                if !settings.dryRun {
                    ledger.remove(id: mapping.id)
                }
                continue
            }
            reconciledDestinationIdentifiers.insert(destinationEvent.eventIdentifier)

            result.deleted += 1
            result.previews.append(SyncEventPreview(
                id: mapping.id,
                sourceTitle: "Deleted source event",
                destinationTitle: destinationEvent.title,
                startDate: mapping.sourceStartDate,
                action: .delete,
                message: settings.dryRun ? "Would delete copy for missing source event" : "Deleted copy for missing source event",
                sourceCalendarName: sourceCalendarName,
                destinationCalendarName: destinationCalendarName
            ))

            guard !settings.dryRun else {
                continue
            }

            do {
                try store.remove(destinationEvent, futureEvents: false)
                ledger.remove(id: mapping.id)
            } catch {
                result.failed += 1
                result.previews.append(SyncEventPreview(
                    id: mapping.id,
                    sourceTitle: "Deleted source event",
                    destinationTitle: destinationEvent.title,
                    startDate: mapping.sourceStartDate,
                    action: .error,
                    message: error.localizedDescription,
                    sourceCalendarName: sourceCalendarName,
                    destinationCalendarName: destinationCalendarName
                ))
            }
        }

        let destinationCalendar = calendar(for: destinationCalendarKey)
        if let destinationCalendar {
            var routeCopyIdentities = Set<String>()
            var orphans: [(event: any StoredEvent, metadata: BridgeEventMetadata)] = []
            for destinationEvent in self.events(from: settings.startDate, to: settings.endDate, calendars: [destinationCalendar]) {
                guard let metadata = BridgeEventMetadata.parse(from: destinationEvent.notes),
                      BridgeEventMetadata.storedName(metadata.sourceCalendarName, matches: sourceCalendarName),
                      BridgeEventMetadata.storedName(metadata.destinationCalendarName, matches: destinationCalendarName),
                      metadata.copyMode == copyMode
                else {
                    continue
                }
                routeCopyIdentities.insert(metadata.sourceIdentity)
                if !reconciledDestinationIdentifiers.contains(destinationEvent.eventIdentifier),
                   !currentSourceIdentities.contains(metadata.sourceIdentity) {
                    orphans.append((destinationEvent, metadata))
                }
            }
            let relinked = relinkOrphanedCopies(
                orphans: orphans,
                sourceEvents: sourceEvents,
                claimedIdentities: routeCopyIdentities,
                sourceCalendarKey: sourceCalendarKey,
                destinationCalendarKey: destinationCalendarKey,
                settings: settings,
                result: &result
            )
            for (destinationEvent, metadata) in orphans where !relinked.contains(destinationEvent.eventIdentifier) {

                result.deleted += 1
                result.previews.append(SyncEventPreview(
                    id: metadata.copyID,
                    sourceTitle: "Deleted source event",
                    destinationTitle: destinationEvent.title,
                    startDate: destinationEvent.startDate,
                    action: .delete,
                    message: settings.dryRun ? "Would delete metadata-tracked copy for missing source event" : "Deleted metadata-tracked copy for missing source event",
                    sourceCalendarName: sourceCalendarName,
                    destinationCalendarName: destinationCalendarName
                ))

                guard !settings.dryRun else {
                    continue
                }

                do {
                    try store.remove(destinationEvent, futureEvents: false)
                } catch {
                    result.failed += 1
                    result.previews.append(SyncEventPreview(
                        id: metadata.copyID,
                        sourceTitle: "Deleted source event",
                        destinationTitle: destinationEvent.title,
                        startDate: destinationEvent.startDate,
                        action: .error,
                        message: error.localizedDescription,
                        sourceCalendarName: sourceCalendarName,
                        destinationCalendarName: destinationCalendarName
                    ))
                }
            }
        }
    }

    /// Keeps the copies of an event that was moved rather than deleted. A copy's identity includes its
    /// source's start, which is what tells a recurring series' occurrences apart; so moving a meeting made
    /// its copies look orphaned, and they were deleted and recreated under new event IDs in the
    /// consolidated calendar and every busy-block calendar. A non-recurring event keeps its identifier
    /// when it moves, so a mapping whose event is still here, alone and non-recurring, is moved to the new
    /// start with its old fingerprint, and the normal update that follows rewrites the copy in place.
    /// Returns the destination events kept this way, which the deletion passes must leave alone.
    private func followMovedEvents(
        staleMappings: [EventMapping],
        sourceEvents: [any StoredEvent],
        settings: BridgeSettings
    ) -> Set<String> {
        let byIdentifier = Dictionary(grouping: sourceEvents) { $0.eventIdentifier ?? $0.calendarItemIdentifier }
        var kept = Set<String>()
        for mapping in staleMappings {
            guard let matches = byIdentifier[mapping.sourceEventIdentifier], matches.count == 1,
                  let moved = matches.first, !moved.hasRecurrenceRules,
                  store.event(withIdentifier: mapping.destinationEventIdentifier) != nil
            else {
                continue
            }
            let followed = EventMapping(
                sourceCalendarKey: mapping.sourceCalendarKey,
                destinationCalendarKey: mapping.destinationCalendarKey,
                sourceEventIdentifier: mapping.sourceEventIdentifier,
                sourceStartDate: moved.startDate,
                sourceLastModifiedDate: mapping.sourceLastModifiedDate,
                fingerprint: mapping.fingerprint,
                destinationEventIdentifier: mapping.destinationEventIdentifier,
                copyMode: mapping.copyMode,
                createdAt: mapping.createdAt
            )
            // A mapping already at the new start means the copy there is the live one; this one is stale.
            guard ledger.mappings[followed.id] == nil else { continue }
            kept.insert(mapping.destinationEventIdentifier)
            if settings.dryRun {
                dryRunMoves[followed.id] = followed
            } else {
                ledger.remove(id: mapping.id)
                ledger.upsert(followed)
            }
        }
        return kept
    }

    /// Re-links copies whose source changed identity without changing, instead of deleting and recreating
    /// them. Removing and re-adding an account regenerates every event's identifiers, so each copy's
    /// recorded source looks deleted and the same event looks new; left alone, that deletes and recreates
    /// every copy from the account and changes every one of their event IDs. A copy is re-linked only when
    /// the match is exact and one-to-one (see `relinks`); anything else keeps the old delete-and-create.
    /// The copy keeps its old fingerprint, so the normal update that follows refreshes it in place.
    private func relinkOrphanedCopies(
        orphans: [(event: any StoredEvent, metadata: BridgeEventMetadata)],
        sourceEvents: [any StoredEvent],
        claimedIdentities: Set<String>,
        sourceCalendarKey: String,
        destinationCalendarKey: String,
        settings: BridgeSettings,
        result: inout SyncResult
    ) -> Set<String> {
        guard !orphans.isEmpty else { return [] }
        let sourceCalendarName = calendarDisplayName(for: sourceCalendarKey)
        let destinationCalendarName = calendarDisplayName(for: destinationCalendarKey)
        let copyMode = settings.transform.copyAsFreeBusyOnly ? "freeBusy" : "details"
        func identity(of event: any StoredEvent) -> String {
            BridgeEventMetadata.makeSourceIdentity(
                sourceCalendarName: sourceCalendarName,
                sourceEventExternalIdentifier: event.calendarItemExternalIdentifier,
                sourceEventIdentifier: event.eventIdentifier,
                sourceStartDate: event.startDate
            )
        }
        // Only sources that would get a copy and do not have one yet can be the other half of a pair.
        let unclaimed = sourceEvents.filter { source in
            if claimedIdentities.contains(identity(of: source)) { return false }
            if settings.skipBridgeCreatedSourceEvents, BridgeEventMetadata.parse(from: source.notes) != nil { return false }
            if settings.skipWhenSourceOriginMatchesDestination,
               sourceOriginMatchesDestination(sourceEvent: source, sourceCalendarKey: sourceCalendarKey,
                                              destinationCalendarKey: destinationCalendarKey) { return false }
            return true
        }
        let sourcesByID = Dictionary(unclaimed.map { ($0.eventIdentifier ?? $0.calendarItemIdentifier, $0) },
                                     uniquingKeysWith: { first, _ in first })
        let orphansByID = Dictionary(orphans.map { ($0.event.eventIdentifier ?? $0.event.calendarItemIdentifier, $0) },
                                     uniquingKeysWith: { first, _ in first })
        let pairs = Self.relinks(
            orphans: orphansByID.map { id, copy in
                RelinkCandidate(id: id, title: copy.event.title ?? "", startDate: copy.event.startDate,
                                endDate: copy.event.endDate, isAllDay: copy.event.isAllDay)
            },
            sources: sourcesByID.map { id, source in
                RelinkCandidate(
                    id: id,
                    title: settings.transform.destinationTitle(
                        for: source.title ?? "",
                        sourceCalendarName: sourceCalendarName,
                        originCalendarName: originCalendarName(forSourceEvent: source, sourceCalendarKey: sourceCalendarKey)
                    ),
                    startDate: source.startDate, endDate: source.endDate, isAllDay: source.isAllDay)
            }
        )

        var relinked = Set<String>()
        for pair in pairs {
            guard let copy = orphansByID[pair.orphan], let source = sourcesByID[pair.source] else { continue }
            let sourceIdentity = identity(of: source)
            let copyID = BridgeEventMetadata.makeCopyID(
                sourceIdentity: sourceIdentity,
                destinationCalendarName: destinationCalendarName,
                copyMode: copyMode
            )
            let metadata = metadataForCopy(
                copyID: copyID,
                sourceIdentity: sourceIdentity,
                sourceCalendarName: sourceCalendarName,
                destinationCalendarName: destinationCalendarName,
                originCalendarName: originCalendarName(forSourceEvent: source, sourceCalendarKey: sourceCalendarKey) ?? sourceCalendarName,
                originCalendarKey: originCalendarKey(forSourceEvent: source, fallback: sourceCalendarKey),
                copyMode: copyMode,
                fingerprint: copy.metadata.fingerprint,
                sourceEvent: source,
                transform: settings.transform
            )
            result.previews.append(SyncEventPreview(
                id: copyID,
                sourceTitle: source.title ?? "Untitled",
                destinationTitle: copy.event.title,
                startDate: source.startDate,
                action: .update,
                message: settings.dryRun
                    ? "Would re-link copy to its source, whose identifiers changed (for example, the account was re-added)"
                    : "Re-linked copy to its source, whose identifiers changed (for example, the account was re-added)",
                sourceCalendarName: sourceCalendarName,
                destinationCalendarName: destinationCalendarName
            ))
            relinked.insert(pair.orphan)
            if settings.dryRun {
                dryRunRelinks[copyID] = copy.event
                continue
            }
            copy.event.notes = BridgeEventMetadata.notesByAddingMarker(to: copy.event.notes, metadata: metadata)
            do {
                try store.save(copy.event)
                ledger.removeMappings(destinationCalendarKey: destinationCalendarKey,
                                      destinationEventIdentifier: copy.event.eventIdentifier)
            } catch {
                relinked.remove(pair.orphan)
                result.failed += 1
                result.previews.append(SyncEventPreview(
                    id: copyID,
                    sourceTitle: source.title ?? "Untitled",
                    destinationTitle: copy.event.title,
                    startDate: source.startDate,
                    action: .error,
                    message: "Re-link failed: \(error.localizedDescription)",
                    sourceCalendarName: sourceCalendarName,
                    destinationCalendarName: destinationCalendarName
                ))
            }
        }
        return relinked
    }

    public struct RelinkCandidate: Equatable, Sendable {
        public var id: String
        /// For a copy, its title; for a source, the title its copy would be given.
        public var title: String
        public var startDate: Date
        public var endDate: Date
        public var isAllDay: Bool

        public init(id: String, title: String, startDate: Date, endDate: Date, isAllDay: Bool) {
            self.id = id
            self.title = title
            self.startDate = startDate
            self.endDate = endDate
            self.isAllDay = isAllDay
        }
    }

    /// Pairs orphaned copies with sources that are the same event under new identifiers. A pair is made only
    /// on an exact match — the title the copy would have, start, end and all-day — and only one-to-one: an
    /// orphan with two candidates, or a candidate two orphans want, is left to delete-and-create, because
    /// guessing between two real events is worse than recreating one.
    public static func relinks(orphans: [RelinkCandidate], sources: [RelinkCandidate]) -> [(orphan: String, source: String)] {
        func key(_ candidate: RelinkCandidate) -> String {
            [candidate.title,
             String(format: "%.0f", candidate.startDate.timeIntervalSince1970),
             String(format: "%.0f", candidate.endDate.timeIntervalSince1970),
             candidate.isAllDay ? "allDay" : "timed"].joined(separator: "\u{1f}")
        }
        let orphansByKey = Dictionary(grouping: orphans, by: key)
        let sourcesByKey = Dictionary(grouping: sources, by: key)
        return orphansByKey.compactMap { key, group -> (orphan: String, source: String)? in
            guard group.count == 1, let candidates = sourcesByKey[key], candidates.count == 1 else { return nil }
            return (group[0].id, candidates[0].id)
        }
        .sorted { $0.orphan < $1.orphan }
    }

    private func deleteDestinationCopy(
        sourceEvent: any StoredEvent,
        sourceCalendarKey: String,
        destinationCalendarKey: String,
        settings: BridgeSettings,
        result: inout SyncResult
    ) {
        let sourceTitle = sourceEvent.title ?? "Untitled"
        let sourceCalendarName = calendarDisplayName(for: sourceCalendarKey)
        let destinationCalendarName = calendarDisplayName(for: destinationCalendarKey)

        guard let mapping = ledger.mapping(
            sourceCalendarKey: sourceCalendarKey,
            destinationCalendarKey: destinationCalendarKey,
            sourceEventIdentifier: sourceEvent.eventIdentifier,
            sourceStartDate: sourceEvent.startDate
        ) else {
            result.skipped += 1
            result.previews.append(SyncEventPreview(
                id: UUID().uuidString,
                sourceTitle: sourceTitle,
                destinationTitle: nil,
                startDate: sourceEvent.startDate,
                action: .skipDuplicate,
                message: "No mapped destination copy found",
                sourceCalendarName: sourceCalendarName,
                destinationCalendarName: destinationCalendarName
            ))
            return
        }

        guard let destinationEvent = store.event(withIdentifier: mapping.destinationEventIdentifier) else {
            result.skipped += 1
            result.previews.append(SyncEventPreview(
                id: mapping.id,
                sourceTitle: sourceTitle,
                destinationTitle: nil,
                startDate: sourceEvent.startDate,
                action: .skipDuplicate,
                message: settings.dryRun ? "Destination copy is already missing" : "Removed stale mapping for missing destination copy",
                sourceCalendarName: sourceCalendarName,
                destinationCalendarName: destinationCalendarName
            ))
            if !settings.dryRun {
                ledger.remove(id: mapping.id)
            }
            return
        }

        result.deleted += 1
        result.previews.append(SyncEventPreview(
            id: mapping.id,
            sourceTitle: sourceTitle,
            destinationTitle: destinationEvent.title,
            startDate: sourceEvent.startDate,
            action: .delete,
            message: settings.dryRun ? "Would delete destination copy" : "Deleted destination copy",
            sourceCalendarName: sourceCalendarName,
            destinationCalendarName: destinationCalendarName
        ))

        guard !settings.dryRun else {
            return
        }

        do {
            try store.remove(destinationEvent, futureEvents: false)
            ledger.remove(id: mapping.id)
        } catch {
            result.failed += 1
            result.previews.append(SyncEventPreview(
                id: mapping.id,
                sourceTitle: sourceTitle,
                destinationTitle: destinationEvent.title,
                startDate: sourceEvent.startDate,
                action: .error,
                message: error.localizedDescription,
                sourceCalendarName: sourceCalendarName,
                destinationCalendarName: destinationCalendarName
            ))
        }
    }

    private func appendCreatePreview(
        sourceEvent: any StoredEvent,
        destinationTitle: String,
        sourceCalendarName: String,
        destinationCalendarName: String,
        sourceAvailability: String?,
        resultingAvailability: String?,
        transformationSummary: String,
        result: inout SyncResult
    ) {
        result.created += 1
        result.previews.append(SyncEventPreview(
            id: UUID().uuidString,
            sourceTitle: sourceEvent.title ?? "Untitled",
            destinationTitle: destinationTitle,
            startDate: sourceEvent.startDate,
            action: .create,
            message: "Will create a new copy",
            sourceCalendarName: sourceCalendarName,
            destinationCalendarName: destinationCalendarName,
            sourceAvailability: sourceAvailability,
            resultingAvailability: resultingAvailability,
            transformationSummary: transformationSummary
        ))
    }

    private func createCopy(
        sourceEvent: any StoredEvent,
        sourceCalendarKey: String,
        destinationCalendarKey: String,
        destinationCalendar: any StoredCalendar,
        fingerprint: String,
        sourceCalendarName: String,
        originCalendarName: String?,
        copyID: String,
        sourceIdentity: String,
        settings: BridgeSettings,
        result: inout SyncResult
    ) {
        let destinationEvent = store.makeEvent()
        let destinationCalendarName = calendarDisplayName(for: destinationCalendarKey)
        let copyMode = settings.transform.copyAsFreeBusyOnly ? "freeBusy" : "details"
        apply(
            sourceEvent: sourceEvent,
            to: destinationEvent,
            destinationCalendar: destinationCalendar,
            transform: settings.transform,
            sourceCalendarName: sourceCalendarName,
            originCalendarName: originCalendarName,
            metadata: metadataForCopy(
                copyID: copyID,
                sourceIdentity: sourceIdentity,
                sourceCalendarName: sourceCalendarName,
                destinationCalendarName: destinationCalendarName,
                originCalendarName: originCalendarName ?? sourceCalendarName,
                originCalendarKey: originCalendarKey(forSourceEvent: sourceEvent, fallback: sourceCalendarKey),
                copyMode: copyMode,
                fingerprint: fingerprint,
                sourceEvent: sourceEvent,
                transform: settings.transform
            )
        )

        do {
            try store.save(destinationEvent)
            upsertLedgerMapping(
                sourceEvent: sourceEvent,
                sourceCalendarKey: sourceCalendarKey,
                destinationCalendarKey: destinationCalendarKey,
                destinationEvent: destinationEvent,
                fingerprint: fingerprint,
                copyMode: copyMode
            )
        } catch {
            result.failed += 1
            result.previews.append(SyncEventPreview(
                id: UUID().uuidString,
                sourceTitle: sourceEvent.title ?? "Untitled",
                destinationTitle: destinationEvent.title,
                startDate: sourceEvent.startDate,
                action: .error,
                message: error.localizedDescription,
                sourceCalendarName: sourceCalendarName,
                destinationCalendarName: calendarDisplayName(for: destinationCalendarKey)
            ))
        }
    }

    private func apply(
        sourceEvent: any StoredEvent,
        to destinationEvent: any StoredEvent,
        destinationCalendar: any StoredCalendar,
        transform: TransformSettings,
        sourceCalendarName: String,
        originCalendarName: String?,
        metadata: BridgeEventMetadata? = nil
    ) {
        destinationEvent.place(in: destinationCalendar)
        destinationEvent.title = transform.destinationTitle(
            for: sourceEvent.title ?? "Untitled",
            sourceCalendarName: sourceCalendarName,
            originCalendarName: originCalendarName
        )
        destinationEvent.startDate = sourceEvent.startDate
        destinationEvent.endDate = sourceEvent.endDate
        destinationEvent.isAllDay = sourceEvent.isAllDay
        destinationEvent.timeZone = sourceEvent.timeZone
        if let availability = eventAvailability(
            for: transform.destinationAvailability,
            sourceEvent: sourceEvent,
            destinationCalendar: destinationCalendar
        ) {
            destinationEvent.availability = availability
        }
        if transform.copyAsFreeBusyOnly, transform.markFreeBusyEventsPrivate {
            destinationEvent.markPrivateIfSupported()
        }
        let copiesLocation = !transform.copyAsFreeBusyOnly && transform.copyLocation
        if copiesLocation, let place = EventFingerprint.geoPlace(of: sourceEvent) {
            // Build a new place rather than copying the source's persisted one, which fails to save into
            // another calendar. Setting structuredLocation replaces the location text with the place title,
            // and setting different text afterwards drops the coordinates, so carry the source text as the title.
            let destinationPlace = EKStructuredLocation(title: sourceEvent.location ?? place.title ?? "")
            destinationPlace.geoLocation = place.geoLocation
            destinationPlace.radius = place.radius
            destinationEvent.structuredLocation = destinationPlace
        } else {
            if destinationEvent.structuredLocation?.geoLocation != nil {
                destinationEvent.structuredLocation = nil
            }
            destinationEvent.location = copiesLocation ? sourceEvent.location : nil
        }
        destinationEvent.url = transform.copyAsFreeBusyOnly ? nil : (transform.copyURL ? sourceEvent.url : nil)
        var transformedNotes = transform.destinationNotes(for: sourceEvent.notes)
        if !transform.copyAsFreeBusyOnly, let details = EventDetailsSummary.text(for: sourceEvent) {
            transformedNotes = [transformedNotes, details].compactMap { $0 }.joined(separator: "\n\n")
        }
        if let metadata {
            destinationEvent.notes = BridgeEventMetadata.notesByAddingMarker(to: transformedNotes, metadata: metadata)
        } else {
            destinationEvent.notes = transformedNotes
        }

        // Each occurrence is copied as its own event, so copies never carry recurrence rules (a rule on an
        // occurrence copy would expand into phantom events); full-detail copies describe it in their notes.
        if transform.copyAsFreeBusyOnly || !transform.copyAlarms {
            // Free/busy copies never alert, and neither do consolidated copies unless asked to.
            destinationEvent.alarms = nil
        } else if let alarms = sourceEvent.alarms {
            destinationEvent.alarms = alarms.map { $0.copy() as? EKAlarm }.compactMap { $0 }
        }
    }

    /// Why a source event should not produce a copy under the run's skip settings, or nil to copy it.
    private func nonBlockingReason(for event: any StoredEvent, settings: BridgeSettings) -> String? {
        let metadata = BridgeEventMetadata.parse(from: event.notes)
        if settings.skipDeclinedSourceEvents,
           metadata?.declined == true || EventDetailsSummary.declinedByCurrentUser(event) {
            return "you declined this meeting"
        }
        if settings.skipFreeSourceEvents,
           (metadataAvailability(from: event) ?? supportedAvailability(event.availability)) == .free {
            return "marked Free"
        }
        if settings.skipAllDaySourceEvents, event.isAllDay {
            return "all-day event"
        }
        return nil
    }

    private func metadataForCopy(
        copyID: String,
        sourceIdentity: String,
        sourceCalendarName: String,
        destinationCalendarName: String,
        originCalendarName: String,
        originCalendarKey: String,
        copyMode: String,
        fingerprint: String,
        sourceEvent: any StoredEvent,
        transform: TransformSettings
    ) -> BridgeEventMetadata {
        let detailsCopy = namesSourceInTheClear(copyMode)
        let sourceMetadata = BridgeEventMetadata.parse(from: sourceEvent.notes)
        let sourceAvailability = sourceMetadata?.sourceAvailability ?? availabilityName(for: sourceEvent.availability)
        let intendedAvailability = intendedAvailabilityName(
            for: transform.destinationAvailability,
            sourceEvent: sourceEvent,
            sourceMetadata: sourceMetadata
        )
        return BridgeEventMetadata(
            copyID: copyID,
            sourceIdentity: sourceIdentity,
            sourceCalendarName: sourceCalendarName,
            sourceCalendarKeyHash: EventFingerprint.hash(parts: [sourceCalendarName]),
            destinationCalendarName: destinationCalendarName,
            originCalendarName: originCalendarName,
            originCalendarKeyHash: EventFingerprint.hash(parts: [originCalendarKey]),
            copyMode: copyMode,
            fingerprint: fingerprint,
            sourceAvailability: sourceAvailability,
            intendedAvailability: intendedAvailability,
            declined: !transform.copyAsFreeBusyOnly && EventDetailsSummary.declinedByCurrentUser(sourceEvent) ? true : nil,
            sourceEventID: detailsCopy ? sourceEvent.calendarItemIdentifier : nil,
            sourceEventExternalID: detailsCopy ? sourceEvent.calendarItemExternalIdentifier : nil,
            sourceCalendarPlainName: detailsCopy ? sourceCalendarName : nil
        )
    }

    /// A full-detail copy goes to your own consolidated calendar, so its marker names the source in
    /// the clear; a free/busy copy goes to someone else's calendar and never does.
    private func namesSourceInTheClear(_ copyMode: String) -> Bool { copyMode == "details" }

    /// True for a full-detail copy written before markers named their source: the marker is rewritten
    /// in place on the next run. The fingerprint is deliberately not involved — changing it would
    /// rewrite every copy on every route, and this needs only the copies that lack the reference.
    private func needsSourceReference(_ metadata: BridgeEventMetadata?, copyMode: String) -> Bool {
        guard let metadata, namesSourceInTheClear(copyMode) else { return false }
        return metadata.sourceEventID == nil
    }

    private func findExistingCopyBySyncedMetadata(
        copyIDs: [String],
        sourceEvent: any StoredEvent,
        destinationCalendar: any StoredCalendar
    ) -> (any StoredEvent)? {
        let start = sourceEvent.startDate.addingTimeInterval(-60)
        let end = sourceEvent.endDate.addingTimeInterval(60)
        return store.events(from: start, to: end, in: [destinationCalendar]).first {
            BridgeEventMetadata.parse(from: $0.notes).map { copyIDs.contains($0.copyID) } ?? false
        }
    }

    private func sourceOriginMatchesDestination(
        sourceEvent: any StoredEvent,
        sourceCalendarKey: String,
        destinationCalendarKey: String
    ) -> Bool {
        // The marker names the origin by calendar name, which survives an account being removed and
        // re-added; the ledger records a calendar key, which does not. Either one saying "this came from
        // the destination" is enough: a missing busy block is recoverable, a block echoing an account's
        // own event back onto it is not.
        if let metadata = BridgeEventMetadata.parse(from: sourceEvent.notes) {
            let destinationName = calendarDisplayName(for: destinationCalendarKey)
            let destinationKeyHash = EventFingerprint.hash(parts: [destinationCalendarKey])
            if BridgeEventMetadata.storedName(metadata.originCalendarName, matches: destinationName)
                || metadata.originCalendarKeyHash == destinationKeyHash {
                return true
            }
        }
        if let origin = liveLedgerOriginKey(forSourceEvent: sourceEvent, sourceCalendarKey: sourceCalendarKey) {
            return origin == destinationCalendarKey
        }
        return false
    }

    private func originCalendarKey(forSourceEvent sourceEvent: any StoredEvent, fallback sourceCalendarKey: String) -> String {
        if let key = liveLedgerOriginKey(forSourceEvent: sourceEvent, sourceCalendarKey: sourceCalendarKey) {
            return key
        }
        if let name = markerOriginName(of: sourceEvent),
           let key = calendars().first(where: { $0.displayName == name })?.stableKey {
            return key
        }
        return sourceCalendarKey
    }

    /// Where the ledger says a copy came from — but only if that calendar still exists. The ledger stores
    /// calendar keys, and removing and re-adding an account gives its calendars new keys. A stale key names
    /// nothing; trusting it made an account's own events look foreign and sent them back to it as busy
    /// blocks, and made the raw key string stand in for the origin's name (2026-09-21).
    private func liveLedgerOriginKey(forSourceEvent sourceEvent: any StoredEvent, sourceCalendarKey: String) -> String? {
        let live = Set(calendars().map(\.stableKey))
        return ledger.mappingsForDestinationEvent(calendarKey: sourceCalendarKey, eventIdentifier: sourceEvent.eventIdentifier)
            .map(\.sourceCalendarKey)
            .first { live.contains($0) }
    }

    private func markerOriginName(of event: any StoredEvent) -> String? {
        BridgeEventMetadata.parse(from: event.notes).flatMap {
            BridgeEventMetadata.resolveStoredName($0.originCalendarName, among: calendars().map(\.displayName))
        }
    }

    private func upsertLedgerMapping(
        sourceEvent: any StoredEvent,
        sourceCalendarKey: String,
        destinationCalendarKey: String,
        destinationEvent: any StoredEvent,
        fingerprint: String,
        copyMode: String
    ) {
        ledger.upsert(EventMapping(
            sourceCalendarKey: sourceCalendarKey,
            destinationCalendarKey: destinationCalendarKey,
            sourceEventIdentifier: sourceEvent.eventIdentifier,
            sourceStartDate: sourceEvent.startDate,
            sourceLastModifiedDate: sourceEvent.lastModifiedDate,
            fingerprint: fingerprint,
            destinationEventIdentifier: destinationEvent.eventIdentifier,
            copyMode: copyMode
        ))
    }

    private func originCalendarName(forSourceEvent sourceEvent: any StoredEvent, sourceCalendarKey: String) -> String? {
        if let key = liveLedgerOriginKey(forSourceEvent: sourceEvent, sourceCalendarKey: sourceCalendarKey) {
            return calendarDisplayName(for: key)
        }
        return markerOriginName(of: sourceEvent)
    }

    private func calendarDisplayName(for key: String) -> String {
        calendars().first { $0.stableKey == key }?.displayName ?? key
    }

    private func transformationSummary(
        transform: TransformSettings,
        sourceTitle: String,
        destinationTitle: String
    ) -> String {
        if transform.copyAsFreeBusyOnly {
            return [
                "Mode: free/busy block only",
                "Title: \(destinationTitle)",
                "Availability: \(transform.destinationAvailability.displayName)",
                "Privacy: private where supported by the destination calendar",
                "Location: stripped",
                "Notes: stripped",
                "URL: stripped",
                "Alarms: stripped"
            ].joined(separator: "\n")
        }

        var lines = [
            "Mode: full detail copy",
            "Source title: \(sourceTitle)",
            "Transformed title: \(destinationTitle)",
            "Availability: \(transform.destinationAvailability.displayName)",
            "Location: \(transform.copyLocation ? "copied" : "stripped")",
            "Notes: \(transform.copyNotes ? "copied" : "stripped")",
            "URL: \(transform.copyURL ? "copied" : "stripped")",
            "Alerts: \(transform.copyAlarms ? "copied" : "stripped")"
        ]
        if !transform.notesFooter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Notes footer: appended")
        }
        return lines.joined(separator: "\n")
    }

    private func eventAvailability(
        for availability: DestinationAvailability,
        sourceEvent: any StoredEvent,
        destinationCalendar: any StoredCalendar
    ) -> EKEventAvailability? {
        let target: EKEventAvailability?
        switch availability {
        case .preserve:
            target = metadataAvailability(from: sourceEvent) ?? supportedAvailability(sourceEvent.availability)
        case .free:
            target = .free
        case .busy:
            target = .busy
        case .tentative:
            target = .tentative
        }
        guard let target,
              destinationCalendar.supportedEventAvailabilities.supports(target)
        else {
            return nil
        }
        return target
    }

    private func intendedAvailabilityName(
        for availability: DestinationAvailability,
        sourceEvent: any StoredEvent,
        sourceMetadata: BridgeEventMetadata?
    ) -> String? {
        switch availability {
        case .preserve:
            sourceMetadata?.intendedAvailability
                ?? sourceMetadata?.sourceAvailability
                ?? availabilityName(for: sourceEvent.availability)
        case .free, .busy, .tentative:
            availability.rawValue
        }
    }

    private func availabilityDisplayName(_ availability: EKEventAvailability?) -> String {
        guard let availability else {
            return "Not written"
        }
        switch availability {
        case .free:
            return "Free"
        case .busy:
            return "Busy"
        case .tentative:
            return "Tentative"
        case .unavailable:
            return "Unavailable"
        case .notSupported:
            return "Not supported"
        @unknown default:
            return "Unknown"
        }
    }

    private func sourceAvailabilityDisplayName(for event: any StoredEvent) -> String {
        if let metadata = BridgeEventMetadata.parse(from: event.notes),
           let availability = availability(named: metadata.sourceAvailability ?? metadata.intendedAvailability) {
            return availabilityDisplayName(availability)
        }
        return availabilityDisplayName(supportedAvailability(event.availability))
    }

    private func metadataAvailability(from event: any StoredEvent) -> EKEventAvailability? {
        guard let metadata = BridgeEventMetadata.parse(from: event.notes) else {
            return nil
        }
        return availability(
            named: metadata.intendedAvailability ?? metadata.sourceAvailability
        )
    }

    private func supportedAvailability(_ availability: EKEventAvailability) -> EKEventAvailability? {
        switch availability {
        case .free, .busy, .tentative, .unavailable:
            availability
        case .notSupported:
            nil
        @unknown default:
            nil
        }
    }

    private func availabilityName(for availability: EKEventAvailability) -> String? {
        switch availability {
        case .free:
            "free"
        case .busy:
            "busy"
        case .tentative:
            "tentative"
        case .unavailable:
            "unavailable"
        case .notSupported:
            nil
        @unknown default:
            nil
        }
    }

    private func availability(named name: String?) -> EKEventAvailability? {
        switch name {
        case "free":
            .free
        case "busy":
            .busy
        case "tentative":
            .tentative
        case "unavailable":
            .unavailable
        default:
            nil
        }
    }
}

private extension EKCalendarEventAvailabilityMask {
    func supports(_ availability: EKEventAvailability) -> Bool {
        switch availability {
        case .free:
            contains(.free)
        case .busy:
            contains(.busy)
        case .tentative:
            contains(.tentative)
        case .unavailable:
            contains(.unavailable)
        case .notSupported:
            false
        @unknown default:
            false
        }
    }
}
