import CoordinatedCalendarCore
import Foundation
import Testing

@Test func bridgeEventMetadataRoundTripsFromNotesMarker() {
    let metadata = BridgeEventMetadata(
        copyID: "copy-123",
        sourceIdentity: "source-123",
        sourceCalendarName: "Consolidated",
        sourceCalendarKeyHash: "source-hash",
        destinationCalendarName: "Work",
        originCalendarName: "Personal",
        originCalendarKeyHash: "origin-hash",
        copyMode: "freeBusy",
        fingerprint: "fingerprint-123"
    )

    let notes = BridgeEventMetadata.notesByAddingMarker(to: "Visible notes", metadata: metadata)

    #expect(BridgeEventMetadata.parse(from: notes) == metadata.withHashedCalendarNames)
    #expect(notes.contains("Visible notes"))
}

@Test func bridgeEventMetadataRemovesPriorMarkerBeforeAddingNewOne() {
    let original = BridgeEventMetadata(
        copyID: "old",
        sourceIdentity: "source",
        sourceCalendarName: "Consolidated",
        sourceCalendarKeyHash: "source-hash",
        destinationCalendarName: "Work",
        originCalendarName: "Personal",
        originCalendarKeyHash: "origin-hash",
        copyMode: "freeBusy",
        fingerprint: "old-fingerprint"
    )
    let replacement = BridgeEventMetadata(
        copyID: "new",
        sourceIdentity: "source",
        sourceCalendarName: "Consolidated",
        sourceCalendarKeyHash: "source-hash",
        destinationCalendarName: "Work",
        originCalendarName: "Personal",
        originCalendarKeyHash: "origin-hash",
        copyMode: "freeBusy",
        fingerprint: "new-fingerprint"
    )

    let originalNotes = BridgeEventMetadata.notesByAddingMarker(to: "Visible notes", metadata: original)
    let replacedNotes = BridgeEventMetadata.notesByAddingMarker(to: originalNotes, metadata: replacement)

    #expect(BridgeEventMetadata.parse(from: replacedNotes) == replacement.withHashedCalendarNames)
    #expect(replacedNotes.components(separatedBy: BridgeEventMetadata.markerPrefix).count == 2)
}

@Test func bridgeEventMetadataSourceIdentityUsesExternalIDWhenPresent() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let first = BridgeEventMetadata.makeSourceIdentity(
        sourceCalendarName: "Work",
        sourceEventExternalIdentifier: "external-id",
        sourceEventIdentifier: "local-a",
        sourceStartDate: start
    )
    let second = BridgeEventMetadata.makeSourceIdentity(
        sourceCalendarName: "Work",
        sourceEventExternalIdentifier: "external-id",
        sourceEventIdentifier: "local-b",
        sourceStartDate: start
    )

    #expect(first == second)
}

@Test func bridgeEventMetadataRoundTripsAvailabilityIntent() {
    let metadata = BridgeEventMetadata(
        copyID: "copy-availability",
        sourceIdentity: "source-availability",
        sourceCalendarName: "Source",
        sourceCalendarKeyHash: "source-hash",
        destinationCalendarName: "Consolidated",
        originCalendarName: "Source",
        originCalendarKeyHash: "origin-hash",
        copyMode: "details",
        fingerprint: "fingerprint",
        sourceAvailability: "busy",
        intendedAvailability: "tentative"
    )

    let notes = BridgeEventMetadata.notesByAddingMarker(to: nil, metadata: metadata)
    let parsed = BridgeEventMetadata.parse(from: notes)

    #expect(parsed?.sourceAvailability == "busy")
    #expect(parsed?.intendedAvailability == "tentative")
}

private let namedMetadata = BridgeEventMetadata(
    copyID: "copy",
    sourceIdentity: "source",
    sourceCalendarName: "iCloud / Consolidated",
    sourceCalendarKeyHash: "source-hash",
    destinationCalendarName: "Client / Calendar",
    originCalendarName: "Work / Calendar",
    originCalendarKeyHash: "origin-hash",
    copyMode: "freeBusy",
    fingerprint: "fingerprint"
)

