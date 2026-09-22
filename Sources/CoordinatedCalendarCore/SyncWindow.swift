import Foundation

/// The span of days a sync covers, counted from today, so it moves forward with the calendar. The app,
/// its settings file and the background job all hold the window this way; fixed dates in one place and
/// day counts in another used to drift apart (2026-09-22: the job covered two years back while the app,
/// on its next Submit, would have cut that to one).
public struct SyncWindow: Codable, Equatable, Sendable {
    public var daysPast: Int
    public var daysFuture: Int

    public static let standard = SyncWindow(daysPast: 30, daysFuture: 365)

    public init(daysPast: Int, daysFuture: Int) {
        self.daysPast = max(0, daysPast)
        self.daysFuture = max(1, daysFuture)
    }

    /// The window that, today, runs from `start` to `end`.
    public init(start: Date, end: Date, now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        self.init(
            daysPast: calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: today).day ?? 30,
            daysFuture: calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: end)).day ?? 365
        )
    }

    /// From midnight `daysPast` days ago to the end of the day `daysFuture` days ahead.
    public func dates(now: Date = Date(), calendar: Calendar = .current) -> (start: Date, end: Date) {
        let today = calendar.startOfDay(for: now)
        return (
            calendar.date(byAdding: .day, value: -daysPast, to: today) ?? today,
            calendar.date(byAdding: .day, value: daysFuture + 1, to: today) ?? today
        )
    }

    public var arguments: [String] {
        ["--window-days-past", "\(daysPast)", "--window-days-future", "\(daysFuture)"]
    }

    /// The window a job's arguments give, or nil if they give none.
    public init?(arguments: [String]) {
        func value(_ flag: String) -> Int? {
            arguments.firstIndex(of: flag).flatMap { index in
                arguments.indices.contains(index + 1) ? Int(arguments[index + 1]) : nil
            }
        }
        guard let past = value("--window-days-past"), let future = value("--window-days-future") else {
            return nil
        }
        self.init(daysPast: past, daysFuture: future)
    }
}
