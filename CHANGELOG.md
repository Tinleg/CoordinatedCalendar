# Changelog

## Unreleased

- **Recurring events no longer rewrite their copies on every sync.** A recurrence rule's description, which the fingerprint included, begins with the rule object's memory address, so it differed in every run and every copy of a recurring event was updated every five minutes. The fingerprint now uses the rule without the address. Existing copies of recurring events are updated once more, then settle.
- **Surviving an account being removed and re-added.** macOS gives a re-added account's calendars new identifiers and regenerates its events' identifiers. The app now copes with both: it no longer sends that account's own events back to it as busy blocks, and instead of deleting and recreating every copy it made from that account (changing all of their event IDs), it re-links each copy to its source in place when the match is exact — same title, start, end and all-day, one-to-one. Anything ambiguous still falls back to delete-and-create.
- New read-only `--list-events --from CAL` command, showing each event's identifiers, for diagnosing sync problems.
- `package-app.sh` always rebuilds; it previously reused an existing release binary, which could package a stale build.

- **Full-detail copies now name their source event in the clear.** A copy in your consolidated calendar carries the source event's identifier, its cross-device identifier and the source calendar's display name in its marker, so a tool reading the consolidated calendar can match a copy to the event it came from exactly instead of guessing by title and time. The consolidated calendar is your own hub; **free/busy copies are unchanged and still reveal nothing**, and a busy block found carrying a source reference is treated as a violation and stripped. Existing consolidated copies gain the reference the next time they sync, updated in place, so their event IDs do not change.

## 0.1.2

- New app icon: a monthly desk calendar with an amber ² ("calendar squared"), replacing the C². The social preview image uses it too.

## 0.1.1

- **License:** now MIT with the Commons Clause condition. It is still free to use, modify and share, but it may not be sold, or offered as a paid product or service built substantially on it. Version 0.1.0 remains available under plain MIT.
- Calendars page: the Fan-In and Fan-Out descriptions are now hover tooltips (ⓘ), so both calendar lists start right under their headings.

## 0.1.0

First public release.

- **Fan-in:** gathers events from chosen calendars into one consolidated calendar with full details, including location coordinates, verbatim notes, and a `Source details:` block (organizer, attendees, status, repeat rule).
- **Fan-out:** writes sanitized busy blocks to your other calendars. Blocks carry only a configurable title (default `Busy - Other`), times, free/busy status, the private flag where supported, and a hashed marker. They have no alarms, location, notes or recurrence, and this is enforced on every run. Events marked Free and meetings you declined are skipped by default.
- Adapts each copy to what its destination supports (for example Tentative on Exchange, Free/Busy on iCloud), keeping the intended status in the marker.
- Runs on several Macs without duplicating copies, and removes duplicates if two Macs race.
- One background job (fan-in, then fan-out), plus a health check that notifies you when syncing stops or fails. The Status page shows each job's schedule, command, launchd state, last result and logs.
- Paged interface: Status, Calendars (fan-in and fan-out side by side, with curves from contributors through the consolidated calendar to recipients), Schedule, Preview & Run and Manual Copy.
- Uninstall with **Remove Everything**, or `--remove-all-copies`, which removes only what the app created.
- No API connections of its own: works through the accounts in macOS Calendar.
