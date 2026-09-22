import CoordinatedCalendarCore
import Testing

private func calendar(_ account: String, _ title: String, id: String) -> CalendarIdentity {
    CalendarIdentity(sourceIdentifier: account, sourceTitle: account, sourceType: "exchange", calendarIdentifier: id,
                     calendarTitle: title, allowsContentModifications: true, supportedAvailabilities: ["busy"])
}

private let redactor = DiagnosticsRedactor(
    calendars: [calendar("Godlan", "Calendar", id: "1"), calendar("ETV Inbox", "Consolidated", id: "2"),
                calendar("Home", "Calendar", id: "3")],
    homeDirectory: "/Users/someone")

@Test func calendarAndAccountNamesBecomeStableLabels() {
    let line = "gui fan-in Godlan / Calendar -> ETV Inbox / Consolidated: scanned=307 create=0 failed=0"
    let redacted = redactor.redact(line)
    #expect(!redacted.contains("Godlan") && !redacted.contains("ETV Inbox"))
    #expect(redacted.contains("scanned=307 create=0 failed=0"), "the useful part stays")
    #expect(redactor.redact("Account Godlan was re-added") == "Account \(redactor.label(forCalendarKey: "Godlan::1").split(separator: " / ")[0]) was re-added")
}

@Test func ordinaryWordsThatContainAnAccountNameAreLeftAlone() {
    // An account named "Home" must not turn "Homebrew" or "home folder" into labels... but "Home" alone is a name.
    #expect(redactor.redact("installed with Homebrew") == "installed with Homebrew")
    #expect(redactor.redact("Calendar access: authorized") == "Calendar access: authorized",
            "a calendar title on its own is a common word and is not treated as a name")
}

@Test func eventTitlesAreRemovedFromActionLines() {
    let line = "error: Godlan / Calendar -> ETV Inbox / Consolidated: Salary review with Dana @ 2026-09-25T20:30:00Z: Existing copy of Salary review with Dana needs updating"
    let redacted = redactor.redact(line)
    #expect(!redacted.contains("Salary") && !redacted.contains("Dana"))
    #expect(redacted.hasPrefix("error: ") && redacted.contains("[event] @ 2026-09-25T20:30:00Z: Existing copy of [event] needs updating"))
}

@Test func theHomeFolderIsShortened() {
    #expect(redactor.redact("/Users/someone/Library/Logs/sync.log") == "~/Library/Logs/sync.log")
}

@Test func macOSBuiltInGroupNamesAreNotTreatedAsPersonal() {
    // macOS calls its Birthdays group "Other"; replacing that word turned "Busy - Other" into "Busy - Account 5".
    let withSystemGroups = DiagnosticsRedactor(
        calendars: [calendar("Godlan", "Calendar", id: "1"),
                    CalendarIdentity(sourceIdentifier: "birthdays", sourceTitle: "Other", sourceType: "birthdays",
                                     calendarIdentifier: "b", calendarTitle: "Birthdays", allowsContentModifications: false,
                                     supportedAvailabilities: [])],
        homeDirectory: "/Users/someone")
    #expect(withSystemGroups.redact(#"busy title "Busy - Other""#) == #"busy title "Busy - Other""#)
}

@Test func theAccountNameIsRemovedEvenOutsideTheHomeFolder() {
    let withUser = DiagnosticsRedactor(calendars: [], homeDirectory: "/Users/someone", userName: "someone")
    #expect(withUser.redact("/private/tmp/build-someone-1/CoordinatedCalendar.app") == "/private/tmp/build-user-1/CoordinatedCalendar.app")
    #expect(withUser.redact("/Users/someone/Applications") == "~/Applications")
}
