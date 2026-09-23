import EventKit
import Foundation

/// A digest of everything a consolidated sync reads, so a run can tell that nothing has changed since the
/// last full sync and stop before doing any work. Almost every scheduled run used to find nothing to do,
/// after reading every event in every route (2026-09-23: 2,628 events, about four seconds, 288 times a day).
///
/// It covers every event in every calendar the sync touches — sources, the consolidated calendar and the
/// recipients — with each field a sync decision depends on, plus `context`: the settings, the date window
/// and the app version. So a changed event, a copy someone edited or deleted, a new setting, the window
/// moving on at midnight or an upgrade all make the next run a full one.
public enum SyncSignature {
    public static func of(events: [(calendarKey: String, event: any StoredEvent)], context: [String]) -> String {
        let lines = events.map { item in
            let event = item.event
            return [
                item.calendarKey,
                event.eventIdentifier ?? event.calendarItemIdentifier,
                event.calendarItemExternalIdentifier ?? "",
                seconds(event.startDate),
                seconds(event.endDate),
                event.isAllDay ? "allDay" : "timed",
                event.title ?? "",
                event.location ?? "",
                event.url?.absoluteString ?? "",
                event.notes ?? "",
                "\(event.availability.rawValue)",
                "\(event.status.rawValue)",
                "\((event.alarms ?? []).count)",
                event.hasRecurrenceRules ? "recurring" : "single",
                EventDetailsSummary.declinedByCurrentUser(event) ? "declined" : "",
                event.structuredLocation?.geoLocation.map { "\($0.coordinate.latitude),\($0.coordinate.longitude)" } ?? "",
                seconds(event.lastModifiedDate)
            ].joined(separator: "\u{1f}")
        }
        return EventFingerprint.hash(parts: context + ["events:\(lines.count)"] + lines.sorted())
    }

    private static func seconds(_ date: Date?) -> String {
        date.map { String(format: "%.0f", $0.timeIntervalSince1970) } ?? ""
    }
}

/// The signature a full sync started from, recorded once it succeeded.
public struct SyncSignatureRecord: Codable, Equatable, Sendable {
    public var signature: String
    public var fullRunAt: Date

    public init(signature: String, fullRunAt: Date) {
        self.signature = signature
        self.fullRunAt = fullRunAt
    }

    /// A full sync runs anyway this often, so nothing the signature fails to capture can go unnoticed long.
    public static let maximumAge: TimeInterval = 6 * 60 * 60

    /// True when a run may skip: the calendars look exactly as they did when the last full sync started,
    /// and that sync is recent enough.
    public static func canSkip(current: String, recorded: SyncSignatureRecord?, now: Date = Date()) -> Bool {
        guard let recorded, recorded.signature == current else { return false }
        return now.timeIntervalSince(recorded.fullRunAt) < maximumAge
    }
}

/// When to sync after calendar changes. One edit arrives as several change notifications — the write,
/// then the account syncing it back from its server a few seconds later — so a sync waits for a quiet
/// spell, but never longer than `maximumDelay` after the first change while changes keep coming.
public struct ChangeDebouncer: Equatable, Sendable {
    public var quietPeriod: TimeInterval
    public var maximumDelay: TimeInterval
    public private(set) var firstChange: Date?
    public private(set) var lastChange: Date?
    public private(set) var pendingChanges = 0

    public init(quietPeriod: TimeInterval = 15, maximumDelay: TimeInterval = 60) {
        self.quietPeriod = quietPeriod
        self.maximumDelay = maximumDelay
    }

    public mutating func recordChange(at date: Date) {
        if firstChange == nil { firstChange = date }
        lastChange = date
        pendingChanges += 1
    }

    /// When the pending changes should be synced, or nil when there are none.
    public var dueDate: Date? {
        guard let firstChange, let lastChange else { return nil }
        return min(lastChange.addingTimeInterval(quietPeriod), firstChange.addingTimeInterval(maximumDelay))
    }

    public func isDue(at date: Date) -> Bool {
        dueDate.map { date >= $0 } ?? false
    }

    public mutating func reset() {
        firstChange = nil
        lastChange = nil
        pendingChanges = 0
    }
}
