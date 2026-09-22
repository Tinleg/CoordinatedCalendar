import CoordinatedCalendarCore
import Foundation
import Testing

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func date(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: text)!
}

@Test func theWindowMovesForwardWithTheDay() {
    let window = SyncWindow(daysPast: 732, daysFuture: 1489)
    let today = window.dates(now: date("2026-09-22T15:30:00Z"), calendar: utc)
    let tomorrow = window.dates(now: date("2026-09-23T09:00:00Z"), calendar: utc)

    #expect(today.start == date("2024-09-20T00:00:00Z"))
    // Through the whole of the last day.
    #expect(today.end == date("2030-10-21T00:00:00Z"))
    #expect(tomorrow.start == today.start.addingTimeInterval(86_400))
    #expect(tomorrow.end == today.end.addingTimeInterval(86_400))
}

@Test func datesBecomeDaysCountedFromToday() {
    let window = SyncWindow(start: date("2025-09-16T04:00:00Z"), end: date("2030-10-16T16:25:10Z"),
                            now: date("2026-09-22T12:00:00Z"), calendar: utc)
    #expect(window == SyncWindow(daysPast: 371, daysFuture: 1485))
}

@Test func aJobsArgumentsGiveItsWindow() {
    let arguments = ["/Applications/CoordinatedCalendar.app/Contents/MacOS/CoordinatedCalendar", "--sync-gui-settings",
                     "--execute", "--window-days-past", "732", "--window-days-future", "1489"]
    let window = SyncWindow(arguments: arguments)
    #expect(window == SyncWindow(daysPast: 732, daysFuture: 1489))
    #expect(window?.arguments == Array(arguments.suffix(4)))
    #expect(SyncWindow(arguments: ["--sync-gui-settings", "--window-days-past"]) == nil)
}

@Test func aWindowCannotRunBackwards() {
    #expect(SyncWindow(daysPast: -5, daysFuture: 0) == SyncWindow(daysPast: 0, daysFuture: 1))
}
