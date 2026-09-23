import CoordinatedCalendarCore
import EventKit
import Foundation
import Testing

private let start = Date(timeIntervalSince1970: 1_790_000_000)

private func calendarWithTwoEvents() -> (FakeCalendarStore, FakeCalendar, [String]) {
    let store = FakeCalendarStore()
    let calendar = store.addCalendar(account: "Work", title: "Calendar")
    let ids = [
        store.addEvent(to: calendar, title: "Standup", start: start),
        store.addEvent(to: calendar, title: "Review", start: start + 7200)
    ]
    return (store, calendar, ids)
}

private func signature(_ store: FakeCalendarStore, _ calendar: FakeCalendar, context: [String] = ["v1"]) -> String {
    SyncSignature.of(events: store.contents(of: calendar).map { (calendar.key, $0 as any StoredEvent) }, context: context)
}

@Test func theSameCalendarsGiveTheSameSignatureInAnyOrder() {
    let (store, calendar, _) = calendarWithTwoEvents()
    let events = store.contents(of: calendar).map { (calendar.key, $0 as any StoredEvent) }
    #expect(SyncSignature.of(events: events, context: ["v1"]) == SyncSignature.of(events: events.reversed(), context: ["v1"]))
}

@Test func anyChangeASyncActsOnChangesTheSignature() {
    let edits: [(String, (FakeEvent) -> Void)] = [
        ("title", { $0.title = "Standup (moved)" }),
        ("time", { $0.startDate = $0.startDate + 900 }),
        ("availability", { $0.availability = .free }),
        ("notes, which hold a copy's marker", { $0.notes = "changed" }),
        ("alerts", { $0.alarms = [EKAlarm(relativeOffset: -600)] }),
        ("location", { $0.location = "Room 4" })
    ]
    for (what, edit) in edits {
        let (store, calendar, ids) = calendarWithTwoEvents()
        let before = signature(store, calendar)
        store.editEvent(ids[0], edit)
        #expect(signature(store, calendar) != before, "changing \(what) must force a full sync")
    }
}

@Test func anAddedOrDeletedEventChangesTheSignature() {
    let (store, calendar, ids) = calendarWithTwoEvents()
    let before = signature(store, calendar)
    store.deleteEvent(ids[1])
    let afterDelete = signature(store, calendar)
    #expect(afterDelete != before)
    store.addEvent(to: calendar, title: "Review", start: start + 7200)
    #expect(signature(store, calendar) != afterDelete)
}

@Test func settingsWindowAndVersionAreInTheSignature() {
    let (store, calendar, _) = calendarWithTwoEvents()
    #expect(signature(store, calendar, context: ["v1", "window 2026-09-23"]) != signature(store, calendar, context: ["v1", "window 2026-09-24"]))
}

@Test func aRunSkipsOnlyWhenNothingChangedSinceARecentFullSync() {
    let now = Date()
    let recent = SyncSignatureRecord(signature: "abc", fullRunAt: now - 600)
    #expect(SyncSignatureRecord.canSkip(current: "abc", recorded: recent, now: now))
    #expect(!SyncSignatureRecord.canSkip(current: "abd", recorded: recent, now: now))
    #expect(!SyncSignatureRecord.canSkip(current: "abc", recorded: nil, now: now))
    let old = SyncSignatureRecord(signature: "abc", fullRunAt: now - SyncSignatureRecord.maximumAge - 1)
    #expect(!SyncSignatureRecord.canSkip(current: "abc", recorded: old, now: now))
}

@Test func changesAreSyncedAfterAQuietSpell() {
    var debouncer = ChangeDebouncer(quietPeriod: 15, maximumDelay: 60)
    let t0 = Date()
    #expect(debouncer.dueDate == nil)
    // The write, then the account syncing it back six seconds later: one sync, 15 seconds after the last.
    debouncer.recordChange(at: t0)
    debouncer.recordChange(at: t0 + 6)
    #expect(debouncer.dueDate == t0 + 21)
    #expect(!debouncer.isDue(at: t0 + 20))
    #expect(debouncer.isDue(at: t0 + 21))
    #expect(debouncer.pendingChanges == 2)
    debouncer.reset()
    #expect(debouncer.dueDate == nil)
}

@Test func aStreamOfChangesStillSyncsWithinTheMaximumDelay() {
    var debouncer = ChangeDebouncer(quietPeriod: 15, maximumDelay: 60)
    let t0 = Date()
    for second in stride(from: 0.0, through: 120, by: 10) {
        debouncer.recordChange(at: t0 + second)
    }
    #expect(debouncer.dueDate == t0 + 60)
}
