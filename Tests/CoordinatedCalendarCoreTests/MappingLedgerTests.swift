import CoordinatedCalendarCore
import Foundation
import Testing

@Test func ledgerRoundTripsMappings() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CoordinatedCalendarTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("mappings.json")

    let sourceStart = Date(timeIntervalSince1970: 1_800_000_000)
    let ledger = try MappingLedger(fileURL: fileURL)
    ledger.upsert(EventMapping(
        sourceCalendarKey: "source",
        destinationCalendarKey: "destination",
        sourceEventIdentifier: "event-1",
        sourceStartDate: sourceStart,
        sourceLastModifiedDate: nil,
        fingerprint: "abc123",
        destinationEventIdentifier: "copy-1"
    ))
    try ledger.save()

    let reloaded = try MappingLedger(fileURL: fileURL)
    let mapping = reloaded.mapping(
        sourceCalendarKey: "source",
        destinationCalendarKey: "destination",
        sourceEventIdentifier: "event-1",
        sourceStartDate: sourceStart
    )

    #expect(mapping?.destinationEventIdentifier == "copy-1")
    #expect(mapping?.fingerprint == "abc123")
}

@Test func ledgerRemovesMappings() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CoordinatedCalendarTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("mappings.json")

    let sourceStart = Date(timeIntervalSince1970: 1_800_000_000)
    let ledger = try MappingLedger(fileURL: fileURL)
    let mapping = EventMapping(
        sourceCalendarKey: "source",
        destinationCalendarKey: "destination",
        sourceEventIdentifier: "event-1",
        sourceStartDate: sourceStart,
        sourceLastModifiedDate: nil,
        fingerprint: "abc123",
        destinationEventIdentifier: "copy-1"
    )
    ledger.upsert(mapping)
    ledger.remove(id: mapping.id)
    try ledger.save()

    let reloaded = try MappingLedger(fileURL: fileURL)
    #expect(reloaded.mapping(
        sourceCalendarKey: "source",
        destinationCalendarKey: "destination",
        sourceEventIdentifier: "event-1",
        sourceStartDate: sourceStart
    ) == nil)
}

@Test func ledgerFindsMappingsForCalendarPairInsideWindow() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CoordinatedCalendarTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("mappings.json")

    let inside = Date(timeIntervalSince1970: 1_800_000_000)
    let outside = Date(timeInterval: 86_400 * 10, since: inside)
    let ledger = try MappingLedger(fileURL: fileURL)
    ledger.upsert(EventMapping(
        sourceCalendarKey: "source",
        destinationCalendarKey: "destination",
        sourceEventIdentifier: "inside",
        sourceStartDate: inside,
        sourceLastModifiedDate: nil,
        fingerprint: "inside",
        destinationEventIdentifier: "copy-inside"
    ))
    ledger.upsert(EventMapping(
        sourceCalendarKey: "source",
        destinationCalendarKey: "destination",
        sourceEventIdentifier: "outside",
        sourceStartDate: outside,
        sourceLastModifiedDate: nil,
        fingerprint: "outside",
        destinationEventIdentifier: "copy-outside"
    ))

    let matches = ledger.mappings(
        sourceCalendarKey: "source",
        destinationCalendarKey: "destination",
        startDate: inside.addingTimeInterval(-1),
        endDate: inside.addingTimeInterval(1)
    )

    #expect(matches.map(\.destinationEventIdentifier) == ["copy-inside"])
}
