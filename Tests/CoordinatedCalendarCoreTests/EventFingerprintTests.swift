import CoordinatedCalendarCore
import CoreLocation
import EventKit
import Foundation
import Testing

@Test func fingerprintIsDeterministic() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let end = Date(timeInterval: 3600, since: start)

    let first = EventFingerprint.fingerprint(
        sourceCalendarKey: "icloud::work",
        title: "Planning",
        startDate: start,
        endDate: end,
        isAllDay: false,
        location: "Office",
        url: URL(string: "https://example.com"),
        recurrenceRuleDescriptions: ["weekly"]
    )
    let second = EventFingerprint.fingerprint(
        sourceCalendarKey: "icloud::work",
        title: "Planning",
        startDate: start,
        endDate: end,
        isAllDay: false,
        location: "Office",
        url: URL(string: "https://example.com"),
        recurrenceRuleDescriptions: ["weekly"]
    )

    #expect(first == second)
}

@Test func fingerprintChangesWhenSourceEventChanges() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let end = Date(timeInterval: 3600, since: start)

    let original = EventFingerprint.fingerprint(
        sourceCalendarKey: "icloud::work",
        title: "Planning",
        startDate: start,
        endDate: end,
        isAllDay: false,
        location: nil,
        url: nil,
        recurrenceRuleDescriptions: []
    )
    let changed = EventFingerprint.fingerprint(
        sourceCalendarKey: "icloud::work",
        title: "Planning moved",
        startDate: start,
        endDate: end,
        isAllDay: false,
        location: nil,
        url: nil,
        recurrenceRuleDescriptions: []
    )

    #expect(original != changed)
}

@Test func fingerprintChangesWhenTransformChanges() {
    let sourceFingerprint = EventFingerprint.hash(parts: ["source-event"])
    let detailFingerprint = EventFingerprint.hash(parts: [
        sourceFingerprint,
        TransformSettings().destinationTitle(for: "Planning"),
        TransformSettings().destinationNotes(for: "Notes") ?? "",
        "fullDetails",
        "copyLocation",
        "copyURL"
    ])
    let freeBusy = TransformSettings(copyAsFreeBusyOnly: true, freeBusyTitle: "Busy")
    let freeBusyFingerprint = EventFingerprint.hash(parts: [
        sourceFingerprint,
        freeBusy.destinationTitle(for: "Planning"),
        freeBusy.destinationNotes(for: "Notes") ?? "",
        "freeBusy",
        "copyLocation",
        "copyURL"
    ])

    #expect(detailFingerprint != freeBusyFingerprint)
}

nonisolated(unsafe) private let placeEventStore = EKEventStore()

private func placeTestEvent(latitude: Double? = nil, longitude: Double? = nil) -> EKEvent {
    let event = EKEvent(eventStore: placeEventStore)
    event.title = "Coffee"
    event.startDate = Date(timeIntervalSince1970: 1_800_000_000)
    event.endDate = Date(timeIntervalSince1970: 1_800_003_600)
    event.location = "Blue Bottle Coffee"
    if let latitude, let longitude {
        let place = EKStructuredLocation(title: "Blue Bottle Coffee")
        place.geoLocation = CLLocation(latitude: latitude, longitude: longitude)
        event.structuredLocation = place
    }
    return event
}

private func placeTestFingerprint(_ event: EKEvent, transform: TransformSettings = TransformSettings()) -> String {
    EventFingerprint.fingerprint(event: event, sourceCalendarKey: "icloud::work", transform: transform)
}

@Test func fingerprintWithoutPlaceIsUnchangedFromPriorReleases() {
    #expect(placeTestFingerprint(placeTestEvent()) == "ee39ff6c4c7364a6bea7e64d563f3075b8b7e7f1e9f530be69e6c9fea31fdd1e")
}

@Test func fingerprintChangesWhenPlaceCoordinatesAreAddedOrMoved() {
    let plain = placeTestFingerprint(placeTestEvent())
    let placed = placeTestFingerprint(placeTestEvent(latitude: 42.36, longitude: -71.06))
    let moved = placeTestFingerprint(placeTestEvent(latitude: 42.37, longitude: -71.06))

    #expect(plain != placed)
    #expect(placed != moved)
    #expect(placed == placeTestFingerprint(placeTestEvent(latitude: 42.36, longitude: -71.06)))
}

@Test func fingerprintIgnoresPlaceWhenLocationIsNotCopied() {
    let freeBusy = TransformSettings(copyAsFreeBusyOnly: true, freeBusyTitle: "Busy")
    var noLocation = TransformSettings()
    noLocation.copyLocation = false

    for transform in [freeBusy, noLocation] {
        #expect(
            placeTestFingerprint(placeTestEvent(), transform: transform)
                == placeTestFingerprint(placeTestEvent(latitude: 42.36, longitude: -71.06), transform: transform)
        )
    }
}

@Test func aRecurringEventHasTheSameFingerprintEveryTime() {
    // Two rule objects for the same rule live at two addresses, as they do in two sync runs.
    let store = EKEventStore()
    func weeklyOnFriday() -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.title = "Weekly sync"
        event.startDate = Date(timeIntervalSince1970: 1_800_000_000)
        event.endDate = Date(timeIntervalSince1970: 1_800_001_800)
        event.addRecurrenceRule(EKRecurrenceRule(
            recurrenceWith: .weekly, interval: 1, daysOfTheWeek: [EKRecurrenceDayOfWeek(.friday)],
            daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil,
            setPositions: nil, end: nil))
        return event
    }
    let first = weeklyOnFriday(), second = weeklyOnFriday()
    #expect(first.recurrenceRules?.first?.description != second.recurrenceRules?.first?.description,
            "the raw descriptions differ by address, which is the whole problem")
    #expect(EventFingerprint.fingerprint(event: first, sourceCalendarKey: "godlan")
            == EventFingerprint.fingerprint(event: second, sourceCalendarKey: "godlan"))
    let stable = EventFingerprint.stableDescription(of: first.recurrenceRules![0])
    #expect(!stable.contains("0x") && stable.hasSuffix("RRULE FREQ=WEEKLY;INTERVAL=1;BYDAY=FR"),
            "the rule itself is kept; only the address goes")
}
