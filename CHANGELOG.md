# Changelog

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
