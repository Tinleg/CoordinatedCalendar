import Foundation

/// The outcome of the last scheduled sync, written by `--sync-gui-settings --execute` for the health check.
public struct SyncRunStatus: Codable, Equatable, Sendable {
    public var finishedAt: Date
    public var scanned: Int
    public var created: Int
    public var updated: Int
    public var deleted: Int
    public var failed: Int
    public var errors: [String]

    public init(finishedAt: Date, result: SyncResult, errorLimit: Int = 20) {
        self.finishedAt = finishedAt
        scanned = result.scanned
        created = result.created
        updated = result.updated
        deleted = result.deleted
        failed = result.failed
        errors = result.previews.filter { $0.action == .error }.prefix(errorLimit).map(\.message)
    }
}

public enum SyncHealth {
    /// Problems worth alerting on: no recorded run, a run older than `maxAge`, or a run with failures.
    public static func problems(status: SyncRunStatus?, now: Date, maxAge: TimeInterval) -> [String] {
        guard let status else {
            return ["No CoordinatedCalendar sync run has been recorded."]
        }
        var problems: [String] = []
        let age = now.timeIntervalSince(status.finishedAt)
        if age > maxAge {
            problems.append("Last CoordinatedCalendar sync finished \(Int(age / 60)) minutes ago.")
        }
        if status.failed > 0 {
            let detail = status.errors.first.map { " First error: \($0)" } ?? ""
            problems.append("Last CoordinatedCalendar sync had \(status.failed) failure\(status.failed == 1 ? "" : "s").\(detail)")
        }
        return problems
    }
}
