import Foundation

/// Makes a diagnostics report safe to paste into a public issue: calendar and account names become stable
/// labels, event titles are removed, and the home folder becomes "~". Everything else — counts, timings,
/// errors, versions — is kept, because that is what makes the report useful.
public struct DiagnosticsRedactor: Sendable {
    private let replacements: [(pattern: NSRegularExpression, label: String)]
    private let labels: [String: String]

    /// Groups macOS creates itself. Their names ("Other", "Subscribed Calendars") are not personal, and
    /// "Other" is an ordinary word: treating it as a name turned a busy title "Busy - Other" into
    /// "Busy - Account 5".
    public static let systemSourceTypes: Set<String> = ["birthdays", "subscribed", "local"]

    public init(calendars: [CalendarIdentity], homeDirectory: String, userName: String = "") {
        let accounts = Array(Set(calendars.map(\.sourceTitle))).sorted()
        let accountLabels = Dictionary(uniqueKeysWithValues: accounts.enumerated().map { ($1, "Account \($0 + 1)") })
        var labels: [String: String] = [:]
        var table: [(String, String)] = []
        for (index, calendar) in calendars.sorted(by: { $0.displayName < $1.displayName }).enumerated() {
            let label = "\(accountLabels[calendar.sourceTitle] ?? "Account") / Calendar \(index + 1)"
            labels[calendar.stableKey] = label
            table.append((calendar.displayName, label))
        }
        let personalAccounts = Set(calendars.filter { !Self.systemSourceTypes.contains($0.sourceType) }.map(\.sourceTitle))
        for (account, label) in accountLabels where !account.isEmpty && personalAccounts.contains(account) {
            table.append((account, label))
        }
        // The account name, wherever it appears — not only at the start of the home folder, since paths
        // elsewhere (a temporary folder, say) can carry it too.
        if !userName.isEmpty {
            table.append((userName, "user"))
        }
        // Longest first, so a full "Account / Calendar" name is replaced before its account part alone.
        // The home folder first, so it becomes "~" before the account name inside it is replaced on its own.
        let home = homeDirectory.isEmpty ? [] : [(try! NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: homeDirectory)), "~")]
        replacements = home + table.sorted { $0.0.count > $1.0.count }.compactMap { name, label in
            // Whole words only: an account called "Home" must not change "Homebrew".
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: name) + "(?![\\p{L}\\p{N}])"
            return (try? NSRegularExpression(pattern: pattern)).map { ($0, label) }
        }
        self.labels = labels
    }

    /// The label a calendar is shown under in the report.
    public func label(forCalendarKey key: String) -> String {
        labels[key] ?? "Unknown calendar"
    }

    public func redact(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { redactLine(String($0)) }.joined(separator: "\n")
    }

    // An action line: "<action>: <source> -> <destination>: <event title> @ <date>: <message>".
    private static let actionLine = try! NSRegularExpression(
        pattern: #"^([A-Za-z-]+): (.+?) -> (.+?): (.*) @ (\d{4}-\d\d-\d\dT[0-9:.]+Z): (.*)$"#)

    private func redactLine(_ line: String) -> String {
        var line = line
        let range = NSRange(line.startIndex..., in: line)
        if let match = Self.actionLine.firstMatch(in: line, range: range) {
            func group(_ index: Int) -> String { String(line[Range(match.range(at: index), in: line)!]) }
            let title = group(4)
            // Some messages repeat the title ("…copy of <title> needs updating"), so it goes from there too.
            let message = title.isEmpty ? group(6) : group(6).replacingOccurrences(of: title, with: "[event]")
            line = "\(group(1)): \(group(2)) -> \(group(3)): [event] @ \(group(5)): \(message)"
        }
        for (pattern, label) in replacements {
            line = pattern.stringByReplacingMatches(
                in: line, range: NSRange(line.startIndex..., in: line), withTemplate: NSRegularExpression.escapedTemplate(for: label))
        }
        return line
    }
}
