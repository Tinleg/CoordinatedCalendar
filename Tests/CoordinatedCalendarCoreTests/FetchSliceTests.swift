import CoordinatedCalendarCore
import Foundation
import Testing

@Test func fetchSlicesCoverLongWindowsInYearSteps() {
    let formatter = ISO8601DateFormatter()
    let start = formatter.date(from: "2024-09-16T04:00:00Z")!
    let end = formatter.date(from: "2030-10-01T04:00:00Z")!
    let slices = CoordinatedCalendarEngine.fetchSlices(from: start, to: end)

    #expect(slices.count == 7)
    #expect(slices.first?.start == start)
    #expect(slices.last?.end == end)
    for (previous, next) in zip(slices, slices.dropFirst()) {
        #expect(previous.end == next.start)
    }
    // Every slice stays well under EventKit's four-year predicate limit.
    #expect(slices.allSatisfy { $0.end.timeIntervalSince($0.start) <= 366 * 86_400 })
}

@Test func fetchSlicesHandleShortAndEmptyWindows() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(CoordinatedCalendarEngine.fetchSlices(from: start, to: start.addingTimeInterval(3600)).count == 1)
    #expect(CoordinatedCalendarEngine.fetchSlices(from: start, to: start).isEmpty)
}
