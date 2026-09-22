import EventKit
import Foundation

/// What the engine needs from a calendar store. `EventKitStore` is the real one; tests supply an
/// in-memory store, so the engine's fan-in, fan-out, reconcile and cleanup rules can be exercised end to
/// end without Calendar access. EventKit itself cannot be faked: it refuses calendars and events not
/// made through a store the user has granted access to.
public protocol CalendarEventStore: AnyObject {
    func requestAccess() async throws -> Bool
    func eventCalendars() -> [any StoredCalendar]
    /// Events overlapping `start..<end` in the given calendars, from one query. EventKit caps a query's
    /// span; the engine slices longer windows itself.
    func events(from start: Date, to end: Date, in calendars: [any StoredCalendar]) -> [any StoredEvent]
    func event(withIdentifier identifier: String) -> (any StoredEvent)?
    /// A new, unsaved event.
    func makeEvent() -> any StoredEvent
    func save(_ event: any StoredEvent) throws
    /// Removes the event, and for a recurring event with `futureEvents`, the rest of its series.
    func remove(_ event: any StoredEvent, futureEvents: Bool) throws
}

public protocol StoredCalendar: AnyObject {
    var identity: CalendarIdentity { get }
    var allowsContentModifications: Bool { get }
    var supportedEventAvailabilities: EKCalendarEventAvailabilityMask { get }
}

/// The event properties the engine reads and writes, named and typed as on `EKEvent`.
public protocol StoredEvent: AnyObject {
    var eventIdentifier: String! { get }
    var calendarItemIdentifier: String { get }
    var calendarItemExternalIdentifier: String! { get }
    var title: String! { get set }
    var startDate: Date! { get set }
    var endDate: Date! { get set }
    var isAllDay: Bool { get set }
    var timeZone: TimeZone? { get set }
    var availability: EKEventAvailability { get set }
    var location: String? { get set }
    var structuredLocation: EKStructuredLocation? { get set }
    var url: URL? { get set }
    var notes: String? { get set }
    var alarms: [EKAlarm]? { get set }
    var recurrenceRules: [EKRecurrenceRule]? { get }
    var hasRecurrenceRules: Bool { get }
    var creationDate: Date? { get }
    var lastModifiedDate: Date? { get }
    var status: EKEventStatus { get }
    var organizer: EKParticipant? { get }
    var attendees: [EKParticipant]? { get }
    func place(in calendar: any StoredCalendar)
    /// Marks the event private where its account allows it; elsewhere does nothing.
    func markPrivateIfSupported()
}

public final class EventKitStore: CalendarEventStore {
    public let store: EKEventStore

    public init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    public func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToEvents()
    }

    public func eventCalendars() -> [any StoredCalendar] {
        store.calendars(for: .event)
    }

    public func events(from start: Date, to end: Date, in calendars: [any StoredCalendar]) -> [any StoredEvent] {
        let ekCalendars = calendars.compactMap { $0 as? EKCalendar }
        // An empty list would mean every calendar to EventKit.
        guard !ekCalendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: ekCalendars)
        return store.events(matching: predicate)
    }

    public func event(withIdentifier identifier: String) -> (any StoredEvent)? {
        store.event(withIdentifier: identifier)
    }

    public func makeEvent() -> any StoredEvent {
        EKEvent(eventStore: store)
    }

    public func save(_ event: any StoredEvent) throws {
        try store.save(Self.ekEvent(event), span: .thisEvent, commit: true)
    }

    public func remove(_ event: any StoredEvent, futureEvents: Bool) throws {
        try store.remove(Self.ekEvent(event), span: futureEvents ? .futureEvents : .thisEvent, commit: true)
    }

    private static func ekEvent(_ event: any StoredEvent) -> EKEvent {
        guard let event = event as? EKEvent else {
            preconditionFailure("EventKitStore was handed an event it did not make")
        }
        return event
    }
}

extension EKCalendar: StoredCalendar {
    public var identity: CalendarIdentity { CalendarIdentity(calendar: self) }
}

extension EKEvent: StoredEvent {
    public func place(in calendar: any StoredCalendar) {
        if let calendar = calendar as? EKCalendar {
            self.calendar = calendar
        }
    }

    public func markPrivateIfSupported() {
        let allowsSelector = Selector(("allowsPrivacyLevelModifications"))
        let setterSelector = Selector(("setPrivacyLevel:"))
        guard responds(to: allowsSelector), responds(to: setterSelector) else {
            return
        }

        typealias AllowsPrivacyGetter = @convention(c) (AnyObject, Selector) -> Bool
        typealias PrivacySetter = @convention(c) (AnyObject, Selector, Int) -> Void

        let allowsPrivacy = unsafeBitCast(method(for: allowsSelector), to: AllowsPrivacyGetter.self)
        guard allowsPrivacy(self, allowsSelector) else {
            return
        }

        let setPrivacy = unsafeBitCast(method(for: setterSelector), to: PrivacySetter.self)
        setPrivacy(self, setterSelector, 2)
    }
}
