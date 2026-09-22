import CoordinatedCalendarCore
import EventKit
import Foundation

enum CommandLineBridge {
    nonisolated(unsafe) private static var verbose = false

    static var isCommandLineMode: Bool {
        CommandLine.arguments.dropFirst().contains { $0.hasPrefix("--") }
    }

    static func run() async -> Int32 {
        do {
            let options = try CLIOptions(arguments: Array(CommandLine.arguments.dropFirst()))
            if options.hasFlag("help") || options.command == nil {
                print(helpText)
                return 0
            }
            verbose = options.hasFlag("verbose")

            // These manage LaunchAgents and status files only, so they do not need Calendar access.
            switch options.command {
            case "health-check":
                return healthCheck(options: options)
            case "install-sync-agent":
                return try installSyncAgent(options: options)
            default:
                break
            }

            let ledger = try MappingLedger()
            let engine = CoordinatedCalendarEngine(ledger: ledger)
            let granted = try await ensureCalendarAccess(engine: engine)
            guard granted else {
                fputs("Calendar full access is required. Open the app once and grant access, then retry.\n", stderr)
                return 2
            }

            switch options.command {
            case "list-calendars":
                return listCalendars(engine: engine)
            case "list-events":
                return listEvents(options: options, engine: engine)
            case "copy":
                return await copy(options: options, engine: engine)
            case "delete":
                return await delete(options: options, engine: engine)
            case "fan-in":
                return await fanIn(options: options, engine: engine)
            case "fan-out":
                return await fanOut(options: options, engine: engine)
            case "cycle":
                return await cycle(options: options, engine: engine)
            case "sync-gui-settings":
                return await syncGUISettings(options: options, engine: engine)
            case "remove-all-copies":
                return await removeAllCopies(options: options, engine: engine)
            case "install-agent":
                return try installAgent(options: options)
            case "uninstall-agent":
                return try uninstallAgent()
            default:
                fputs("Unknown command. Use --help.\n", stderr)
                return 64
            }
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func ensureCalendarAccess(engine: CoordinatedCalendarEngine) async throws -> Bool {
        switch engine.authorizationStatus() {
        case .fullAccess:
            return true
        case .notDetermined:
            return try await engine.requestAccess()
        default:
            return false
        }
    }

    private static func listCalendars(engine: CoordinatedCalendarEngine) -> Int32 {
        for calendar in engine.calendars() {
            let writable = calendar.allowsContentModifications ? "writable" : "read-only"
            let availability = calendar.supportedAvailabilities.isEmpty
                ? "availability: none"
                : "availability: \(calendar.supportedAvailabilities.joined(separator: ","))"
            print("\(calendar.stableKey)\t\(calendar.displayName)\t\(writable)\tsource: \(calendar.sourceType)\t\(availability)")
        }
        return 0
    }

    /// Read-only: what EventKit hands the app for one calendar, with the identifiers identity is
    /// built from. For diagnosing sync problems without writing anything.
    private static func listEvents(options: CLIOptions, engine: CoordinatedCalendarEngine) -> Int32 {
        do {
            let identity = try resolveCalendar(options.requiredValue("from"), engine: engine)
            guard let calendar = engine.calendar(for: identity.stableKey) else {
                throw CLIError.message("Calendar \(identity.displayName) is not available.")
            }
            let iso = ISO8601DateFormatter()
            let events = engine.events(from: try startDate(options: options), to: try endDate(options: options),
                                       calendars: [calendar])
            for event in events.sorted(by: { $0.startDate < $1.startDate }) {
                let marker = BridgeEventMetadata.parse(from: event.notes)
                print([
                    iso.string(from: event.startDate),
                    event.title ?? "Untitled",
                    "external: \(event.calendarItemExternalIdentifier ?? "none")",
                    "recurring: \(event.hasRecurrenceRules ? "yes" : "no")",
                    marker.map { "marker: \($0.copyMode)" } ?? "marker: none",
                    "copy of: \(marker?.sourceEventExternalID ?? "-")"
                ].joined(separator: "\t"))
            }
            return 0
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func copy(options: CLIOptions, engine: CoordinatedCalendarEngine) async -> Int32 {
        do {
            let source = try resolveCalendar(options.requiredValue("from"), engine: engine)
            let destination = try resolveCalendar(options.requiredValue("to"), engine: engine)
            var settings = try baseSettings(options: options, source: source, destination: destination)
            settings.skipBridgeCreatedSourceEvents = options.hasFlag("skip-bridge-created")
            return await run(settings: settings, engine: engine)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 64
        }
    }

    private static func delete(options: CLIOptions, engine: CoordinatedCalendarEngine) async -> Int32 {
        do {
            let source = try resolveCalendar(options.requiredValue("from"), engine: engine)
            let destination = try resolveCalendar(options.requiredValue("to"), engine: engine)
            let settings = try baseSettings(options: options, source: source, destination: destination)
            return await delete(settings: settings, engine: engine)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 64
        }
    }

    private static func fanIn(options: CLIOptions, engine: CoordinatedCalendarEngine) async -> Int32 {
        do {
            let destination = try resolveCalendar(options.requiredValue("to"), engine: engine)
            let sources = try selectedSources(options: options, excluding: destination, engine: engine)
            var aggregate = SyncResult()

            for source in sources {
                var settings = try baseSettings(options: options, source: source, destination: destination)
                settings.skipBridgeCreatedSourceEvents = true
                settings.transform.includeSourceCalendarInTitle = true
                let result = await engine.run(settings: settings)
                printSummary(label: "fan-in \(source.displayName) -> \(destination.displayName)", result: result)
                aggregate.merge(result)
            }

            printSummary(label: "fan-in total", result: aggregate, detail: false)
            return aggregate.failed == 0 ? 0 : 1
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 64
        }
    }

    private static func fanOut(options: CLIOptions, engine: CoordinatedCalendarEngine) async -> Int32 {
        do {
            let source = try resolveCalendar(options.requiredValue("from"), engine: engine)
            let destinations = try selectedDestinations(options: options, excluding: source, engine: engine)
            var aggregate = SyncResult()

            for destination in destinations {
                var settings = try baseSettings(options: options, source: source, destination: destination)
                settings.transform.copyAsFreeBusyOnly = true
                // Fan-out blocks carry only the busy title; --origin-title does not apply.
                settings.transform.freeBusyTitle = options.value("busy-title") ?? FreeBusyCompliance.fanOutTitle
                settings.transform.includeOriginCalendarInFreeBusyTitle = false
                settings.skipFreeSourceEvents = !options.hasFlag("include-free")
                settings.skipDeclinedSourceEvents = !options.hasFlag("include-declined")
                settings.skipWhenSourceOriginMatchesDestination = true
                let result = await engine.run(settings: settings)
                printSummary(label: "fan-out \(source.displayName) -> \(destination.displayName)", result: result)
                aggregate.merge(result)
            }

            printSummary(label: "fan-out total", result: aggregate, detail: false)
            return aggregate.failed == 0 ? 0 : 1
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 64
        }
    }

    private static func cycle(options: CLIOptions, engine: CoordinatedCalendarEngine) async -> Int32 {
        do {
            let consolidated = try resolveCalendar(options.requiredValue("consolidated"), engine: engine)
            var fanInOptions = options
            fanInOptions.set("to", value: consolidated.stableKey)
            var fanOutOptions = options
            fanOutOptions.set("from", value: consolidated.stableKey)

            let inCode = await fanIn(options: fanInOptions, engine: engine)
            let outCode = await fanOut(options: fanOutOptions, engine: engine)
            return inCode == 0 && outCode == 0 ? 0 : 1
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 64
        }
    }

    private static func syncGUISettings(options: CLIOptions, engine: CoordinatedCalendarEngine) async -> Int32 {
        do {
            let store: GUISettingsStore
            if let path = options.value("gui-settings") {
                store = try GUISettingsStore(fileURL: URL(fileURLWithPath: path))
            } else {
                store = try GUISettingsStore()
            }
            guard var saved = try store.load() else {
                throw CLIError.message("No GUI settings file was found.")
            }
            // Before anything else: a calendar that came back under a new identifier is re-attached here,
            // unattended, rather than failing every run until someone opens the app.
            let unreconciled = saved
            let reconciliation = saved.reconcileCalendars(with: engine.calendars())
            if saved != unreconciled {
                try store.save(saved)
            }
            for notice in reconciliation.notices {
                print(notice)
            }
            guard let consolidatedKey = saved.consolidatedCalendarKey else {
                throw CLIError.message("Saved GUI settings do not include a consolidated calendar.")
            }
            guard !saved.contributorCalendarKeys.isEmpty || !saved.recipientCalendarKeys.isEmpty else {
                throw CLIError.message("Saved GUI settings do not include any contributor or recipient calendars.")
            }

            // The scheduled job passes a rolling window; the saved GUI dates apply only when it is absent.
            let hasWindowOptions = options.value("window-days-past") != nil || options.value("window-days-future") != nil
            let startDate = try hasWindowOptions ? startDate(options: options) : (saved.startDate ?? startDate(options: options))
            let endDate = try hasWindowOptions ? endDate(options: options) : (saved.endDate ?? endDate(options: options))
            let dryRun = !options.hasFlag("execute")
            var aggregate = SyncResult()

            for sourceKey in saved.contributorCalendarKeys.sorted() where sourceKey != consolidatedKey {
                var settings = saved.fanInSettings(
                    sourceKey: sourceKey,
                    consolidatedKey: consolidatedKey,
                    startDate: startDate,
                    endDate: endDate,
                    dryRun: dryRun
                )
                if options.hasFlag("no-reconcile-deletions") {
                    settings.reconcileDeletions = false
                }
                let result = await engine.run(settings: settings)
                printSummary(
                    label: "gui fan-in \(calendarDisplayName(sourceKey, engine: engine)) -> \(calendarDisplayName(consolidatedKey, engine: engine))",
                    result: result
                )
                aggregate.merge(result)
            }

            for destinationKey in saved.recipientCalendarKeys.sorted() where destinationKey != consolidatedKey {
                var settings = saved.fanOutSettings(
                    consolidatedKey: consolidatedKey,
                    destinationKey: destinationKey,
                    availability: saved.recipientAvailabilities?[destinationKey] ?? .busy,
                    startDate: startDate,
                    endDate: endDate,
                    dryRun: dryRun
                )
                if options.hasFlag("no-reconcile-deletions") {
                    settings.reconcileDeletions = false
                }
                let result = await engine.run(settings: settings)
                printSummary(
                    label: "gui fan-out \(calendarDisplayName(consolidatedKey, engine: engine)) -> \(calendarDisplayName(destinationKey, engine: engine))",
                    result: result
                )
                aggregate.merge(result)
            }

            printSummary(label: dryRun ? "gui settings preview total" : "gui settings execute total", result: aggregate, detail: false)
            if !dryRun {
                SyncStatusStore.save(SyncRunStatus(finishedAt: Date(), result: aggregate))
            }
            return aggregate.failed == 0 ? 0 : 1
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 64
        }
    }

    private static func baseSettings(options: CLIOptions, source: CalendarIdentity, destination: CalendarIdentity) throws -> BridgeSettings {
        var transform = TransformSettings()
        transform.titlePrefix = options.value("title-prefix") ?? ""
        transform.titleSuffix = options.value("title-suffix") ?? ""
        transform.notesFooter = options.value("notes-footer") ?? ""
        transform.copyLocation = !options.hasFlag("no-location")
        transform.copyNotes = !options.hasFlag("no-notes")
        transform.copyURL = !options.hasFlag("no-url")
        transform.copyAsFreeBusyOnly = options.hasFlag("free-busy")
        transform.freeBusyTitle = options.value("busy-title") ?? "Busy"
        transform.includeOriginCalendarInFreeBusyTitle = options.hasFlag("origin-title")
        transform.includeSourceCalendarInTitle = options.hasFlag("source-title")
        transform.destinationAvailability = try availability(options: options)

        return BridgeSettings(
            sourceCalendarKey: source.stableKey,
            destinationCalendarKey: destination.stableKey,
            startDate: try startDate(options: options),
            endDate: try endDate(options: options),
            transform: transform,
            dryRun: !options.hasFlag("execute"),
            updateExistingCopies: options.hasFlag("update"),
            reconcileDeletions: options.hasFlag("reconcile-deletions")
        )
    }

    private static func run(settings: BridgeSettings, engine: CoordinatedCalendarEngine) async -> Int32 {
        let result = await engine.run(settings: settings) { progress, title in
            let percent = Int(progress * 100)
            print("[\(percent)%] \(title)")
        }
        printSummary(label: settings.dryRun ? "preview" : "execute", result: result)
        return result.failed == 0 ? 0 : 1
    }

    private static func delete(settings: BridgeSettings, engine: CoordinatedCalendarEngine) async -> Int32 {
        let result = await engine.deleteCopies(settings: settings) { progress, title in
            let percent = Int(progress * 100)
            print("[\(percent)%] \(title)")
        }
        printSummary(label: settings.dryRun ? "delete preview" : "delete execute", result: result)
        return result.failed == 0 ? 0 : 1
    }

    private static func selectedSources(options: CLIOptions, excluding destination: CalendarIdentity, engine: CoordinatedCalendarEngine) throws -> [CalendarIdentity] {
        if let selected = options.values("from"), !selected.isEmpty {
            return try selected.map { try resolveCalendar($0, engine: engine) }
                .filter { $0.stableKey != destination.stableKey }
        }
        let excluded = try excludedCalendarKeys(options: options, engine: engine)
        return engine.calendars().filter { $0.stableKey != destination.stableKey && !excluded.contains($0.stableKey) }
    }

    private static func selectedDestinations(options: CLIOptions, excluding source: CalendarIdentity, engine: CoordinatedCalendarEngine) throws -> [CalendarIdentity] {
        if let selected = options.values("to"), !selected.isEmpty {
            return try selected.map { try resolveCalendar($0, engine: engine) }
                .filter { $0.stableKey != source.stableKey && $0.allowsContentModifications }
        }
        let excluded = try excludedCalendarKeys(options: options, engine: engine)
        return engine.calendars().filter { $0.stableKey != source.stableKey && $0.allowsContentModifications && !excluded.contains($0.stableKey) }
    }

    private static func excludedCalendarKeys(options: CLIOptions, engine: CoordinatedCalendarEngine) throws -> Set<String> {
        let excluded = try (options.values("exclude") ?? []).map { try resolveCalendar($0, engine: engine).stableKey }
        return Set(excluded)
    }

    private static func resolveCalendar(_ selector: String, engine: CoordinatedCalendarEngine) throws -> CalendarIdentity {
        let calendars = engine.calendars()
        if let exact = calendars.first(where: { $0.stableKey == selector || $0.displayName == selector }) {
            return exact
        }
        let titleMatches = calendars.filter { $0.calendarTitle == selector }
        if titleMatches.count == 1, let match = titleMatches.first {
            return match
        }
        if titleMatches.count > 1 {
            throw CLIError.message("Calendar name \"\(selector)\" is ambiguous. Use --list-calendars and pass the stable key.")
        }
        throw CLIError.message("Calendar \"\(selector)\" was not found.")
    }

    private static func calendarDisplayName(_ key: String, engine: CoordinatedCalendarEngine) -> String {
        engine.calendars().first { $0.stableKey == key }?.displayName ?? key
    }

    private static func startDate(options: CLIOptions) throws -> Date {
        if let value = options.value("start") {
            return try parseDate(value)
        }
        let days = Int(options.value("window-days-past") ?? "30") ?? 30
        return Calendar.current.date(byAdding: .day, value: -days, to: Calendar.current.startOfDay(for: Date())) ?? Date()
    }

    private static func endDate(options: CLIOptions) throws -> Date {
        if let value = options.value("end") {
            return try parseDate(value)
        }
        let days = Int(options.value("window-days-future") ?? "365") ?? 365
        return Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
    }

    private static func parseDate(_ value: String) throws -> Date {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) {
            return date
        }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) {
            return date
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        if let date = formatter.date(from: value) {
            return date
        }
        throw CLIError.message("Could not parse date \"\(value)\". Use YYYY-MM-DD or ISO-8601.")
    }

    private static func availability(options: CLIOptions) throws -> DestinationAvailability {
        guard let value = options.value("availability") else {
            return .busy
        }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        let availability: DestinationAvailability? = switch normalized {
        case "preserve", "leave-as-is", "as-is":
            .preserve
        default:
            DestinationAvailability(rawValue: normalized)
        }
        guard let availability else {
            throw CLIError.message("Invalid --availability \"\(value)\". Use preserve, free, busy, or tentative.")
        }
        return availability
    }

    private static func installAgent(options: CLIOptions) throws -> Int32 {
        let consolidated = try options.requiredValue("consolidated")
        let interval = Int(options.value("interval") ?? "300") ?? 300
        // Through the same guard as every other job installation; this path used to skip it entirely.
        let executable = try SyncAgentInstaller.stableExecutablePath()
        let label = "io.github.tinleg.coordinatedcalendar.cycle"
        let plistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var arguments = [
            executable,
            "--cycle",
            "--consolidated", consolidated,
            "--execute",
            "--window-days-past", options.value("window-days-past") ?? "30",
            "--window-days-future", options.value("window-days-future") ?? "365"
        ]
        if let busyTitle = options.value("busy-title") {
            arguments.append(contentsOf: ["--busy-title", busyTitle])
        }
        if options.hasFlag("update") {
            arguments.append("--update")
        }
        if options.hasFlag("reconcile-deletions") {
            arguments.append("--reconcile-deletions")
        }
        if options.hasFlag("origin-title") {
            arguments.append("--origin-title")
        }
        for excluded in options.values("exclude") ?? [] {
            arguments.append(contentsOf: ["--exclude", excluded])
        }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": arguments,
            "StartInterval": interval,
            "RunAtLoad": true,
            "StandardOutPath": FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/CoordinatedCalendar.out.log").path,
            "StandardErrorPath": FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/CoordinatedCalendar.err.log").path
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: [.atomic])
        print("Wrote \(plistURL.path)")
        print("Load it with: launchctl bootstrap gui/$(id -u) \(plistURL.path)")
        return 0
    }

    private static func installSyncAgent(options: CLIOptions) throws -> Int32 {
        let saved = try GUISettingsStore().load()
        let interval = options.value("interval").flatMap(Int.init) ?? saved?.effectiveSyncInterval ?? 300
        let window: [String]
        if let past = options.value("window-days-past"), let future = options.value("window-days-future") {
            window = ["--window-days-past", past, "--window-days-future", future]
        } else {
            window = SyncAgentInstaller.relativeWindowArguments(start: saved?.startDate, end: saved?.endDate)
        }
        for url in try SyncAgentInstaller.install(interval: interval, windowArguments: window) {
            print("Installed and loaded \(url.path)")
        }
        return 0
    }

    /// Uninstall step. A preview by default; with --execute it removes the background jobs first, so a
    /// scheduled sync can't recreate anything, then every event this app created, in every calendar.
    private static func removeAllCopies(options: CLIOptions, engine: CoordinatedCalendarEngine) async -> Int32 {
        let execute = options.hasFlag("execute")
        if execute {
            do {
                let removed = try SyncAgentInstaller.removeAll()
                print("Removed \(removed) background job\(removed == 1 ? "" : "s").")
            } catch {
                fputs("Could not remove the background jobs, so nothing was deleted: \(error.localizedDescription)\n", stderr)
                return 1
            }
        }
        let window = CoordinatedCalendarEngine.removalWindow()
        let result = await engine.removeAllCopies(from: window.start, to: window.end, dryRun: !execute)
        printSummary(label: execute ? "remove all copies" : "remove all copies preview", result: result)
        if !execute {
            print("Nothing was changed. Add --execute to remove these events and the background jobs.")
        }
        return result.failed == 0 ? 0 : 1
    }

    private static func healthCheck(options: CLIOptions) -> Int32 {
        let maxAgeMinutes = Double(options.value("max-age-minutes") ?? "20") ?? 20
        let status = SyncStatusStore.load()
        let problems = SyncHealth.problems(status: status, now: Date(), maxAge: maxAgeMinutes * 60)
        if options.hasFlag("notify") {
            SyncStatusStore.notifyIfNeeded(problems: problems)
        }
        if problems.isEmpty, let status {
            print("healthy: last sync \(status.finishedAt.ISO8601Format()) scanned=\(status.scanned) create=\(status.created) updated=\(status.updated) delete=\(status.deleted) failed=0")
            return 0
        }
        for problem in problems {
            print("unhealthy: \(problem)")
        }
        return 1
    }

    private static func uninstallAgent() throws -> Int32 {
        let plistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/io.github.tinleg.coordinatedcalendar.cycle.plist")
        try? FileManager.default.removeItem(at: plistURL)
        print("Removed \(plistURL.path)")
        return 0
    }

    /// Totals pass `detail: false` because their per-route previews were already printed.
    private static func printSummary(label: String, result: SyncResult, detail: Bool = true) {
        if detail {
            for preview in result.previews where preview.action == .error || (verbose && preview.action != .skipDuplicate) {
                let route = [preview.sourceCalendarName, preview.destinationCalendarName].compactMap { $0 }.joined(separator: " -> ")
                let line = "\(preview.action.rawValue): \(route): \(preview.sourceTitle) @ \(preview.startDate.ISO8601Format()): \(preview.message)\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
        }
        print("\(label): scanned=\(result.scanned) create=\(result.created) delete=\(result.deleted) skipped=\(result.skipped) updated=\(result.updated) blocked=\(result.blocked) failed=\(result.failed)")
    }
}

private struct CLIOptions {
    private var storage: [String: [String]] = [:]
    var command: String?

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            guard token.hasPrefix("--") else {
                throw CLIError.message("Unexpected argument \"\(token)\".")
            }
            let key = String(token.dropFirst(2))
            if Self.commands.contains(key) {
                command = key
                index += 1
                continue
            }
            if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                storage[key, default: []].append(arguments[index + 1])
                index += 2
            } else {
                storage[key, default: []].append("true")
                index += 1
            }
        }
    }

