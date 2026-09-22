import AppKit
import EventKit
import CoordinatedCalendarCore
import Foundation

/// A report to attach to a bug report: versions, where the app runs from, which kinds of calendars are set
/// up and how, the background jobs, and recent sync results. Calendar and account names are replaced with
/// labels, event titles are removed, and nothing is sent anywhere — the person reads it and chooses to share.
enum DiagnosticsReport {
    static func make(engine: CoordinatedCalendarEngine, settingsStore: GUISettingsStore?) -> String {
        let calendars = engine.calendars()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let redactor = DiagnosticsRedactor(calendars: calendars, homeDirectory: home, userName: NSUserName())
        let settings = (try? settingsStore?.load()) ?? nil
        let info = Bundle.main.infoDictionary ?? [:]
        var lines: [String] = []

        lines.append("CoordinatedCalendar diagnostics, \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("Calendar and account names are replaced with labels; event titles are removed.")
        lines.append("")
        lines.append("App: \(info["CFBundleShortVersionString"] ?? "?") (build \(info["CFBundleVersion"] ?? "?"))")
        lines.append("Running from: \(Bundle.main.bundleURL.path)"
            + (SyncAgentInstaller.installLocationProblem.map { " — \(String(describing: $0))" } ?? " — ok"))
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString), \(machine())")
        lines.append("Calendar access: \(accessDescription(engine.authorizationStatus()))")

        lines.append("")
        lines.append("Calendars (\(calendars.count)):")
        for calendar in calendars.sorted(by: { redactor.label(forCalendarKey: $0.stableKey) < redactor.label(forCalendarKey: $1.stableKey) }) {
            var roles: [String] = []
            if settings?.consolidatedCalendarKey == calendar.stableKey { roles.append("consolidated") }
            if settings?.contributorCalendarKeys.contains(calendar.stableKey) == true { roles.append("fan-in") }
            if settings?.recipientCalendarKeys.contains(calendar.stableKey) == true {
                let availability = settings?.recipientAvailabilities?[calendar.stableKey].map { " (\($0.rawValue))" } ?? ""
                roles.append("fan-out\(availability)")
            }
            lines.append("  \(redactor.label(forCalendarKey: calendar.stableKey)): \(calendar.sourceType), "
                + "\(calendar.allowsContentModifications ? "writable" : "read-only"), "
                + "availability \(calendar.supportedAvailabilities.isEmpty ? "none" : calendar.supportedAvailabilities.joined(separator: ","))"
                + (roles.isEmpty ? "" : " — \(roles.joined(separator: ", "))"))
        }

        lines.append("")
        if let settings {
            let present = Set(calendars.map(\.stableKey))
            let missing = settings.selectedCalendarKeys.filter { !present.contains($0) }
            lines.append("Settings: \(settings.contributorCalendarKeys.count) fan-in, \(settings.recipientCalendarKeys.count) fan-out, "
                + "sync every \(settings.effectiveSyncInterval) s, busy title \"\(settings.effectiveFanOutTitle)\", "
                + "skip free \(settings.skipFreeEvents ?? true ? "yes" : "no"), skip declined \(settings.skipDeclinedEvents ?? true ? "yes" : "no")")
            lines.append("Selected but not currently available: \(missing.isEmpty ? "none" : "\(missing.count)")")
        } else {
            lines.append("Settings: none saved")
        }

        lines.append("")
        let jobs = SyncAgentInstaller.installedJobs()
        lines.append("Background jobs (\(jobs.count)):")
        for job in jobs {
            lines.append("  \(job.label): \(job.isLoaded ? "loaded" : "not loaded"), every \(job.interval) s, "
                + "runs \(job.runs ?? "?"), last exit \(job.lastExitCode ?? "?")")
        }
        if let sync = jobs.first(where: { $0.label == SyncAgentInstaller.syncLabel }) {
            lines.append("")
            lines.append("Recent sync results:")
            lines += tail(sync.logPath, lines: 12).map { "  " + $0 }
            let errors = tail(sync.errorLogPath, lines: 20)
            lines.append("")
            lines.append("Recent sync errors: \(errors.isEmpty ? "none" : "")")
            lines += errors.map { "  " + $0 }
        }
        if let health = jobs.first(where: { $0.label == SyncAgentInstaller.healthLabel }) {
            lines.append("")
            lines.append("Last health check: \(tail(health.logPath, lines: 1).first ?? "none")")
        }
        return redactor.redact(lines.joined(separator: "\n"))
    }

    static func copyToPasteboard(_ report: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    private static func tail(_ path: String, lines count: Int) -> [String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).suffix(count).map(String.init)
    }

    private static func machine() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var value = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.machine", &value, &size, nil, 0)
        return String(cString: value)
    }

    private static func accessDescription(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .fullAccess: "full access"
        case .writeOnly: "write-only (not enough)"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not asked yet"
        @unknown default: "unknown"
        }
    }
}
