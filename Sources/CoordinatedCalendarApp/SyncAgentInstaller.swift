import CoordinatedCalendarCore
import Foundation

/// Installs the scheduled sync as one LaunchAgent running `--sync-gui-settings`, a watcher that starts it
/// when the calendars change, and a health check. Fan-in and fan-out run sequentially inside the one sync
/// job, and the watcher only ever starts that job, so runs never overlap.
enum SyncAgentInstaller {
    static let syncLabel = "io.github.tinleg.coordinatedcalendar.sync"
    static let healthLabel = "io.github.tinleg.coordinatedcalendar.health"
    static let watchLabel = "io.github.tinleg.coordinatedcalendar.watch"
    static let healthInterval = 900

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var launchAgentsURL: URL { home.appendingPathComponent("Library/LaunchAgents", isDirectory: true) }

    /// Returns the running executable, refusing any copy that is not in /Applications or ~/Applications.
    /// Background jobs record this path, so a copy that is later moved, deleted, ejected or cleaned away
    /// would leave them pointing at nothing — which is how syncing once stopped silently after a restart.
    static func stableExecutablePath() throws -> String {
        if let problem = installLocationProblem {
            throw CLIError.message(problem.message)
        }
        return (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath().path
    }

    /// Why this copy should not be the one background jobs point at, or nil when it is in place.
    static var installLocationProblem: InstallLocation.Problem? {
        InstallLocation.problem(
            forBundlePath: Bundle.main.bundleURL.resolvingSymlinksInPath().path,
            home: FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    /// Replaces every existing CoordinatedCalendar LaunchAgent with the sync and health agents. Returns the plist paths.
    @discardableResult
    static func install(interval: Int, windowArguments: [String]) throws -> [URL] {
        let executable = try stableExecutablePath()
        try removeAll()

        let syncURL = try writeAndLoad(
            label: syncLabel,
            interval: max(interval, 60),
            runAtLoad: true,
            arguments: [executable, "--sync-gui-settings", "--execute"] + windowArguments
        )
        // Not run at load: at install or login the first sync has not recorded a result yet.
        let healthURL = try writeAndLoad(
            label: healthLabel,
            interval: healthInterval,
            runAtLoad: false,
            arguments: [executable, "--health-check", "--notify", "--max-age-minutes", "\(max(interval, 60) * 4 / 60)"]
        )
        // Always running; restarted if it crashes, but not after exiting cleanly (it does when Calendar
        // access is missing, rather than failing again every few seconds).
        let watchURL = try writeAndLoad(
            label: watchLabel,
            interval: nil,
            runAtLoad: true,
            arguments: [executable, "--watch"],
            extra: ["KeepAlive": ["SuccessfulExit": false], "ProcessType": "Background", "ThrottleInterval": 30]
        )
        return [syncURL, healthURL, watchURL]
    }

    static let labelPrefix = "io.github.tinleg.coordinatedcalendar."

    /// Unloads and deletes every LaunchAgent this app installed.
    @discardableResult
    static func removeAll() throws -> Int {
        guard FileManager.default.fileExists(atPath: launchAgentsURL.path) else {
            return 0
        }
        let urls = try FileManager.default.contentsOfDirectory(at: launchAgentsURL, includingPropertiesForKeys: nil)
        var removed = 0
        for url in urls where url.pathExtension == "plist" && label(from: url)?.hasPrefix(labelPrefix) == true {
            _ = try? runLaunchctl(["bootout", service, url.path])
            try FileManager.default.removeItem(at: url)
            removed += 1
        }
        return removed
    }

    /// The window the installed sync job runs with, read from its plist; nil when there is none.
    static func installedSyncWindow() -> SyncWindow? {
        let url = launchAgentsURL.appendingPathComponent("\(syncLabel).plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String]
        else { return nil }
        return SyncWindow(arguments: arguments)
    }

    /// What an installed LaunchAgent does, read from its plist and from launchd.
    struct JobDetails: Identifiable, Equatable {
        let label: String
        let plistPath: String
        let interval: Int
        let runsAtLoad: Bool
        let arguments: [String]
        let logPath: String
        let errorLogPath: String
        /// launchd's view: nil when the job is installed but not loaded.
        var state: String?
        var runs: String?
        var lastExitCode: String?

        var id: String { label }
        var isLoaded: Bool { state != nil }
    }

    /// Every LaunchAgent this app installed, with launchd's current state for each.
    static func installedJobs() -> [JobDetails] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: launchAgentsURL, includingPropertiesForKeys: nil) else {
            return []
        }
        return urls
            .filter { $0.pathExtension == "plist" }
            .compactMap { url -> JobDetails? in
                guard let data = try? Data(contentsOf: url),
                      let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                      let label = plist["Label"] as? String, label.hasPrefix(labelPrefix)
                else { return nil }
                var job = JobDetails(
                    label: label,
                    plistPath: url.path,
                    interval: plist["StartInterval"] as? Int ?? 0,
                    runsAtLoad: plist["RunAtLoad"] as? Bool ?? false,
                    arguments: plist["ProgramArguments"] as? [String] ?? [],
                    logPath: plist["StandardOutPath"] as? String ?? "",
                    errorLogPath: plist["StandardErrorPath"] as? String ?? ""
                )
                let state = launchdState(label: label)
                job.state = state["state"]
                job.runs = state["runs"]
                job.lastExitCode = state["last exit code"]
                return job
            }
            .sorted { $0.label > $1.label }
    }

    /// Top-level `key = value` lines from `launchctl print` (state, runs, last exit code); empty if not loaded.
    private static func launchdState(label: String) -> [String: String] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "\(service)/\(label)"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [:] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for line in text.components(separatedBy: "\n") where line.hasPrefix("\t") && !line.hasPrefix("\t\t") {
            let parts = line.dropFirst().components(separatedBy: " = ")
            guard parts.count == 2, ["state", "runs", "last exit code"].contains(parts[0]), values[parts[0]] == nil else { continue }
            values[parts[0]] = parts[1]
        }
        return values
    }

    /// This executable's file number and modification time: different for every build that replaces it.
    /// Nil when the file is missing.
    static var executableIdentity: String? {
        guard let path = Bundle.main.executablePath,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        else { return nil }
        let number = attributes[.systemFileNumber].map { "\($0)" } ?? ""
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(number)-\(modified)"
    }

    static func isRunning(label: String) -> Bool {
        launchdState(label: label)["state"] == "running"
    }

    /// Starts a loaded job now. A job that is already running is left alone.
    static func startNow(label: String) throws {
        try runLaunchctl(["kickstart", "\(service)/\(label)"])
    }

    /// True when the jobs predate the change watcher and should be submitted again to add it.
    static var isMissingWatcher: Bool {
        isInstalled && !FileManager.default.fileExists(atPath: launchAgentsURL.appendingPathComponent("\(watchLabel).plist").path)
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: launchAgentsURL.appendingPathComponent("\(syncLabel).plist").path)
    }