@Test func encodedMarkerContainsNoPlainCalendarNames() throws {
    let marker = namedMetadata.encodedMarker
    let payload = try #require(Data(base64Encoded: String(marker.dropFirst(BridgeEventMetadata.markerPrefix.count))))
    let json = try #require(String(data: payload, encoding: .utf8))

    for name in ["Consolidated", "Client", "Work", "iCloud"] {
        #expect(!json.contains(name))
    }
    #expect(BridgeEventMetadata.parse(from: marker)?.hasPlainCalendarNames == false)
}

@Test func storedCalendarNamesMatchInHashedAndOlderPlainForm() {
    let hashed = namedMetadata.withHashedCalendarNames

    #expect(BridgeEventMetadata.storedName(hashed.originCalendarName, matches: "Work / Calendar"))
    #expect(BridgeEventMetadata.storedName("Work / Calendar", matches: "Work / Calendar"))
    #expect(!BridgeEventMetadata.storedName(hashed.originCalendarName, matches: "Client / Calendar"))
    #expect(namedMetadata.hasPlainCalendarNames)
    #expect(hashed.withHashedCalendarNames == hashed)
}

@Test func hashedCalendarNamesResolveToKnownCalendars() {
    let stored = namedMetadata.withHashedCalendarNames.originCalendarName
    let known = ["iCloud / Consolidated", "Work / Calendar", "Client / Calendar"]

    #expect(BridgeEventMetadata.resolveStoredName(stored, among: known) == "Work / Calendar")
    #expect(BridgeEventMetadata.resolveStoredName(stored, among: ["Client / Calendar"]) == nil)
    #expect(BridgeEventMetadata.resolveStoredName("Work / Calendar", among: []) == "Work / Calendar")
}

@Test func declinedFlagIsOmittedFromMarkersUnlessSet() throws {
    func keys(_ metadata: BridgeEventMetadata) throws -> Set<String> {
        let marker = metadata.encodedMarker
        let data = try #require(Data(base64Encoded: String(marker.dropFirst(BridgeEventMetadata.markerPrefix.count))))
        return Set(try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys)
    }
    var declined = namedMetadata
    declined.declined = true

    #expect(!(try keys(namedMetadata)).contains("declined"))
    #expect(try keys(declined).contains("declined"))
    #expect(BridgeEventMetadata.parse(from: declined.encodedMarker)?.declined == true)
}

@Test func aDetailsMarkerCarriesItsSourceInTheClearThroughEncoding() {
    let metadata = BridgeEventMetadata(
        copyID: "copy",
        sourceIdentity: "identity",
        sourceCalendarName: "Work / Calendar",
        sourceCalendarKeyHash: "sourceHash",
        destinationCalendarName: "iCloud / Consolidated",
        originCalendarName: "Work / Calendar",
        originCalendarKeyHash: "originHash",
        copyMode: "details",
        fingerprint: "fingerprint",
        sourceEventID: "1B2C3D4E-0000-0000-0000-000000000001",
        sourceEventExternalID: "external-id",
        sourceCalendarPlainName: "Work / Calendar"
    )

    let parsed = BridgeEventMetadata.parse(from: BridgeEventMetadata.notesByAddingMarker(to: "Notes", metadata: metadata))
    #expect(parsed?.sourceEventID == "1B2C3D4E-0000-0000-0000-000000000001")
    #expect(parsed?.sourceEventExternalID == "external-id")
    // The hashed name is still hashed: nothing that reads markers today changes meaning.
    #expect(parsed?.sourceCalendarName.hasPrefix("sha256:") == true)
    #expect(parsed?.sourceCalendarPlainName == "Work / Calendar")
    #expect(parsed?.carriesSourceReference == true)
}

@Test func aMarkerWithoutSourceFieldsStillParsesAndCarriesNothing() {
    let metadata = BridgeEventMetadata(
        copyID: "copy",
        sourceIdentity: "identity",
        sourceCalendarName: "Work / Calendar",
        sourceCalendarKeyHash: "sourceHash",
        destinationCalendarName: "Client / Calendar",
        originCalendarName: "Work / Calendar",
        originCalendarKeyHash: "originHash",
        copyMode: "freeBusy",
        fingerprint: "fingerprint"
    )
    let parsed = BridgeEventMetadata.parse(from: metadata.encodedMarker)
    #expect(parsed?.carriesSourceReference == false)
    #expect(parsed?.sourceEventID == nil)
}
