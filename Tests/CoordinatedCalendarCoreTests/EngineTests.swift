import CoordinatedCalendarCore
import EventKit
import Foundation
import Testing

// End-to-end runs of the engine against FakeCalendarStore: two accounts that each contribute and receive,
// and one consolidated calendar, synced the way the app syncs them.

private let day = Date(timeIntervalSince1970: 1_790_000_000)
private let hour: TimeInterval = 3600

private final class Setup {
    let store = FakeCalendarStore()
    let home: FakeCalendar
    var work: FakeCalendar
    let hub: FakeCalendar
    var engine: CoordinatedCalendarEngine
    var dentist: String!
    var standup: String!

    init() {
        home = store.addCalendar(account: "Home", title: "Calendar")
        work = store.addCalendar(account: "Work", title: "Calendar")
        hub = store.addCalendar(account: "Hub", title: "Consolidated")
        engine = CoordinatedCalendarEngine(store: store, ledger: MappingLedger.inMemory())
    }

    /// A private dentist visit at home and a work standup with a room and an agenda.
    func addUsualEvents() {
        dentist = store.addEvent(to: home, title: "Dentist", start: day + hour)
        standup = store.addEvent(to: work, title: "Standup", start: day + 2 * hour, notes: "Agenda: numbers", location: "Room 4")
    }

    /// One full sync, as the app runs it: every contributor into the hub, then the hub out to every recipient.
    @discardableResult
    func sync(dryRun: Bool = false, keepAlerts: Bool = false, skipAllDay: Bool = false) async -> SyncResult {
        let start = day - 7 * 24 * hour
        let end = day + 30 * 24 * hour
        var total = SyncResult()
        for source in [home, work].sorted(by: { $0.key < $1.key }) {
            total.add(await engine.run(settings: .fanIn(sourceKey: source.key, consolidatedKey: hub.key,
                                                        copyAlarms: keepAlerts,
                                                        startDate: start, endDate: end, dryRun: dryRun)))
        }
        for destination in [home, work].sorted(by: { $0.key < $1.key }) {
            total.add(await engine.run(settings: .fanOut(consolidatedKey: hub.key, destinationKey: destination.key,
                                                         availability: .busy, skipAllDayEvents: skipAllDay,
                                                         startDate: start, endDate: end, dryRun: dryRun)))
        }
        return total
    }

    func busyBlocks(in calendar: FakeCalendar) -> [FakeEvent] {
        store.contents(of: calendar).filter { $0.marker?.copyMode == "freeBusy" }
    }

    func copies(in calendar: FakeCalendar) -> [FakeEvent] {
        store.contents(of: calendar).filter { $0.marker?.copyMode == "details" }
    }

    /// What removing and re-adding an account does: the same calendar and events come back under new
    /// identifiers, and the settings follow the calendar to its new key.
    func reAddWorkAccount() {
        let old = work
        let returned = store.addCalendar(account: "Work", title: "Calendar", id: "2")
        for event in store.contents(of: old) {
            let id = store.addEvent(to: returned, title: event.title, start: event.startDate,
                                    minutes: event.endDate.timeIntervalSince(event.startDate) / 60,
                                    availability: event.availability, notes: event.notes, location: event.location)
            if event.eventIdentifier == standup { standup = id }
        }
        store.removeCalendar(old)
        work = returned
    }
}

private extension SyncResult {
    mutating func add(_ other: SyncResult) {
        scanned += other.scanned
        created += other.created
        deleted += other.deleted
        skipped += other.skipped
        updated += other.updated
        blocked += other.blocked
        failed += other.failed
        previews += other.previews
    }

    var changes: Int { created + deleted + updated }
    var errors: [String] { previews.filter { $0.action == .error }.map(\.message) }
}

@Test func aFullSyncGathersEverythingAndSendsBusyBlocksOnlyToTheOtherAccounts() async throws {
    let setup = Setup()
    setup.addUsualEvents()

    let result = await setup.sync()

    #expect(result.errors.isEmpty)
    let copies = setup.copies(in: setup.hub)
    #expect(copies.map(\.title) == ["Home / Calendar: Dentist", "Work / Calendar: Standup"])
    let standup = try #require(copies.last)
    #expect(standup.location == "Room 4")
    #expect(standup.notes?.contains("Agenda: numbers") == true)
    #expect(standup.marker?.sourceEventExternalID == setup.store.stored(setup.standup)?.calendarItemExternalIdentifier)

    // Each account gets a block for the other's event, and none for its own.
    let homeBlocks = setup.busyBlocks(in: setup.home)
    let workBlocks = setup.busyBlocks(in: setup.work)
    #expect(homeBlocks.map(\.startDate) == [day + 2 * hour])
    #expect(workBlocks.map(\.startDate) == [day + hour])
    #expect(setup.store.contents(of: setup.home).count == 2)
    #expect(setup.store.contents(of: setup.work).count == 2)
}

