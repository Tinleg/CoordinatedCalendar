import CoordinatedCalendarCore
import Testing

private typealias Available = CalendarRebinding.Available

@Test func aCalendarThatCameBackUnderANewIdentifierIsRebound() {
    // Removing and re-adding an account gives its calendars new identifiers; the names survive.
    let rebinds = CalendarRebinding.rebinds(
        selected: ["old-godlan", "hazletts"],
        recordedNames: ["old-godlan": "Godlan / Calendar", "hazletts": "Hazletts / Calendar"],
        available: [Available(key: "new-godlan", name: "Godlan / Calendar"),
                    Available(key: "hazletts", name: "Hazletts / Calendar")])
    #expect(rebinds == ["old-godlan": "new-godlan"])
}

@Test func aNameCarriedByTwoCalendarsIsNotGuessedBetween() {
    let rebinds = CalendarRebinding.rebinds(
        selected: ["old"], recordedNames: ["old": "Work / Calendar"],
        available: [Available(key: "a", name: "Work / Calendar"), Available(key: "b", name: "Work / Calendar")])
    #expect(rebinds.isEmpty)
}

@Test func aCalendarAlreadySelectedIsNotTakenOver() {
    let rebinds = CalendarRebinding.rebinds(
        selected: ["old", "current"], recordedNames: ["old": "Work / Calendar"],
        available: [Available(key: "current", name: "Work / Calendar")])
    #expect(rebinds.isEmpty)
}

@Test func twoVanishedCalendarsWantingOneReplacementGetNeither() {
    let rebinds = CalendarRebinding.rebinds(
        selected: ["old-1", "old-2"], recordedNames: ["old-1": "Work / Calendar", "old-2": "Work / Calendar"],
        available: [Available(key: "new", name: "Work / Calendar")])
    #expect(rebinds.isEmpty)
}

@Test func withoutARecordedNameNothingIsRebound() {
    // Settings saved before names were recorded: there is nothing to match on.
    let rebinds = CalendarRebinding.rebinds(
        selected: ["old"], recordedNames: [:], available: [Available(key: "new", name: "Godlan / Calendar")])
    #expect(rebinds.isEmpty)
}

@Test func whatCannotBeReboundIsReportedNotDropped() {
    let available = [Available(key: "here", name: "Here / Calendar")]
    let missing = CalendarRebinding.stillMissing(
        selected: ["here", "gone", "moved"], recordedNames: ["gone": "Offline / Calendar", "moved": "Moved / Calendar"],
        available: available, rebinds: ["moved": "somewhere"])
    #expect(missing.map(\.key) == ["gone"])
    #expect(missing.first?.name == "Offline / Calendar")
}
