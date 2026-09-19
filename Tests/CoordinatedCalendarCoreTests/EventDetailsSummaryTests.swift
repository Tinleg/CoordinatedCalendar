import CoordinatedCalendarCore
import EventKit
import Foundation
import Testing

@Test func detailsSummaryIsNilForPlainEvents() {
    #expect(EventDetailsSummary.text(organizer: nil, attendees: [], status: nil, recurrence: nil) == nil)
}

@Test func detailsSummaryListsStatusOrganizerAttendeesAndRecurrence() {
    let text = EventDetailsSummary.text(
        organizer: .init(name: "Pat Lee", email: "pat@example.com", status: nil),
        attendees: [
            .init(name: "Alex", email: "alex@example.com", status: "accepted"),
            .init(name: nil, email: "room@example.com", status: "no response"),
            .init(name: "sam@example.com", email: "sam@example.com", status: nil)
        ],
        status: "canceled",
        recurrence: "every week on Mon"
    )

    #expect(text == """
    Source details:
    Status: canceled
    Organizer: Pat Lee <pat@example.com>
    Attendees: Alex <alex@example.com> (accepted); room@example.com (no response); sam@example.com
    Repeats: every week on Mon
    """)
}

@Test func detailsSummaryCapsLongAttendeeLists() {
    let attendees = (10...64).map { EventDetailsSummary.Participant(name: nil, email: "p\($0)@example.com", status: nil) }
    let text = EventDetailsSummary.text(organizer: nil, attendees: attendees, status: nil, recurrence: nil) ?? ""

    #expect(text.hasSuffix("p59@example.com; and 5 more"))
}

@Test func recurrenceDescriptionReadsNaturally() {
    let until = ISO8601DateFormatter().date(from: "2026-12-31T12:00:00Z")
    #expect(EventDetailsSummary.recurrenceDescription(frequency: .weekly, interval: 1, weekdays: [], until: nil, count: nil) == "every week")
    #expect(
        EventDetailsSummary.recurrenceDescription(frequency: .weekly, interval: 2, weekdays: [4, 2], until: until, count: nil)
            == "every 2 weeks on Mon, Wed until 2026-12-31"
    )
    #expect(EventDetailsSummary.recurrenceDescription(frequency: .monthly, interval: 1, weekdays: [], until: nil, count: 6) == "every month, 6 times")
}

@Test func detailsSummaryIgnoresAttendeeOrder() {
    let first = EventDetailsSummary.Participant(name: "Jordan Lee", email: "jordan@example.com", status: "tentative")
    let second = EventDetailsSummary.Participant(name: "Alex Rivera", email: "alex@example.com", status: "accepted")

    #expect(
        EventDetailsSummary.text(organizer: nil, attendees: [first, second], status: nil, recurrence: nil)
            == EventDetailsSummary.text(organizer: nil, attendees: [second, first], status: nil, recurrence: nil)
    )
}

@Test func detailsSummaryRecordsYourDeclinedResponse() {
    let text = EventDetailsSummary.text(organizer: nil, attendees: [], status: nil, recurrence: nil, declinedByYou: true)
    #expect(text == "Source details:\nYour response: declined")
    #expect(EventDetailsSummary.text(organizer: nil, attendees: [], status: nil, recurrence: nil, declinedByYou: false) == nil)
}
