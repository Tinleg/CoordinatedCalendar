import CoordinatedCalendarCore
import Foundation
import Testing

private let notesMetadata = BridgeEventMetadata(
    copyID: "copy",
    sourceIdentity: "source",
    sourceCalendarName: "Work / Calendar",
    sourceCalendarKeyHash: "source-hash",
    destinationCalendarName: "iCloud / Consolidated",
    originCalendarName: "Work / Calendar",
    originCalendarKeyHash: "origin-hash",
    copyMode: "details",
    fingerprint: "fingerprint"
)

private func userNotes(in notes: String) -> String {
    BridgeEventMetadata.notesByRemovingMarker(from: notes)
}

@Test func fanInKeepsUserNotesVerbatim() {
    let written = "  Agenda:\n\n    1. Budget\n    2. Hiring\n\n\nBring the drawings."
    let transform = TransformSettings(includeSourceCalendarInTitle: true, destinationAvailability: .preserve)
    let copied = BridgeEventMetadata.notesByAddingMarker(to: transform.destinationNotes(for: written), metadata: notesMetadata)

    #expect(copied.hasPrefix(written))
    #expect(userNotes(in: copied) == written)
}

@Test func fanInKeepsWindowsLineEndingsAsSingleBreaks() {
    // Exchange notes often use CRLF; each must stay one line break, not become a blank line.
    let written = "Line one\r\nLine two\r\n\r\nLine four"
    let copied = BridgeEventMetadata.notesByAddingMarker(to: written, metadata: notesMetadata)
    let kept = userNotes(in: copied)

    #expect(kept.components(separatedBy: "Line two").count == 2)
    #expect(kept.replacingOccurrences(of: "\r\n", with: "\n") == "Line one\nLine two\n\nLine four")
}

@Test func fanInReplacesOnlyTheMarkerLineOnUpdate() {
    let written = "Notes that mention CoordinatedCalendar: the app, mid-line.\nSecond line."
    let first = BridgeEventMetadata.notesByAddingMarker(to: written, metadata: notesMetadata)
    let second = BridgeEventMetadata.notesByAddingMarker(to: first, metadata: notesMetadata)

    #expect(userNotes(in: second) == written)
    #expect(second.components(separatedBy: BridgeEventMetadata.markerPrefix).count == 3)
}

@Test func fanOutCarriesNoUserNotes() {
    let fanOut = TransformSettings(copyAsFreeBusyOnly: true, freeBusyTitle: FreeBusyCompliance.fanOutTitle)
    #expect(fanOut.destinationNotes(for: "Private agenda and passcode 1234") == nil)

    let busyNotes = BridgeEventMetadata.notesByAddingMarker(to: fanOut.destinationNotes(for: "Private agenda"), metadata: notesMetadata)
    #expect(userNotes(in: busyNotes).isEmpty)
    #expect(!busyNotes.contains("Private agenda"))
}