@Test func aBusyBlockCarriesNothingButItsTimes() async throws {
    let setup = Setup()
    setup.addUsualEvents()
    await setup.sync()

    let block = try #require(setup.busyBlocks(in: setup.home).first)
    #expect(block.title == FreeBusyCompliance.fanOutTitle)
    #expect(block.startDate == day + 2 * hour && block.endDate == day + 3 * hour)
    #expect(block.availability == .busy)
    #expect(block.location == nil && block.url == nil)
    #expect((block.alarms ?? []).isEmpty)
    #expect(BridgeEventMetadata.notesByRemovingMarker(from: block.notes).isEmpty)
    #expect(block.marker?.carriesSourceReference == false)
    #expect(block.isPrivate)
    #expect(FreeBusyCompliance.violations(of: block, expectedTitle: FreeBusyCompliance.fanOutTitle).isEmpty)
}

@Test func aSecondSyncChangesNothing() async {
    let setup = Setup()
    setup.addUsualEvents()
    await setup.sync()
    let saves = setup.store.saves

    let second = await setup.sync()

    #expect(second.changes == 0)
    #expect(second.errors.isEmpty)
    #expect(setup.store.saves == saves)
}

@Test func anEditedEventUpdatesItsCopiesInPlace() async throws {
    let setup = Setup()
    setup.addUsualEvents()
    await setup.sync()
    let copyID = try #require(setup.copies(in: setup.hub).last?.eventIdentifier)
    let blockID = try #require(setup.busyBlocks(in: setup.home).first?.eventIdentifier)

    setup.store.editEvent(setup.standup) {
        $0.title = "Standup (moved)"
        $0.startDate = day + 5 * hour
        $0.endDate = day + 6 * hour
    }
    let result = await setup.sync()

    #expect(result.created == 0 && result.deleted == 0)
    let copy = try #require(setup.store.stored(copyID))
    #expect(copy.title == "Work / Calendar: Standup (moved)")
    #expect(copy.startDate == day + 5 * hour)
    let block = try #require(setup.store.stored(blockID))
    #expect(block.startDate == day + 5 * hour)
    #expect(block.title == FreeBusyCompliance.fanOutTitle)
    #expect(await setup.sync().changes == 0)
}

@Test func aDryRunOfAMoveReportsUpdatesNotReplacements() async {
    let setup = Setup()
    setup.addUsualEvents()
    await setup.sync()
    let saves = setup.store.saves

    setup.store.editEvent(setup.standup) {
        $0.startDate = day + 5 * hour
        $0.endDate = day + 6 * hour
    }
    let preview = await setup.sync(dryRun: true)

    #expect(preview.created == 0 && preview.deleted == 0)
    #expect(preview.updated >= 1)
    #expect(setup.store.saves == saves)
}

@Test func aRecurringEventIsNotFollowedByIdentifierAlone() async {
    let setup = Setup()
    setup.addUsualEvents()
    await setup.sync()
    // EventKit gives every occurrence of a series the same identifier, so for a recurring event an
    // identifier alone cannot say which occurrence moved. Its copy is replaced rather than followed.
    let first = setup.store.addEvent(to: setup.work, title: "Weekly", start: day + 24 * hour)
    await setup.sync()
    setup.store.editEvent(first) { $0.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)] }
    await setup.sync()
    #expect(setup.copies(in: setup.hub).filter { $0.title == "Work / Calendar: Weekly" }.count == 1)

    setup.store.editEvent(first) {
        $0.startDate = day + 8 * 24 * hour
        $0.endDate = day + 8 * 24 * hour + hour
    }
    let result = await setup.sync()
    #expect(result.errors.isEmpty)
    let weekly = setup.copies(in: setup.hub).filter { $0.title == "Work / Calendar: Weekly" }
    #expect(weekly.map(\.startDate) == [day + 8 * 24 * hour])
}

@Test func aDeletedEventTakesItsCopiesWithIt() async {
    let setup = Setup()
    setup.addUsualEvents()
    await setup.sync()

    setup.store.deleteEvent(setup.standup)
    await setup.sync()

    #expect(setup.copies(in: setup.hub).map(\.title) == ["Home / Calendar: Dentist"])
    #expect(setup.busyBlocks(in: setup.home).isEmpty)
    #expect(setup.busyBlocks(in: setup.work).count == 1)
}

