import Foundation

public struct EventMapping: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var sourceCalendarKey: String
    public var destinationCalendarKey: String
    public var sourceEventIdentifier: String
    public var sourceStartDate: Date
    public var sourceLastModifiedDate: Date?
    public var fingerprint: String
    public var destinationEventIdentifier: String
    public var copyMode: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        sourceCalendarKey: String,
        destinationCalendarKey: String,
        sourceEventIdentifier: String,
        sourceStartDate: Date,
        sourceLastModifiedDate: Date?,
        fingerprint: String,
        destinationEventIdentifier: String,
        copyMode: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = Self.makeID(
            sourceCalendarKey: sourceCalendarKey,
            destinationCalendarKey: destinationCalendarKey,
            sourceEventIdentifier: sourceEventIdentifier,
            sourceStartDate: sourceStartDate
        )
        self.sourceCalendarKey = sourceCalendarKey
        self.destinationCalendarKey = destinationCalendarKey
        self.sourceEventIdentifier = sourceEventIdentifier
        self.sourceStartDate = sourceStartDate
        self.sourceLastModifiedDate = sourceLastModifiedDate
        self.fingerprint = fingerprint
        self.destinationEventIdentifier = destinationEventIdentifier
        self.copyMode = copyMode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func makeID(
        sourceCalendarKey: String,
        destinationCalendarKey: String,
        sourceEventIdentifier: String,
        sourceStartDate: Date
    ) -> String {
        EventFingerprint.hash(parts: [
            sourceCalendarKey,
            destinationCalendarKey,
            sourceEventIdentifier,
            String(format: "%.0f", sourceStartDate.timeIntervalSince1970)
        ])
    }
}

public final class MappingLedger: @unchecked Sendable {
    public private(set) var mappings: [String: EventMapping]
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            let stored = try decoder.decode([EventMapping].self, from: data)
            self.mappings = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
        } else {
            self.mappings = [:]
        }
    }

    /// A ledger in a throwaway file, for demo mode or when the settings folder is unavailable.
    public static func inMemory() -> MappingLedger {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("coordinatedcalendar-\(UUID().uuidString).json")
        return MappingLedger(emptyAt: url)
    }

    /// Starts empty without reading `fileURL`.
    public init(emptyAt fileURL: URL) {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        self.mappings = [:]
    }

    public convenience init() throws {
        try self.init(fileURL: AppSupport.directory().appendingPathComponent("mappings.json"))
    }

    public func mapping(
        sourceCalendarKey: String,
        destinationCalendarKey: String,
        sourceEventIdentifier: String,
        sourceStartDate: Date
    ) -> EventMapping? {
        mappings[EventMapping.makeID(
            sourceCalendarKey: sourceCalendarKey,
            destinationCalendarKey: destinationCalendarKey,
            sourceEventIdentifier: sourceEventIdentifier,
            sourceStartDate: sourceStartDate
        )]
    }

    public func upsert(_ mapping: EventMapping) {
        mappings[mapping.id] = mapping
    }

    public func remove(id: String) {
        mappings.removeValue(forKey: id)
    }

    public func removeAll() {
        mappings.removeAll()
    }

    public func mappings(
        sourceCalendarKey: String,
        destinationCalendarKey: String,
        startDate: Date,
        endDate: Date
    ) -> [EventMapping] {
        mappings.values
            .filter {
                $0.sourceCalendarKey == sourceCalendarKey
                    && $0.destinationCalendarKey == destinationCalendarKey
                    && $0.sourceStartDate >= startDate
                    && $0.sourceStartDate < endDate
            }
            .sorted { $0.sourceStartDate < $1.sourceStartDate }
    }

    public func mappingForDestinationEvent(calendarKey: String, eventIdentifier: String) -> EventMapping? {
        mappings.values.first {
            $0.destinationCalendarKey == calendarKey && $0.destinationEventIdentifier == eventIdentifier
        }
    }

    public func isBridgeCreatedDestination(calendarKey: String, eventIdentifier: String) -> Bool {
        mappingForDestinationEvent(calendarKey: calendarKey, eventIdentifier: eventIdentifier) != nil
    }

    public func save() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(mappings.values.sorted { $0.createdAt < $1.createdAt })
        try data.write(to: fileURL, options: [.atomic])
    }
}
