# Architecture

CoordinatedCalendar has two targets:

- `CoordinatedCalendarCore`: EventKit bridge logic, durable mappings, duplicate fingerprints, and sync result models.
- `CoordinatedCalendar`: a compact SwiftUI macOS interface for permission, calendar selection, date range, transformations, preview, and copy.

## Data Model

`CalendarIdentity` combines `EKSource.sourceIdentifier` and `EKCalendar.calendarIdentifier` so duplicate calendar names across accounts remain distinguishable.

`EventMapping` records a source calendar, destination calendar, source event identifier, occurrence start date, fingerprint, and destination event identifier. It is persisted as JSON under `~/Library/Application Support/CoordinatedCalendar`.

`EventFingerprint` hashes stable event fields that define a copy: source calendar, title, start/end, all-day status, location, URL, and recurrence rule descriptions.

## Sync Flow

1. Validate calendar access, source/destination selection, date window, and destination writability.
2. Fetch source events using `EKEventStore.predicateForEvents`.
3. For each source event, check the mapping ledger.
4. If no mapping exists, create or preview a destination copy.
5. If a mapping exists and the fingerprint matches, skip as a duplicate.
6. If a mapping exists and the fingerprint changed, block by default or update when the user explicitly enabled updates.
7. Persist mappings only after a real write run.

## Consolidated Calendar Mode

Script mode supports a full bridge cycle around one consolidated calendar:

1. Fan-in copies source calendars into the consolidated calendar.
2. Fan-in skips events that CoordinatedCalendar previously created, which prevents free/busy blocks and consolidated copies from being copied back into the consolidated calendar as new originals.
3. Fan-out copies the consolidated calendar to writable destination calendars as free/busy blocks.
4. Fan-out checks each consolidated event's ledger origin. If the destination calendar is the original source for that event, it skips the copy back.

These rules allow repeated runs every few minutes without copying an event back over itself.

The `--sync-gui-settings` command runs the same fan-in/fan-out behavior from the saved GUI settings file at `~/Library/Application Support/CoordinatedCalendar/gui-settings.json`. That lets the GUI act as the configuration editor while LaunchAgent or Terminal invokes the saved sync.

## Cross-Device Deduplication

CoordinatedCalendar keeps `mappings.json` as a local cache, but it also writes a compact `CoordinatedCalendar:` metadata marker to every event it creates. The marker contains stable copy/source hashes, hashed origin/source/destination calendar names (`sha256:` tokens of the display names, so they match across Macs without revealing the names), copy mode, availability, and the current transformation fingerprint. It does not contain the meeting title, location, URL, notes, or any calendar name in plain text. Markers written before names were hashed are still recognized, and each sync rewrites them in the hashed form.

When another Mac runs CoordinatedCalendar against the same synced calendars, it scans for these markers before creating new copies. That lets it skip or update copies created by another computer, skip fan-out back to the originating calendar, and reconcile stale metadata-tracked copies when source events disappear from the active date window.

## Recurrence

EventKit expands recurring events in date-window fetches. CoordinatedCalendar copies recurrence rules where EventKit exposes them safely, and uses the occurrence start date in mapping IDs so repeated occurrences can be tracked conservatively.