    private static var service: String { "gui/\(getuid())" }

    private static func writeAndLoad(
        label: String,
        interval: Int?,
        runAtLoad: Bool,
        arguments: [String],
        extra: [String: Any] = [:]
    ) throws -> URL {
        try FileManager.default.createDirectory(at: launchAgentsURL, withIntermediateDirectories: true)
        let plistURL = launchAgentsURL.appendingPathComponent("\(label).plist")
        var plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": arguments,
            "RunAtLoad": runAtLoad,
            "StandardOutPath": home.appendingPathComponent("Library/Logs/\(label).log").path,
            "StandardErrorPath": home.appendingPathComponent("Library/Logs/\(label).err.log").path,
            // Ties the job to the app, so macOS names CoordinatedCalendar in "Background Items Added" and
            // in System Settings > General > Login Items, instead of an unattributed item that looks suspect.
            "AssociatedBundleIdentifiers": [Bundle.main.bundleIdentifier ?? "io.github.tinleg.coordinatedcalendar"]
        ]
        if let interval {
            plist["StartInterval"] = interval
        }
        plist.merge(extra) { _, new in new }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: [.atomic])
        _ = try? runLaunchctl(["bootout", service, plistURL.path])
        try runLaunchctl(["bootstrap", service, plistURL.path])
        return plistURL
    }

    private static func label(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else {
            return nil
        }
        return plist["Label"] as? String
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        if arguments.first == "bootout" {
            // Unloading a job that is not loaded is expected here; launchctl's complaint is noise.
            process.standardError = FileHandle.nullDevice
        }
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0, arguments.first != "bootout" {
            throw CLIError.message("launchctl \(arguments.joined(separator: " ")) failed.")
        }
        return process.terminationStatus
    }
}

/// Reads and writes the last-run status and alert state under Application Support.
enum SyncStatusStore {
    private static var directory: URL {
        (try? AppSupport.directory())
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/\(AppSupport.folderName)", isDirectory: true)
    }
    static var statusURL: URL { directory.appendingPathComponent("last-sync.json") }
    private static var signatureURL: URL { directory.appendingPathComponent("sync-signature.json") }

    /// What the calendars looked like when the last successful full sync started (see SyncSignature).
    static func loadSignature() -> SyncSignatureRecord? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: signatureURL)).flatMap { try? decoder.decode(SyncSignatureRecord.self, from: $0) }
    }

    /// Records a successful full sync, or with nil forgets it, so the next run is a full one.
    static func saveSignature(_ record: SyncSignatureRecord?) {
        guard let record else {
            try? FileManager.default.removeItem(at: signatureURL)
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(record).write(to: signatureURL, options: [.atomic])
    }
    private static var alertURL: URL { directory.appendingPathComponent("health-alert.json") }

    private struct AlertState: Codable {
        var problems: [String]
        var notifiedAt: Date
    }

    static func save(_ status: SyncRunStatus) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(status).write(to: statusURL, options: [.atomic])
    }

    static func load() -> SyncRunStatus? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: statusURL) else { return nil }
        return try? decoder.decode(SyncRunStatus.self, from: data)
    }

    /// Posts a notification when problems appear or change, repeats every 6 hours while they persist,
    /// and posts once when the sync recovers.
    static func notifyIfNeeded(problems: [String], now: Date = Date()) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let previous = (try? Data(contentsOf: alertURL)).flatMap { try? decoder.decode(AlertState.self, from: $0) }

        if problems.isEmpty {
            guard let previous, !previous.problems.isEmpty else { return }
            postNotification(title: "CoordinatedCalendar recovered", body: "Calendar sync is running normally again.")
            record(AlertState(problems: [], notifiedAt: now))
            return
        }

        let changed = previous?.problems.map(normalized) != problems.map(normalized)
        let due = previous.map { now.timeIntervalSince($0.notifiedAt) > 6 * 3600 } ?? true
        guard changed || due else { return }
        postNotification(title: "CoordinatedCalendar needs attention", body: problems.joined(separator: " "))
        record(AlertState(problems: problems, notifiedAt: now))
    }

    /// Ignores digits so a growing "N minutes ago" does not count as a new problem.
    private static func normalized(_ problem: String) -> String {
        problem.filter { !$0.isNumber }
    }

    private static func record(_ state: AlertState) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(state).write(to: alertURL, options: [.atomic])
    }

    private static func postNotification(title: String, body: String) {
        let escape = { (text: String) in
            text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "display notification \"\(escape(body))\" with title \"\(escape(title))\""]
        try? process.run()
        process.waitUntilExit()
    }
}
