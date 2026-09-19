import CoordinatedCalendarCore
import Foundation
import Testing

@Test func detailCopyTransformPreservesSelectedFields() {
    let transform = TransformSettings(
        titlePrefix: "[Copied] ",
        titleSuffix: " / shared",
        notesFooter: "Copied by CoordinatedCalendar"
    )

    #expect(transform.destinationTitle(for: "Design Review") == "[Copied] Design Review / shared")
    #expect(transform.destinationNotes(for: "Bring drawings") == "Bring drawings\n\nCopied by CoordinatedCalendar")
}

@Test func freeBusyTransformStripsMeetingDetails() {
    let transform = TransformSettings(
        titlePrefix: "[Copied] ",
        titleSuffix: " / shared",
        notesFooter: "Copied by CoordinatedCalendar",
        copyLocation: true,
        copyNotes: true,
        copyURL: true,
        copyAsFreeBusyOnly: true,
        freeBusyTitle: "Unavailable"
    )

    #expect(transform.destinationTitle(for: "Confidential Deal Review") == "Unavailable")
    #expect(transform.destinationNotes(for: "Sensitive notes") == nil)
}

@Test func freeBusyTransformFallsBackToBusyTitle() {
    let transform = TransformSettings(copyAsFreeBusyOnly: true, freeBusyTitle: "   ")

    #expect(transform.destinationTitle(for: "Anything") == "Busy")
}

@Test func freeBusyOriginTitleUsesCalendarColonTitleFormat() {
    let transform = TransformSettings(
        copyAsFreeBusyOnly: true,
        freeBusyTitle: "Busy",
        includeOriginCalendarInFreeBusyTitle: true
    )

    #expect(transform.destinationTitle(
        for: "Design Review",
        originCalendarName: "Work / Calendar"
    ) == "Work / Calendar: Design Review")
}

@Test func freeBusyOriginTitleFallsBackToBusyForBlankSourceTitle() {
    let transform = TransformSettings(
        copyAsFreeBusyOnly: true,
        freeBusyTitle: "Busy",
        includeOriginCalendarInFreeBusyTitle: true
    )

    #expect(transform.destinationTitle(
        for: "   ",
        originCalendarName: "Work / Calendar"
    ) == "Work / Calendar: Busy")
}

@Test func fullDetailSourceTitleUsesCalendarColonTitleFormat() {
    let transform = TransformSettings(includeSourceCalendarInTitle: true)

    #expect(transform.destinationTitle(
        for: "Design Review",
        sourceCalendarName: "Work / Calendar"
    ) == "Work / Calendar: Design Review")
}

@Test func fullDetailSourceTitleFallsBackToUntitledForBlankSourceTitle() {
    let transform = TransformSettings(includeSourceCalendarInTitle: true)

    #expect(transform.destinationTitle(
        for: "   ",
        sourceCalendarName: "Work / Calendar"
    ) == "Work / Calendar: Untitled")
}

@Test func freeBusyDefaultDoesNotExposeCalendarOrTitle() {
    let transform = TransformSettings(
        copyAsFreeBusyOnly: true,
        freeBusyTitle: "Busy",
        includeOriginCalendarInFreeBusyTitle: false
    )

    #expect(transform.destinationTitle(
        for: "Design Review",
        originCalendarName: "Work / Calendar"
    ) == "Busy")
}

@Test func transformSettingsDecodeDefaultsFreeBusyPrivacyForOlderConfigs() throws {
    let data = Data("""
    {
      "titlePrefix": "",
      "titleSuffix": "",
      "notesFooter": "",
      "copyLocation": true,
      "copyNotes": true,
      "copyURL": true,
      "copyAsFreeBusyOnly": true,
      "freeBusyTitle": "Busy",
      "includeOriginCalendarInFreeBusyTitle": false,
      "includeSourceCalendarInTitle": false
    }
    """.utf8)

    let transform = try JSONDecoder().decode(TransformSettings.self, from: data)

    #expect(transform.markFreeBusyEventsPrivate)
    #expect(transform.destinationAvailability == .busy)
}

@Test func transformSettingsStoresDestinationAvailability() {
    let transform = TransformSettings(destinationAvailability: .tentative)

    #expect(transform.destinationAvailability == .tentative)
    #expect(transform.destinationAvailability.displayName == "Tentative")
}

@Test func transformSettingsSupportsPreservingDestinationAvailability() {
    let transform = TransformSettings(destinationAvailability: .preserve)

    #expect(transform.destinationAvailability == .preserve)
    #expect(transform.destinationAvailability.displayName == "Leave As-Is")
}
