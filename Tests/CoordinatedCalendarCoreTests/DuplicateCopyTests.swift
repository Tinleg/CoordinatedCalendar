import CoordinatedCalendarCore
import Foundation
import Testing

private func candidate(_ copyID: String, created: Double?, external: String?, id: String) -> CoordinatedCalendarEngine.DuplicateCandidate {
    .init(copyID: copyID, creationDate: created.map(Date.init(timeIntervalSince1970:)), externalIdentifier: external, eventIdentifier: id)
}

@Test func duplicateCopiesKeepsEarliestCreatedCopy() {
    let surplus = CoordinatedCalendarEngine.duplicateCopies(in: [
        candidate("copy-a", created: 200, external: "ext-1", id: "later"),
        candidate("copy-a", created: 100, external: "ext-2", id: "earliest"),
        candidate("copy-a", created: 300, external: "ext-0", id: "latest"),
        candidate("copy-b", created: 100, external: "ext-3", id: "unique")
    ])

    #expect(surplus == ["later", "latest"])
}

@Test func duplicateCopiesBreaksTiesByCrossDeviceIdentifier() {
    // Two Macs listing the same copies in different orders must choose the same keeper.
    let copies = [
        candidate("copy-a", created: 100, external: "ext-b", id: "second"),
        candidate("copy-a", created: 100, external: "ext-a", id: "first")
    ]

    #expect(CoordinatedCalendarEngine.duplicateCopies(in: copies) == ["second"])
    #expect(CoordinatedCalendarEngine.duplicateCopies(in: copies.reversed()) == ["second"])
}

@Test func duplicateCopiesIgnoresSingleCopies() {
    #expect(CoordinatedCalendarEngine.duplicateCopies(in: [candidate("copy-a", created: nil, external: nil, id: "only")]).isEmpty)
}
