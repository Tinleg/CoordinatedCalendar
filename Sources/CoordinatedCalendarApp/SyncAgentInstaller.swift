import CoordinatedCalendarCore
import Foundation

/// Installs the scheduled sync as one LaunchAgent running `--sync-gui-settings`, plus an hourly-or-faster
/// health check. Fan-in and fan-out run sequentially inside that one job, so runs never overlap.
enum SyncAgentInstaller {
    static let syncLabel = "io.github.tinleg.coordinatedcalendar.sync"
    static let healthLabel = "io.github.tinleg.coordinatedcalendar.health"
    static let healthInterval = 900

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var launchAgentsURL: URL { home.appendingPathComponent("Library/LaunchAgents", isDirectory: true) }

    /// Returns the running executable, refusing temporary locations that macOS clears on restart.
    static func stableExecutablePath() throws -> String {
        let path = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath().path
        if path.hasPrefix("/private/tmp/") || path.hasPrefix("/tmp/") || path.hasPrefix("/private/var/folders/") {
            throw CLIError.message("CoordinatedCalendar is running from \(path), which macOS clears on restart. Run it from ~/Applications/CoordinatedCalendar.app before installing background jobs.")
        }
        return path
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
        return [syncURL, healthURL]
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

    /// Converts the saved GUI date range into a rolling window relative to today.
    static func relativeWindowArguments(start: Date?, end: Date?) -> [String] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let past = start.map { max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: $0), to: today).day ?? 30) } ?? 30
        let future = end.map { max(1, calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: $0)).day ?? 365) } ?? 365
        return ["--window-days-past", "\(past)", "--window-days-future", "\(future)"]
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

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: launchAgentsURL.appendingPathComponent("\(syncLabel).plist").path)
    }

    private static var service: String { "gui/\(getuid())" }

    private static func writeAndLoad(label: String, interval: Int, runAtLoad: Bool, arguments: [String]) throws -> URL {
        try FileManager.default.createDirectory(at: launchAgentsURL, withIntermediateDirectories: true)
        let plistURL = launchAgentsURL.appendingPathComponent("\(label).plist")
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": arguments,
            "StartInterval": interval,
            "RunAtLoad": runAtLoad,
            "StandardOutPath": home.appendingPathComponent("Library/Logs/\(label).log").path,
            "StandardErrorPath": home.appendingPathComponent("Library/Logs/\(label).err.log").path
        ]
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
