import CoordinatedCalendarCore
import Foundation

struct GUISettings: Codable, Equatable {
    var modeRawValue: String
    var startDate: Date?
    var endDate: Date?
    var consolidatedCalendarKey: String?
    var contributorCalendarKeys: [String]
    var recipientCalendarKeys: [String]
    var contributorIntervals: [String: Int]
    var recipientIntervals: [String: Int]
    var contributorAvailabilities: [String: DestinationAvailability]?
    var recipientAvailabilities: [String: DestinationAvailability]?
    /// Title of fan-out busy blocks; nil or blank means FreeBusyCompliance.fanOutTitle.
    var fanOutTitle: String?
    /// Fan-out leaves out events marked Free; nil means true.
    var skipFreeEvents: Bool?
    /// Fan-out leaves out meetings you declined; nil means true.
    var skipDeclinedEvents: Bool?
    /// How often the background sync runs, in seconds; nil falls back to the shortest per-calendar interval.
    var syncInterval: Int?
}

/// The fan-in and fan-out runs a consolidated sync performs. The GUI and `--sync-gui-settings` both build
/// their runs here so they always behave the same.
extension GUISettings {
    var effectiveFanOutTitle: String {
        let title = fanOutTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? FreeBusyCompliance.fanOutTitle : title
    }

    var effectiveSyncInterval: Int {
        syncInterval ?? (Array(contributorIntervals.values) + Array(recipientIntervals.values)).min() ?? 300
    }

    func fanInSettings(sourceKey: String, consolidatedKey: String, startDate: Date, endDate: Date, dryRun: Bool) -> BridgeSettings {
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

    func fanOutSettings(
        consolidatedKey: String,
        destinationKey: String,
        availability: DestinationAvailability,
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
                freeBusyTitle: effectiveFanOutTitle,
                destinationAvailability: availability
            ),
            dryRun: dryRun,
            updateExistingCopies: true,
            skipBridgeCreatedSourceEvents: false,
            skipWhenSourceOriginMatchesDestination: true,
            reconcileDeletions: true,
            skipFreeSourceEvents: skipFreeEvents ?? true,
            skipDeclinedSourceEvents: skipDeclinedEvents ?? true
        )
    }
}

final class GUISettingsStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// A store in a throwaway file, for demo mode or when the settings folder is unavailable.
    static func inMemory() -> GUISettingsStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("coordinatedcalendar-settings-\(UUID().uuidString).json")
        return GUISettingsStore(file: url)
    }

    private init(file: URL) {
        self.fileURL = file
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    init(fileURL: URL? = nil) throws {
        if let fileURL {
            self.fileURL = fileURL
            return
        }

        self.fileURL = try AppSupport.directory().appendingPathComponent("gui-settings.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() throws -> GUISettings? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(GUISettings.self, from: data)
    }

    func save(_ settings: GUISettings) throws {
        let data = try encoder.encode(settings)
        try data.write(to: fileURL, options: [.atomic])
    }
}
