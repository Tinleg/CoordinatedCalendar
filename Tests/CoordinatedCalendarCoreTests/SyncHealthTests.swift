import CoordinatedCalendarCore
import Foundation
import Testing

private let healthNow = Date(timeIntervalSince1970: 1_800_000_000)

@Test func syncHealthReportsMissingRun() {
    #expect(SyncHealth.problems(status: nil, now: healthNow, maxAge: 1200).count == 1)
}

@Test func syncHealthAcceptsRecentCleanRun() {
    let status = SyncRunStatus(finishedAt: healthNow.addingTimeInterval(-300), result: SyncResult())
    #expect(SyncHealth.problems(status: status, now: healthNow, maxAge: 1200).isEmpty)
}

@Test func syncHealthReportsStaleAndFailedRuns() {
    var result = SyncResult()
    result.failed = 2
    result.previews.append(SyncEventPreview(
        id: "1",
        sourceTitle: "Planning",
        destinationTitle: nil,
        startDate: healthNow,
        action: .error,
        message: "Object not found."
    ))
    let status = SyncRunStatus(finishedAt: healthNow.addingTimeInterval(-3600), result: result)
    let problems = SyncHealth.problems(status: status, now: healthNow, maxAge: 1200)

    #expect(problems.count == 2)
    #expect(problems[0].contains("60 minutes"))
    #expect(problems[1].contains("2 failures") && problems[1].contains("Object not found."))
}
