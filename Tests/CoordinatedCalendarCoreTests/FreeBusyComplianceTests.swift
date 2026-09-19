import CoordinatedCalendarCore
import CoreLocation
import EventKit
import Foundation
import Testing

nonisolated(unsafe) private let complianceEventStore = EKEventStore()

private let complianceMetadata = BridgeEventMetadata(
    copyID: "copy",
    sourceIdentity: "source",
    sourceCalendarName: "iCloud / Consolidated",
    sourceCalendarKeyHash: "sourceHash",
    destinationCalendarName: "Work / Calendar",
    originCalendarName: "iCloud / Projects",
    originCalendarKeyHash: "originHash",
    copyMode: "freeBusy",
    fingerprint: "fingerprint"
)

private func compliantCopy() -> EKEvent {
    let event = EKEvent(eventStore: complianceEventStore)
    event.title = FreeBusyCompliance.fanOutTitle
    event.startDate = Date(timeIntervalSince1970: 1_800_000_000)
    event.endDate = Date(timeIntervalSince1970: 1_800_003_600)
    event.notes = BridgeEventMetadata.notesByAddingMarker(to: nil, metadata: complianceMetadata)
    return event
}

@Test func freeBusyCopyWithOnlyTitleTimesAndMarkerIsCompliant() {
    #expect(FreeBusyCompliance.violations(of: compliantCopy(), expectedTitle: FreeBusyCompliance.fanOutTitle).isEmpty)
}

@Test func freeBusyComplianceFlagsEveryLeakedField() {
    let event = compliantCopy()
    event.title = "Board meeting"
    let place = EKStructuredLocation(title: "HQ")
    place.geoLocation = CLLocation(latitude: 35.2, longitude: -80.8)
    event.structuredLocation = place
    event.url = URL(string: "https://example.com/meeting")
    event.addAlarm(EKAlarm(relativeOffset: -600))
    event.notes = "Agenda\n\n" + (event.notes ?? "")

    #expect(
        FreeBusyCompliance.violations(of: event, expectedTitle: FreeBusyCompliance.fanOutTitle)
            == ["title", "location", "URL", "alarms", "notes"]
    )
}

@Test func freeBusyComplianceFlagsRecurrence() {
    let event = compliantCopy()
    event.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil))

    #expect(FreeBusyCompliance.violations(of: event, expectedTitle: FreeBusyCompliance.fanOutTitle) == ["recurrence"])
}

@Test func freeBusyStripLeavesOnlyBusyTitleTimesAndMarker() {
    let event = compliantCopy()
    event.title = "Board meeting"
    event.location = "HQ"
    event.url = URL(string: "https://example.com/meeting")
    event.addAlarm(EKAlarm(relativeOffset: -600))
    event.notes = "Agenda"

    FreeBusyCompliance.strip(event, metadata: complianceMetadata, expectedTitle: FreeBusyCompliance.fanOutTitle)

    #expect(FreeBusyCompliance.violations(of: event, expectedTitle: FreeBusyCompliance.fanOutTitle).isEmpty)
    #expect(BridgeEventMetadata.parse(from: event.notes) == complianceMetadata.withHashedCalendarNames)
    #expect(event.startDate == Date(timeIntervalSince1970: 1_800_000_000))
}

@Test func freeBusyComplianceSkipsTitleWhenOriginTitlesAreRequested() {
    let event = compliantCopy()
    event.title = "Work / Calendar: Planning"

    #expect(FreeBusyCompliance.violations(of: event, expectedTitle: nil).isEmpty)
}