@Test func freeTimeIsGatheredButBlocksNobody() async {
    let setup = Setup()
    setup.addUsualEvents()
    setup.store.addEvent(to: setup.work, title: "Optional lunch", start: day + 4 * hour, availability: .free)
    await setup.sync()

    #expect(setup.copies(in: setup.hub).count == 3)
    #expect(setup.busyBlocks(in: setup.home).map(\.startDate) == [day + 2 * hour])

    // An event that becomes Free loses the block it had.
    setup.store.editEvent(setup.standup) { $0.availability = .free }
    await setup.sync()
    #expect(setup.busyBlocks(in: setup.home).isEmpty)
}

@Test func detailsAddedToABusyBlockAreStrippedAgain() async throws {
    let setup = Setup()
    setup.addUsualEvents()
    await setup.sync()
    let blockID = try #require(setup.busyBlocks(in: setup.home).first?.eventIdentifier)

    setup.store.editEvent(blockID) {
        $0.location = "Room 4"
        $0.notes = ($0.notes ?? "") + "\nAgenda: numbers"
        $0.alarms = [EKAlarm(relativeOffset: -600)]
    }
    let result = await setup.sync()

    #expect(result.errors.isEmpty)
    let block = try #require(setup.store.stored(blockID))
    #expect(block.location == nil)
    #expect((block.alarms ?? []).isEmpty)
    #expect(BridgeEventMetadata.notesByRemovingMarker(from: block.notes).isEmpty)
}

@Test func anotherMacWithNoLedgerRecognisesTheCopiesInsteadOfDuplicatingThem() async {
    let setup = Setup()
    setup.addUsualEvents()
    await setup.sync()
    let events = setup.store.contents(of: setup.hub).count

    setup.engine = CoordinatedCalendarEngine(store: setup.store, ledger: MappingLedger.inMemory())
    let result = await setup.sync()

    #expect(result.created == 0 && result.deleted == 0)
    #expect(setup.store.contents(of: setup.hub).count == events)
    #expect(setup.busyBlocks(in: setup.home).count == 1)
}

@Test func aDuplicateCopyFromAnotherMacIsRemovedAndTheOlderKept() async throws {
    let setup = Setup()
    setup.addUsualEvents()
    await setup.sync()
    let original = try #require(setup.copies(in: setup.hub).last)
    // Two Macs each copied the event before their calendars synced; the other Mac's copy arrives later.
    setup.store.addEvent(to: setup.hub, title: original.title, start: original.startDate,
                         notes: original.notes, location: original.location)

    await setup.sync()

    let standups = setup.copies(in: setup.hub).filter { $0.title == original.title }
    #expect(standups.map(\.eventIdentifier) == [original.eventIdentifier])
}

@Test func anAccountRemovedAndReAddedKeepsItsCopiesAndGetsNoEcho() async throws {
    let setup = Setup()
    setup.addUsualEvents()
    await setup.sync()
    let copyID = try #require(setup.copies(in: setup.hub).last?.eventIdentifier)
    let homeBlockID = try #require(setup.busyBlocks(in: setup.home).first?.eventIdentifier)

    setup.reAddWorkAccount()
    let result = await setup.sync()

    #expect(result.errors.isEmpty)
    #expect(result.created == 0 && result.deleted == 0)
    // The consolidated copy was re-linked to the returned event, not recreated.
    let copies = setup.copies(in: setup.hub)
    #expect(copies.count == 2)
    #expect(copies.last?.eventIdentifier == copyID)
    #expect(copies.last?.marker?.sourceEventExternalID == setup.store.stored(setup.standup)?.calendarItemExternalIdentifier)
    // The returned account still has only its own event and the one block for home's.
    #expect(setup.busyBlocks(in: setup.work).map(\.startDate) == [day + hour])
    #expect(setup.store.contents(of: setup.work).count == 2)
    #expect(setup.busyBlocks(in: setup.home).map(\.eventIdentifier) == [homeBlockID])
    // And it settles.
    #expect(await setup.sync().changes == 0)
}

@Test func aDryRunReportsWhatItWouldDoAndWritesNothing() async {
    let setup = Setup()
    setup.addUsualEvents()

    let result = await setup.sync(dryRun: true)

    #expect(result.created == 2)
    #expect(setup.store.saves == 0 && setup.store.removals == 0)
    #expect(setup.store.contents(of: setup.hub).isEmpty)
}

@Test func removingEverythingLeavesOnlyYourOwnEvents() async {
    let setup = Setup()
    setup.addUsualEvents()
    await setup.sync()
    let window = CoordinatedCalendarEngine.removalWindow(now: day)

    let preview = await setup.engine.removeAllCopies(from: window.start, to: window.end, dryRun: true)
    #expect(preview.deleted == 4)
    #expect(setup.store.removals == 0)

    let result = await setup.engine.removeAllCopies(from: window.start, to: window.end, dryRun: false)
    #expect(result.deleted == 4 && result.failed == 0)
    #expect(setup.store.contents(of: setup.hub).isEmpty)
    #expect(setup.store.contents(of: setup.home).map(\.title) == ["Dentist"])
    #expect(setup.store.contents(of: setup.work).map(\.title) == ["Standup"])
}