    mutating func set(_ key: String, value: String) {
        storage[key] = [value]
    }

    func hasFlag(_ key: String) -> Bool {
        storage[key]?.contains("true") == true || command == key
    }

    func value(_ key: String) -> String? {
        storage[key]?.last
    }

    func values(_ key: String) -> [String]? {
        storage[key]
    }

    func requiredValue(_ key: String) throws -> String {
        guard let value = value(key), value != "true" else {
            throw CLIError.message("Missing required --\(key) value.")
        }
        return value
    }

    private static let commands: Set<String> = [
        "help",
        "health-check",
        "install-sync-agent",
        "list-calendars",
        "list-events",
        "remove-all-copies",
        "copy",
        "delete",
        "fan-in",
        "fan-out",
        "cycle",
        "sync-gui-settings",
        "install-agent",
        "uninstall-agent"
    ]
}

enum CLIError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}

private extension SyncResult {
    mutating func merge(_ other: SyncResult) {
        scanned += other.scanned
        created += other.created
        deleted += other.deleted
        skipped += other.skipped
        updated += other.updated
        blocked += other.blocked
        failed += other.failed
        previews.append(contentsOf: other.previews)
    }
}

private let helpText = """
CoordinatedCalendar script mode

Commands:
  --list-calendars
  --list-events --from CAL [--start D] [--end D]   Read-only: events with the identifiers identity is built from
  --copy --from CAL --to CAL [--execute] [--free-busy]
  --delete --from CAL --to CAL [--execute]
  --fan-in --to CONSOLIDATED [--from CAL ...] [--execute]
  --fan-out --from CONSOLIDATED [--to CAL ...] [--execute]
  --cycle --consolidated CAL [--execute]
  --sync-gui-settings [--execute] [--gui-settings PATH]
  --install-sync-agent [--interval SECONDS]  Replace all CoordinatedCalendar LaunchAgents with one sync job and a health check
  --health-check [--notify] [--max-age-minutes N]
  --remove-all-copies [--execute]  Uninstall: remove the background jobs and every event this app created
  --install-agent --consolidated CAL [--interval 300]
  --uninstall-agent

Calendar selectors can be a stable key from --list-calendars, a display name like "iCloud / Work", or an unambiguous calendar title.

Options:
  --start YYYY-MM-DD|ISO8601
  --end YYYY-MM-DD|ISO8601
  --window-days-past N       Default: 30
  --window-days-future N     Default: 365
  --execute                  Write changes. Without this, commands dry-run.
  --update                   Update prior CoordinatedCalendar copies if source/transform changed.
  --verbose                  Print each create/update/delete/blocked action to stderr (errors always print).
  --reconcile-deletions      Delete mapped destination copies whose source event disappeared.
  --free-busy                Copy as a busy block only.
  --busy-title TITLE         Busy block title. Default: Busy, or Busy - Other for fan-out.
  --include-free             Fan-out: also block time for events marked Free (skipped by default).
  --include-declined         Fan-out: also block time for meetings you declined (skipped by default).
  --availability VALUE       Destination event availability: preserve, free, busy, or tentative. Default: busy.
                             Also accepts leave-as-is.
  --source-title             Prefix full-detail copies as "Calendar: Title".
  --origin-title             Optional: include originating calendar in --copy --free-busy titles (not fan-out).
  --title-prefix TEXT
  --title-suffix TEXT
  --notes-footer TEXT
  --no-location
  --no-notes
  --no-url
  --exclude CAL              Exclude a calendar from fan-in/fan-out/cycle. Repeatable.
  --gui-settings PATH        Use a specific GUI settings JSON file.
  --no-reconcile-deletions   For --sync-gui-settings, disable deletion reconciliation.

Example:
  CoordinatedCalendar --cycle --consolidated "iCloud / Consolidated" --execute --window-days-past 7 --window-days-future 180
  CoordinatedCalendar --sync-gui-settings --execute
"""
