import Foundation

public enum DestinationAvailability: String, Codable, CaseIterable, Equatable, Sendable {
    case preserve
    case free
    case busy
    case tentative

    public var displayName: String {
        switch self {
        case .preserve: "Leave As-Is"
        case .free: "Free"
        case .busy: "Busy"
        case .tentative: "Tentative"
        }
    }
}

public struct TransformSettings: Codable, Equatable, Sendable {
    public var titlePrefix: String
    public var titleSuffix: String
    public var notesFooter: String
    public var copyLocation: Bool
    public var copyNotes: Bool
    public var copyURL: Bool
    public var copyAsFreeBusyOnly: Bool
    public var freeBusyTitle: String
    public var markFreeBusyEventsPrivate: Bool
    public var includeOriginCalendarInFreeBusyTitle: Bool
    public var includeSourceCalendarInTitle: Bool
    public var destinationAvailability: DestinationAvailability

    public init(
        titlePrefix: String = "",
        titleSuffix: String = "",
        notesFooter: String = "",
        copyLocation: Bool = true,
        copyNotes: Bool = true,
        copyURL: Bool = true,
        copyAsFreeBusyOnly: Bool = false,
        freeBusyTitle: String = "Busy",
        markFreeBusyEventsPrivate: Bool = true,
        includeOriginCalendarInFreeBusyTitle: Bool = false,
        includeSourceCalendarInTitle: Bool = false,
        destinationAvailability: DestinationAvailability = .busy
    ) {
        self.titlePrefix = titlePrefix
        self.titleSuffix = titleSuffix
        self.notesFooter = notesFooter
        self.copyLocation = copyLocation
        self.copyNotes = copyNotes
        self.copyURL = copyURL
        self.copyAsFreeBusyOnly = copyAsFreeBusyOnly
        self.freeBusyTitle = freeBusyTitle
        self.markFreeBusyEventsPrivate = markFreeBusyEventsPrivate
        self.includeOriginCalendarInFreeBusyTitle = includeOriginCalendarInFreeBusyTitle
        self.includeSourceCalendarInTitle = includeSourceCalendarInTitle
        self.destinationAvailability = destinationAvailability
    }

    private enum CodingKeys: String, CodingKey {
        case titlePrefix
        case titleSuffix
        case notesFooter
        case copyLocation
        case copyNotes
        case copyURL
        case copyAsFreeBusyOnly
        case freeBusyTitle
        case markFreeBusyEventsPrivate
        case includeOriginCalendarInFreeBusyTitle
        case includeSourceCalendarInTitle
        case destinationAvailability
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            titlePrefix: try container.decodeIfPresent(String.self, forKey: .titlePrefix) ?? "",
            titleSuffix: try container.decodeIfPresent(String.self, forKey: .titleSuffix) ?? "",
            notesFooter: try container.decodeIfPresent(String.self, forKey: .notesFooter) ?? "",
            copyLocation: try container.decodeIfPresent(Bool.self, forKey: .copyLocation) ?? true,
            copyNotes: try container.decodeIfPresent(Bool.self, forKey: .copyNotes) ?? true,
            copyURL: try container.decodeIfPresent(Bool.self, forKey: .copyURL) ?? true,
            copyAsFreeBusyOnly: try container.decodeIfPresent(Bool.self, forKey: .copyAsFreeBusyOnly) ?? false,
            freeBusyTitle: try container.decodeIfPresent(String.self, forKey: .freeBusyTitle) ?? "Busy",
            markFreeBusyEventsPrivate: try container.decodeIfPresent(Bool.self, forKey: .markFreeBusyEventsPrivate) ?? true,
            includeOriginCalendarInFreeBusyTitle: try container.decodeIfPresent(Bool.self, forKey: .includeOriginCalendarInFreeBusyTitle) ?? false,
            includeSourceCalendarInTitle: try container.decodeIfPresent(Bool.self, forKey: .includeSourceCalendarInTitle) ?? false,
            destinationAvailability: try container.decodeIfPresent(DestinationAvailability.self, forKey: .destinationAvailability) ?? .busy
        )
    }

    public func destinationTitle(
        for sourceTitle: String,
        sourceCalendarName: String? = nil,
        originCalendarName: String? = nil
    ) -> String {
        if copyAsFreeBusyOnly {
            let trimmed = freeBusyTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = trimmed.isEmpty ? "Busy" : trimmed
            guard includeOriginCalendarInFreeBusyTitle,
                  let originCalendarName,
                  !originCalendarName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return title
            }
            let source = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(originCalendarName): \(source.isEmpty ? title : source)"
        }
        if includeSourceCalendarInTitle,
           let sourceCalendarName,
           !sourceCalendarName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let source = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(sourceCalendarName): \(source.isEmpty ? "Untitled" : source)"
        }
        return "\(titlePrefix)\(sourceTitle)\(titleSuffix)"
    }

    public func destinationNotes(for sourceNotes: String?) -> String? {
        guard !copyAsFreeBusyOnly else { return nil }

        let base = copyNotes ? (sourceNotes ?? "") : ""
        guard !notesFooter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return base.isEmpty ? nil : base
        }
        return [base, notesFooter].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