@Test func aFailedWriteIsReportedAndNothingIsRecordedAsCopied() async {
    let setup = Setup()
    setup.addUsualEvents()
    setup.store.failWrites = true

    let failed = await setup.sync()
    #expect(failed.failed == 2)
    #expect(failed.errors.count == 2)

    // Once writes work again, everything is copied; nothing was wrongly recorded as done.
    setup.store.failWrites = false
    await setup.sync()
    #expect(setup.copies(in: setup.hub).count == 2)
    #expect(setup.busyBlocks(in: setup.home).count == 1)
}

@Test func aReadOnlyDestinationIsRefusedBeforeAnythingHappens() async {
    let setup = Setup()
    setup.addUsualEvents()
    let holidays = setup.store.addCalendar(account: "Subscribed", title: "Holidays", writable: false)

    let result = await setup.engine.run(settings: .fanOut(
        consolidatedKey: setup.hub.key, destinationKey: holidays.key, availability: .busy,
        startDate: day - 24 * hour, endDate: day + 24 * hour, dryRun: false))

    #expect(result.failed == 1)
    #expect(setup.store.saves == 0)
}

@Test func gatheredCopiesAndBusyBlocksCarryNoAlerts() async throws {
    let setup = Setup()
    setup.addUsualEvents()
    setup.store.editEvent(setup.standup) { $0.alarms = [EKAlarm(relativeOffset: -600)] }

    await setup.sync()

    // The source keeps its own alert; nothing the app writes has one.
    #expect(setup.store.stored(setup.standup)?.alarms?.count == 1)
    #expect(setup.copies(in: setup.hub).allSatisfy { ($0.alarms ?? []).isEmpty })
    #expect(setup.busyBlocks(in: setup.home).allSatisfy { ($0.alarms ?? []).isEmpty })
}

@Test func anAlertAddedToAGatheredCopyIsRemovedAgain() async throws {
    let setup = Setup()
    setup.addUsualEvents()
    await setup.sync()
    let copyID = try #require(setup.copies(in: setup.hub).last?.eventIdentifier)

    // Some accounts put a default alert on every new event, after the copy was written.
    setup.store.editEvent(copyID) { $0.alarms = [EKAlarm(relativeOffset: -900)] }
    let result = await setup.sync()

    #expect(result.errors.isEmpty)
    #expect((setup.store.stored(copyID)?.alarms ?? []).isEmpty)
    #expect(setup.store.stored(copyID)?.eventIdentifier == copyID)
    #expect(await setup.sync().changes == 0)
}

@Test func alertsAreKeptWhenAskedFor() async throws {
    let setup = Setup()
    setup.addUsualEvents()
    setup.store.editEvent(setup.standup) { $0.alarms = [EKAlarm(relativeOffset: -600)] }

    await setup.sync(keepAlerts: true)

    let copy = try #require(setup.copies(in: setup.hub).last)
    #expect(copy.alarms?.count == 1)
    // Busy blocks still never alert.
    #expect(setup.busyBlocks(in: setup.home).allSatisfy { ($0.alarms ?? []).isEmpty })
}

@Test func allDayEventsAreGatheredAndBlockTimeUnlessSkipped() async throws {
    let setup = Setup()
    setup.addUsualEvents()
    // A trip marked Busy, spanning several days.
    let trip = setup.store.addEvent(to: setup.work, title: "Buffalo trip", start: day + 24 * hour, minutes: 4 * 24 * 60)
    setup.store.editEvent(trip) { $0.isAllDay = true }

    await setup.sync()
    let copy = try #require(setup.copies(in: setup.hub).first { $0.title == "Work / Calendar: Buffalo trip" })
    #expect(copy.isAllDay)
    #expect(copy.endDate == day + 5 * 24 * hour)
    let block = try #require(setup.busyBlocks(in: setup.home).first { $0.isAllDay })
    #expect(block.startDate == day + 24 * hour)

    // With the option, the all-day block goes; the timed one stays, and the trip is still gathered.
    let result = await setup.sync(skipAllDay: true)
    #expect(result.errors.isEmpty)
    #expect(setup.busyBlocks(in: setup.home).map(\.startDate) == [day + 2 * hour])
    #expect(setup.copies(in: setup.hub).contains { $0.title == "Work / Calendar: Buffalo trip" })
    #expect(await setup.sync(skipAllDay: true).changes == 0)
}
