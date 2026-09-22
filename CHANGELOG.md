# Changelog

## Unreleased

- **A calendar that comes back under a new identifier is re-attached automatically.** Removing and re-adding an account (the usual fix when Calendar stops showing its events) gives its calendars new identifiers; the app now recognises them by name, re-attaches them with their settings, and says so. A selected calendar that is only temporarily unavailable stays selected instead of being silently dropped along with its settings.
- **Background jobs are attributed to the app.** macOS now names CoordinatedCalendar in "Background Items Added" and in System Settings > General > Login Items. Existing jobs gain this the next time they are submitted (Status page > Submit Background Jobs).
- **Disk image builds.** `scripts/make-dmg.sh` produces `dist/CoordinatedCalendar-<version>.dmg` with the familiar "drag to Applications" window. It signs with a Developer ID certificate and notarizes when those credentials exist, and reports plainly when they don't.
- **Background syncing can only be turned on from an Applications folder.** If the app was opened straight from a download, from its disk image, from a temporary folder or from anywhere else, it says so on the Status page from launch and explains how to move it, instead of installing background jobs that would break when that copy moves or disappears. The older `--install-agent` command now goes through the same check; it previously skipped it.
- The app is now signed with the **hardened runtime** and declares the Calendar entitlement it needs under it. Nothing changes in use; this is the prerequisite for a notarized download that installs without security warnings.

## 0.2.0

**Behavior change:** full-detail copies in the consolidated calendar now carry their source event's identifiers and source calendar name in the clear (see below). Anything that reads the consolidated calendar's notes will see new marker fields; busy blocks on other calendars are unchanged.

- **Full-detail copies now name their source event in the clear.** A copy in your consolidated calendar carries the source event's identifier, its cross-device identifier and the source calendar's display name in its marker, so a tool reading the consolidated calendar can match a copy to the event it came from exactly instead of guessing by title and time. The consolidated calendar is your own hub; **free/busy copies are unchanged and still reveal nothing**, and a busy block found carrying a source reference is treated as a violation and stripped. Existing consolidated copies gain the reference the next time they sync, updated in place, so their event IDs do not change.
- **Surviving an account being removed and re-added.** macOS gives a re-added account's calendars new identifiers and regenerates its events' identifiers. The app now copes with both: it no longer sends that account's own events back to it as busy blocks, and instead of deleting and recreating every copy it made from that account (changing all of their event IDs), it re-links each copy to its source in place when the match is exact — same title, start, end and all-day, one-to-one. Anything ambiguous still falls back to delete-and-create.
- **Recurring events no longer rewrite their copies on every sync.** A recurrence rule's description, which the fingerprint included, begins with the rule object's memory address, so it differed in every run and every copy of a recurring event was updated every five minutes. The fingerprint now uses the rule without the address. Existing copies of recurring events are updated once more, then settle.
- New read-only `--list-events --from CAL` command, showing each event's identifiers, for diagnosing sync problems.
- `package-app.sh` always rebuilds; it previously reused an existing release binary, which could package a stale build.

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