public struct BridgeSettings: Codable, Equatable, Sendable {
    public var sourceCalendarKey: String?
    public var destinationCalendarKey: String?
    public var startDate: Date
    public var endDate: Date
    public var transform: TransformSettings
    public var dryRun: Bool
    public var updateExistingCopies: Bool
    public var skipBridgeCreatedSourceEvents: Bool
    public var skipWhenSourceOriginMatchesDestination: Bool
    public var reconcileDeletions: Bool
    /// Leaves out source events marked Free, which do not block time (used for fan-out).
    public var skipFreeSourceEvents: Bool
    /// Leaves out meetings you declined (used for fan-out).
    public var skipDeclinedSourceEvents: Bool

    public init(
        sourceCalendarKey: String? = nil,
        destinationCalendarKey: String? = nil,
        startDate: Date = Calendar.current.startOfDay(for: Date()),
        endDate: Date = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date(),
        transform: TransformSettings = TransformSettings(),
        dryRun: Bool = true,
        updateExistingCopies: Bool = false,
        skipBridgeCreatedSourceEvents: Bool = false,
        skipWhenSourceOriginMatchesDestination: Bool = false,
        reconcileDeletions: Bool = false,
        skipFreeSourceEvents: Bool = false,
        skipDeclinedSourceEvents: Bool = false
    ) {
        self.sourceCalendarKey = sourceCalendarKey
        self.destinationCalendarKey = destinationCalendarKey
        self.startDate = startDate
        self.endDate = endDate
        self.transform = transform
        self.dryRun = dryRun
        self.updateExistingCopies = updateExistingCopies
        self.skipBridgeCreatedSourceEvents = skipBridgeCreatedSourceEvents
        self.skipWhenSourceOriginMatchesDestination = skipWhenSourceOriginMatchesDestination
        self.reconcileDeletions = reconcileDeletions
        self.skipFreeSourceEvents = skipFreeSourceEvents
        self.skipDeclinedSourceEvents = skipDeclinedSourceEvents
    }
}

/// The two kinds of run a consolidated sync is made of. The app builds every route from these, and the
/// engine tests run them, so what is tested is what runs.
extension BridgeSettings {
    /// A contributor's events into the consolidated calendar, with full details.
    public static func fanIn(sourceKey: String, consolidatedKey: String, startDate: Date, endDate: Date, dryRun: Bool) -> BridgeSettings {
        BridgeSettings(
            sourceCalendarKey: sourceKey,
            destinationCalendarKey: consolidatedKey,
            startDate: startDate,
            endDate: endDate,
            transform: TransformSettings(includeSourceCalendarInTitle: true, destinationAvailability: .preserve),
            dryRun: dryRun,
            updateExistingCopies: true,
            skipBridgeCreatedSourceEvents: true,
            skipWhenSourceOriginMatchesDestination: false,
            reconcileDeletions: true
        )
    }

    /// The consolidated calendar out to a recipient, as busy blocks.
    public static func fanOut(
        consolidatedKey: String,
        destinationKey: String,
        availability: DestinationAvailability,
        title: String = FreeBusyCompliance.fanOutTitle,
        skipFreeEvents: Bool = true,
        skipDeclinedEvents: Bool = true,
        startDate: Date,
        endDate: Date,
        dryRun: Bool
    ) -> BridgeSettings {
        BridgeSettings(
            sourceCalendarKey: consolidatedKey,
            destinationCalendarKey: destinationKey,
            startDate: startDate,
            endDate: endDate,
            transform: TransformSettings(
                copyAsFreeBusyOnly: true,
                freeBusyTitle: title,
                destinationAvailability: availability
            ),
            dryRun: dryRun,
            updateExistingCopies: true,
            skipBridgeCreatedSourceEvents: false,
            skipWhenSourceOriginMatchesDestination: true,
            reconcileDeletions: true,
            skipFreeSourceEvents: skipFreeEvents,
            skipDeclinedSourceEvents: skipDeclinedEvents
        )
    }
}
