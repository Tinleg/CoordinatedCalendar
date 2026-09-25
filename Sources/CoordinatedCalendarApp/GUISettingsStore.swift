import CoordinatedCalendarCore
import Foundation

struct GUISettings: Codable, Equatable {
    var modeRawValue: String
    /// The window's dates on the day the settings were saved. Kept for older builds; the window itself is
    /// `windowDaysPast`/`windowDaysFuture`, which move forward with the calendar.
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
    /// Fan-out leaves out all-day events even when they are marked Busy; nil means false.
    var skipAllDayEvents: Bool?
    /// Gathered events keep their alerts in the consolidated calendar; nil means false (alerts stripped).
    var keepAlertsInConsolidated: Bool?
    /// How often the background sync runs, in seconds; nil falls back to the shortest per-calendar interval.
    var syncInterval: Int?
    /// The display name each selected calendar key had when last seen. Names survive an account being removed
    /// and re-added; keys do not, so this is what lets a returning calendar be re-attached (CalendarRebinding).
    var calendarNames: [String: String]?
    var windowDaysPast: Int?
    var windowDaysFuture: Int?
}

extension GUISettings {
    /// The sync window in days. Settings saved before the window was kept in days have only dates: then
    /// the installed background job's window wins, since that is what has actually been syncing, and
    /// failing that the saved dates are counted from today.
    func syncWindow(installedJob: SyncWindow? = SyncAgentInstaller.installedSyncWindow()) -> SyncWindow {
        if let windowDaysPast, let windowDaysFuture {
            return SyncWindow(daysPast: windowDaysPast, daysFuture: windowDaysFuture)
        }
        if let installedJob {
            return installedJob
        }
        if let startDate, let endDate {
            return SyncWindow(start: startDate, end: endDate)
        }
        return .standard
    }
}

extension GUISettings {
    struct CalendarReconciliation: Equatable {
        /// Names of calendars re-attached under a new identifier.
        var rebound: [String] = []
        /// Names of selected calendars that are not currently available and could not be re-attached.
        var missing: [String] = []

        var notices: [String] {
            rebound.map { "Re-attached \u{201C}\($0)\u{201D}: it came back with a new identifier, which happens when its account is removed and added again. Its settings were kept." }
                + missing.map { "\u{201C}\($0)\u{201D} is selected but not currently available. It stays selected and resumes syncing when it returns." }
        }
    }

    var selectedCalendarKeys: [String] {
        [consolidatedCalendarKey].compactMap { $0 } + contributorCalendarKeys + recipientCalendarKeys
    }

    /// Re-attaches selected calendars that came back under a new identifier, carrying their per-calendar
    /// settings, and records the current name of every selected calendar. A selected calendar that is simply
    /// absent — an account offline, or switched off for a moment — stays selected and is reported.
    mutating func reconcileCalendars(with calendars: [CalendarIdentity]) -> CalendarReconciliation {
        let available = calendars.map { CalendarRebinding.Available(key: $0.stableKey, name: $0.displayName) }
        let recorded = calendarNames ?? [:]
        let rebinds = CalendarRebinding.rebinds(selected: selectedCalendarKeys, recordedNames: recorded, available: available)
        let missing = CalendarRebinding.stillMissing(
            selected: selectedCalendarKeys, recordedNames: recorded, available: available, rebinds: rebinds)
        for (old, new) in rebinds {
            rebind(old, to: new)
        }
        var names = recorded.filter { rebinds[$0.key] == nil }
        let selected = Set(selectedCalendarKeys)
        for calendar in calendars where selected.contains(calendar.stableKey) {
            names[calendar.stableKey] = calendar.displayName
        }
        // A missing calendar keeps its recorded name, so it can still be re-attached when it returns.
        calendarNames = names.filter { selected.contains($0.key) }
        return CalendarReconciliation(
            rebound: rebinds.keys.compactMap { recorded[$0] }.sorted(),
            missing: missing.map { $0.name ?? "A calendar that is no longer available" }
        )
    }

    private mutating func rebind(_ old: String, to new: String) {
        if consolidatedCalendarKey == old { consolidatedCalendarKey = new }
        contributorCalendarKeys = contributorCalendarKeys.map { $0 == old ? new : $0 }
        recipientCalendarKeys = recipientCalendarKeys.map { $0 == old ? new : $0 }
        func move<Value>(_ values: inout [String: Value]) {
            if let value = values.removeValue(forKey: old) { values[new] = value }
        }
        move(&contributorIntervals)
        move(&recipientIntervals)
        if var values = contributorAvailabilities { move(&values); contributorAvailabilities = values }
        if var values = recipientAvailabilities { move(&values); recipientAvailabilities = values }
    }
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
        .fanIn(sourceKey: sourceKey, consolidatedKey: consolidatedKey, copyAlarms: keepAlertsInConsolidated ?? false,
               startDate: startDate, endDate: endDate, dryRun: dryRun)
    }

    func fanOutSettings(
        consolidatedKey: String,
        destinationKey: String,
        availability: DestinationAvailability,
        startDate: Date,
        endDate: Date,
        dryRun: Bool
    ) -> BridgeSettings {
        .fanOut(
            consolidatedKey: consolidatedKey,
            destinationKey: destinationKey,
            availability: availability,
            title: effectiveFanOutTitle,
            skipFreeEvents: skipFreeEvents ?? true,
            skipDeclinedEvents: skipDeclinedEvents ?? true,
            skipAllDayEvents: skipAllDayEvents ?? false,
            startDate: startDate,
            endDate: endDate,
            dryRun: dryRun
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
