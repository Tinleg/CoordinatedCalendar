import CoordinatedCalendarCore
import EventKit
import Foundation

/// An in-memory stand-in for EventKit, close enough to exercise the engine end to end. Like EventKit,
/// every fetch returns fresh objects, so a change the engine makes to an event exists only once it saves
/// it; saving assigns identifiers the first time; and a query returns events overlapping its window.
final class FakeCalendarStore: CalendarEventStore {
    private(set) var calendars: [FakeCalendar] = []
    private var records: [String: FakeEvent] = [:]
    private var nextID = 1
    private(set) var saves = 0
    private(set) var removals = 0
    /// Makes every save and removal fail, as a read-only or unreachable account would.
    var failWrites = false

    struct WriteRefused: LocalizedError {
        var errorDescription: String? { "The fake store refused the write" }
    }

    @discardableResult
    func addCalendar(account: String, title: String, writable: Bool = true, id: String? = nil) -> FakeCalendar {
        let calendar = FakeCalendar(
            identity: CalendarIdentity(
                sourceIdentifier: "source-\(account)-\(id ?? "1")",
                sourceTitle: account,
                sourceType: "exchange",
                calendarIdentifier: "calendar-\(account)-\(title)-\(id ?? "1")",
                calendarTitle: title,
                allowsContentModifications: writable
            )
        )
        calendars.append(calendar)
        return calendar
    }

    func removeCalendar(_ calendar: FakeCalendar) {
        calendars.removeAll { $0 === calendar }
        records = records.filter { $0.value.calendar !== calendar }
    }

    /// Adds an event as the calendar's account would, outside the engine.
    @discardableResult
    func addEvent(
        to calendar: FakeCalendar,
        title: String,
        start: Date,
        minutes: Double = 60,
        availability: EKEventAvailability = .busy,
        notes: String? = nil,
        location: String? = nil,
        created: Date? = nil
    ) -> String {
        let event = FakeEvent()
        event.title = title
        event.startDate = start
        event.endDate = start.addingTimeInterval(minutes * 60)
        event.availability = availability
        event.notes = notes
        event.location = location
        event.calendar = calendar
        assignIdentifiers(event)
        event.creationDate = created ?? event.creationDate
        records[event.eventIdentifier] = event.copy()
        return event.eventIdentifier
    }

    /// Changes an event as its account would, outside the engine.
    func editEvent(_ identifier: String, _ change: (FakeEvent) -> Void) {
        guard let event = records[identifier] else { preconditionFailure("no event \(identifier)") }
        change(event)
    }

    func deleteEvent(_ identifier: String) {
        records[identifier] = nil
    }

    /// Stored events in a calendar, oldest first; fresh copies, like a fetch.
    func contents(of calendar: FakeCalendar) -> [FakeEvent] {
        records.values.filter { $0.calendar === calendar }
            .sorted { ($0.startDate, $0.eventIdentifier) < ($1.startDate, $1.eventIdentifier) }
            .map { $0.copy() }
    }

    func stored(_ identifier: String) -> FakeEvent? {
        records[identifier]?.copy()
    }

    // MARK: CalendarEventStore

    func requestAccess() async throws -> Bool { true }

    func eventCalendars() -> [any StoredCalendar] { calendars }

    func events(from start: Date, to end: Date, in calendars: [any StoredCalendar]) -> [any StoredEvent] {
        let wanted = calendars.compactMap { $0 as? FakeCalendar }
        return records.values
            .filter { event in
                wanted.contains { $0 === event.calendar }
                    && event.startDate < end
                    && (event.endDate > start || (event.endDate == event.startDate && event.startDate >= start))
            }
            .map { $0.copy() }
    }

    func event(withIdentifier identifier: String) -> (any StoredEvent)? {
        records[identifier]?.copy()
    }

    /// Unlike most accounts, a new event here has no free/busy status until one is written, so a test
    /// cannot pass on the accident of a Busy default.
    func makeEvent() -> any StoredEvent {
        let event = FakeEvent()
        event.availability = .notSupported
        return event
    }

    func save(_ event: any StoredEvent) throws {
        guard !failWrites else { throw WriteRefused() }
        guard let event = event as? FakeEvent, let calendar = event.calendar else {
            preconditionFailure("saving an event with no calendar")
        }
        precondition(calendar.allowsContentModifications, "saved into a read-only calendar")
        if event.eventIdentifier == nil {
            assignIdentifiers(event)
        }
        event.lastModifiedDate = Date()
        records[event.eventIdentifier] = event.copy()
        saves += 1
    }

    func remove(_ event: any StoredEvent, futureEvents: Bool) throws {
        guard !failWrites else { throw WriteRefused() }
        guard records.removeValue(forKey: event.eventIdentifier) != nil else {
            throw WriteRefused()
        }
        removals += 1
    }

    private func assignIdentifiers(_ event: FakeEvent) {
        let number = nextID
        nextID += 1
        event.eventIdentifier = "event-\(number)"
        event.calendarItemExternalIdentifier = "external-\(number)"
        // Later events are created later, as they would be.
        event.creationDate = Date(timeIntervalSince1970: 1_700_000_000 + Double(number))
    }
}

final class FakeCalendar: StoredCalendar {
    let identity: CalendarIdentity
    var supportedEventAvailabilities: EKCalendarEventAvailabilityMask = [.busy, .free, .tentative, .unavailable]
    var allowsContentModifications: Bool { identity.allowsContentModifications }

    init(identity: CalendarIdentity) {
        self.identity = identity
    }

    var key: String { identity.stableKey }
    var name: String { identity.displayName }
}

final class FakeEvent: StoredEvent {
    var eventIdentifier: String!
    var calendarItemExternalIdentifier: String!
    var calendarItemIdentifier: String { eventIdentifier ?? "unsaved" }
    var title: String!
    var startDate: Date!
    var endDate: Date!
    var isAllDay = false
    var timeZone: TimeZone?
    var availability: EKEventAvailability = .busy
    var location: String?
    var structuredLocation: EKStructuredLocation?
    var url: URL?
    var notes: String?
    var alarms: [EKAlarm]?
    var recurrenceRules: [EKRecurrenceRule]?
    var hasRecurrenceRules: Bool { !(recurrenceRules ?? []).isEmpty }
    var creationDate: Date?
    var lastModifiedDate: Date?
    var status: EKEventStatus = .none
    var organizer: EKParticipant? { nil }
    var attendees: [EKParticipant]? { nil }
    var calendar: FakeCalendar?
    var isPrivate = false

    func place(in calendar: any StoredCalendar) {
        self.calendar = calendar as? FakeCalendar
    }

    func markPrivateIfSupported() {
        isPrivate = true
    }

    var marker: BridgeEventMetadata? { BridgeEventMetadata.parse(from: notes) }

    func copy() -> FakeEvent {
        let copy = FakeEvent()
        copy.eventIdentifier = eventIdentifier
        copy.calendarItemExternalIdentifier = calendarItemExternalIdentifier
        copy.title = title
        copy.startDate = startDate
        copy.endDate = endDate
        copy.isAllDay = isAllDay
        copy.timeZone = timeZone
        copy.availability = availability
        copy.location = location
        copy.structuredLocation = structuredLocation
        copy.url = url
        copy.notes = notes
        copy.alarms = alarms
        copy.recurrenceRules = recurrenceRules
        copy.creationDate = creationDate
        copy.lastModifiedDate = lastModifiedDate
        copy.status = status
        copy.calendar = calendar
        copy.isPrivate = isPrivate
        return copy
    }
}
