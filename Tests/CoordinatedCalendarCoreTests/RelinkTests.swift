import CoordinatedCalendarCore
import Foundation
import Testing

private let monday = Date(timeIntervalSince1970: 1_800_000_000)

private func candidate(_ id: String, _ title: String = "SEPAC Sales to Service",
                       start: Date = monday, minutes: Double = 60, allDay: Bool = false) -> CoordinatedCalendarEngine.RelinkCandidate {
    .init(id: id, title: title, startDate: start, endDate: start.addingTimeInterval(minutes * 60), isAllDay: allDay)
}

private func pairs(_ orphans: [CoordinatedCalendarEngine.RelinkCandidate],
                   _ sources: [CoordinatedCalendarEngine.RelinkCandidate]) -> [String] {
    CoordinatedCalendarEngine.relinks(orphans: orphans, sources: sources).map { "\($0.orphan)->\($0.source)" }
}

@Test func aCopyIsRelinkedToTheSameEventUnderANewIdentifier() {
    // Re-adding an account regenerates every event's identifiers; the event itself is unchanged.
    #expect(pairs([candidate("old-copy")], [candidate("new-source")]) == ["old-copy->new-source"])
}

@Test func eachCopyFindsItsOwnSourceAmongSeveral() {
    let later = monday.addingTimeInterval(86_400)
    #expect(pairs(
        [candidate("copy-a"), candidate("copy-b", "Orientation", start: later)],
        [candidate("source-b", "Orientation", start: later), candidate("source-a")]
    ) == ["copy-a->source-a", "copy-b->source-b"])
}

@Test func anythingLessThanAnExactMatchIsNotRelinked() {
    #expect(pairs([candidate("copy")], [candidate("source", "SEPAC Sales")]).isEmpty, "title differs")
    #expect(pairs([candidate("copy")], [candidate("source", minutes: 30)]).isEmpty, "end differs")
    #expect(pairs([candidate("copy")], [candidate("source", start: monday.addingTimeInterval(60))]).isEmpty, "start differs")
    #expect(pairs([candidate("copy")], [candidate("source", allDay: true)]).isEmpty, "all-day differs")
}

@Test func twoCandidatesForOneCopyIsAGuessAndIsRefused() {
    // Two real events with the same title and times: picking one would guess.
    #expect(pairs([candidate("copy")], [candidate("source-1"), candidate("source-2")]).isEmpty)
}

@Test func twoCopiesWantingOneSourceIsRefused() {
    #expect(pairs([candidate("copy-1"), candidate("copy-2")], [candidate("source")]).isEmpty)
}
