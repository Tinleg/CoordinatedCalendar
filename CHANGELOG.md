# Changelog

## 0.3.2

- **The disk image window is laid out again.** 0.3.1's image opened as a plain Finder window, without the drag-to-Applications arrow or the first-launch instructions: Finder was asked to style the window before it could see the background file, and the build went ahead anyway. The build now waits for the file, accepts whichever way of naming it Finder takes on the day, and refuses to produce an image without its window layout. The app itself is unchanged.

## 0.3.1

- **Gathered events no longer alert twice.** A copy in the consolidated calendar is now written without the source event's alerts, so a meeting notifies you from its own calendar only. Alerts on existing copies are removed on the next sync, including ones an account added by itself. **Keep alerts on gathered events** in the Calendars page copies them after all; `--fan-in` takes `--keep-alerts`, and `--copy` takes `--no-alerts`. Busy blocks never carried alerts and still don't.

## 0.3.0

- **Download and install.** Releases now include `CoordinatedCalendar-<version>.dmg`: open it and drag the app to Applications. The app is signed and uses the hardened runtime but is not notarized by Apple, so the first launch needs **Open Anyway** in System Settings > Privacy & Security; the disk image window, the README and the release notes say so. Every release is signed with the same certificate, so the Calendar permission carries over when you update. Requires a Mac with Apple silicon.
- **VoiceOver:** the recipient availability menus name their calendar, the column headers read as headers with their explanation, a background job's state is spoken (and shown on hover) instead of only coloured, and decorative lines and dots are skipped.
- **The sync window is kept in days, everywhere.** The Date Window now reads "days back" and "days ahead" and moves forward each day, in the app as it already did in the background job. The app previously saved fixed dates and turned them into days only when jobs were submitted, so the two could disagree, and a Submit could quietly shorten what the job covered. Existing settings adopt the installed job's window. `--install-sync-agent` with a window records it in the app's settings too.
- **A moved meeting keeps its copies.** Moving an event to a new time used to delete its consolidated copy and every busy block made from it and create new ones, so their event IDs changed each time something was rescheduled. They are now updated in place. (A recurring event's occurrences share one identifier, so a moved occurrence is still replaced.)
- **Engine tests.** The sync engine now runs against an in-memory calendar store in the tests: fan-in, fan-out, edits, moves, deletions, Free events, stripping, duplicates from two Macs, a re-added account, dry runs, failed writes and removing everything. Writing them found the moved-meeting problem above.
- **Check for Updates** on the Status page (and `--check-for-updates`): asks GitHub for the newest release and, if there is one, offers to open its download page. It also checks once a week while the app is open; that can be turned off. This is the only network request the app makes, and it sends nothing about your calendars.
- **Copy Diagnostics** on the Status page (and `--diagnostics`): a report to attach to a bug report — versions, where the app runs from, how each kind of calendar is set up, the background jobs and recent sync results. Calendar and account names are replaced with labels, event titles are removed, and nothing is sent anywhere.
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
