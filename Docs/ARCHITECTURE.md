# Architecture

CoordinatedCalendar is a local macOS app that coordinates free/busy time across calendar accounts. It gathers every event into one **consolidated** calendar with full details (**fan-in**), and writes sanitized **busy blocks** from that calendar back to every other calendar (**fan-out**). Everything runs on the Mac through EventKit, using the accounts already added to macOS Calendar. There is no server, and no API connection or credentials of its own.

For the reasoning behind the main choices, see [DESIGN-DECISIONS.md](DESIGN-DECISIONS.md). For where it could go next, see [ROADMAP.md](ROADMAP.md).

## Layout

The Swift package has two targets and one test target:

| Target | Purpose |
|---|---|
| `CoordinatedCalendarCore` | The sync engine and everything it needs: EventKit access, identities, the ledger, markers, fingerprints, copy rules and health. It has no UI. |
| `CoordinatedCalendar` | The executable: a SwiftUI app, and a command-line mode when started with `--` arguments. It also installs LaunchAgents and stores settings and status. |
| `CoordinatedCalendarCoreTests` | Swift Testing unit tests for the core. They use synthetic data and in-memory `EKEvent`s, so they need no calendar access. |

### Core (`Sources/CoordinatedCalendarCore`)

| File | Responsibility |
|---|---|
| `CoordinatedCalendarEngine.swift` | Runs one source-to-destination route (fan-in, fan-out or a manual copy), uninstall removal, and the helpers. |
| `BridgeSettings.swift` | `BridgeSettings` (one route's options) and `TransformSettings` (what a copy looks like). |
| `CalendarIdentity.swift` | A stable key per calendar (`sourceIdentifier::calendarIdentifier`), plus display name, account type, writability and supported availabilities. |
| `BridgeEventMetadata.swift` | The notes marker every copy carries: identity hashes, hashed calendar names, copy mode, fingerprint, availability intent, and — on full-detail copies only — the source event named in the clear. |
| `EventFingerprint.swift` | Hashes that decide whether an existing copy is up to date. |
| `EventDetailsSummary.swift` | The `Source details:` notes block for full-detail copies: organizer, attendees, status, repeat rule and your declined response. |
| `FreeBusyCompliance.swift` | What a busy block may carry, and how to strip one back to that. |
| `MappingLedger.swift` | A per-Mac cache mapping source occurrences to copies (`mappings.json`). |
| `SyncHealth.swift` | The last-run status record and the rules for when the health check alerts. |
| `SyncSignature.swift` | The digest that lets a run stop when nothing has changed, and the change debouncer. |
| `SyncResult.swift` | Counts and per-event previews returned by every run. |
| `AppSupport.swift` | The `~/Library/Application Support/CoordinatedCalendar` folder. |
| `BridgeError.swift` | User-facing errors. |

### App (`Sources/CoordinatedCalendarApp`)

| File | Responsibility |
|---|---|
| `CoordinatedCalendarApp.swift` | Entry point: command-line mode if any `--` argument is present, otherwise the SwiftUI app. |
| `CommandLineBridge.swift` | CLI commands and argument parsing. |
| `BridgeViewModel.swift` | GUI state, actions, demo mode and startup-error handling. |
| `ContentView.swift` | Sidebar pages: Status, Calendars, Schedule, Preview & Run and Manual Copy. |
| `CalendarFlowView.swift` | The Calendars page: contributors, the consolidated card and recipients, joined by curves. |
| `GUISettingsStore.swift` | `gui-settings.json`, and the shared fan-in and fan-out settings builder used by both the GUI and `--sync-gui-settings`. |
| `SyncAgentInstaller.swift` | Installing and removing LaunchAgents, reading job details from launchd, and the last-sync status, signature and notification store. |
| `ChangeWatcher.swift` | `--watch`: starts the sync job shortly after the calendars change. |

## Data model

- **Calendar identity:** `CalendarIdentity.stableKey` is `EKSource.sourceIdentifier::EKCalendar.calendarIdentifier`. Keys are per-Mac. Across Macs, calendars are matched by display name (`Account / Calendar`), which is why names must match on every Mac.
- **Copy identity:** `sourceIdentity` hashes the source calendar name, the event's cross-device identifier (`calendarItemExternalIdentifier`, falling back to the local ID) and the occurrence start. `copyID` hashes the source identity, the destination calendar name and the copy mode. Both hash in the `CoordinatedCalendar` namespace (`BridgeEventMetadata.identityNamespace`). Every Mac computes the same IDs for the same copy.
- **Marker:** each copy's notes end with one line, `CoordinatedCalendar:<base64 JSON>`. The JSON holds `copyID`, `sourceIdentity`, the source, destination and origin calendar names as `sha256:` tokens, key hashes, `copyMode` (`details` or `freeBusy`), the `fingerprint`, and `sourceAvailability`/`intendedAvailability`. It may also hold `declined: true`. On a **full-detail** copy it additionally holds `sourceEventID`, `sourceEventExternalID` and `sourceCalendarPlainName` in the clear, because such a copy lives in your own consolidated calendar and a reader there should be able to identify the source event exactly. A **free/busy** copy never holds them, holds no event content and no plain calendar name; `FreeBusyCompliance` counts a source reference on a busy block as a violation and strips it. The marker is the source of truth for recognizing copies, including across Macs.
- **Ledger:** `mappings.json` maps (source calendar, destination calendar, source event, occurrence start) to a destination event, with its fingerprint. It is a per-Mac cache. Losing it is harmless because the marker lets the app find its copies again. A ledger entry naming a calendar key that no longer exists — which is what removing and re-adding an account produces — is ignored, and the marker decides instead.
- **Fingerprint:** a hash of the source event's defining fields (title, times, all-day, location, URL, recurrence) and the transform (title rules, notes, free/busy mode, privacy, availability, resolved availability, origin, location and URL options). Extra parts are appended only when present, so copies without them keep their fingerprints:
  - `place:` coordinates when a location's coordinates are copied;
  - `details:` when a `Source details:` block exists;
  - `notes:verbatim` for notes with CRLF or leading whitespace.

  A copy whose stored fingerprint differs from the computed one is updated in place.

## One route: `CoordinatedCalendarEngine.run`

Every fan-in, fan-out and manual copy is one call with a `BridgeSettings`:

1. **Validate** the window, both calendars and that the destination is writable.
2. **Fetch source events** in one-year slices across the window. EventKit returns at most four years per query, so slicing avoids silently truncating long windows. Duplicates that span a slice boundary are dropped. EventKit expands recurring events, so every occurrence is its own source event.
3. **Skip non-blocking events** when the route asks for it (fan-out): events marked Free, using the marker's intended availability before the event's own, and meetings you declined, using the marker's `declined` or your attendee status. Skipped events count as absent, so step 5 removes copies made for them earlier.
4. **Clean up existing copies on the destination** (`enforceCopyShape`), touching only events carrying this route's marker:
   - **Duplicates** of the same `copyID` are reduced to one. The keeper is the earliest created, then the smallest cross-device identifier, so every Mac keeps the same copy.
   - **Recurring copies** are removed so the sync recreates them as single occurrences.
   - **Busy blocks** are stripped to what `FreeBusyCompliance` allows: the title, no location or place, no URL, no alarms, no recurrence, and notes holding only the marker.
   - **Markers** still holding plain calendar names are rewritten in hashed form.
5. **Reconcile deletions** (when enabled): copies whose source event no longer exists in the window are deleted. They are found through the ledger and through markers, so this works on a Mac with an empty ledger too. Before a marker-tracked copy is deleted, it is **re-linked** if it is plainly the same event under new identifiers: exactly one unclaimed source with the title the copy would have, the same start, end and all-day flag, and no other copy wanting that source. Its marker is rewritten in place and the normal update refreshes it, so its event ID survives. Anything ambiguous is deleted and recreated as before.
6. **Process each source event:**
   - Skip events the app created, on fan-in, and copies back to the event's originating calendar, on fan-out.
   - Look for an existing copy by marker (`copyID` near the event's time), then through the ledger.
   - Found and fingerprint equal: skip. Found and fingerprint changed: update in place, or block unless updates are enabled. Not found: create.
7. **Save the ledger** after a real run. Every command is a dry run unless `--execute` is given, and dry runs return the same previews without writing.

### What a copy carries

- **Full-detail copy** (fan-in):
  - the title as `Account / Calendar: Title`, and times, all-day and time zone;
  - availability resolved against what the destination supports;
  - location text, with coordinates and radius copied as a fresh `EKStructuredLocation` whose title is the exact location text;
  - URL and alarms;
  - notes kept verbatim (only marker lines and trailing whitespace are removed), followed by the `Source details:` block and the marker.
- **Busy block** (fan-out): the busy title (default `Busy - Other`), times, availability, the private flag where the destination allows it, and the marker. Nothing else.
- **No copy carries recurrence rules.** Occurrences are copied individually. A rule on a copied occurrence would expand into phantom events.

### Availability across calendar types

Each destination reports its supported availabilities (Exchange: Free, Busy, Tentative, Unavailable; iCloud/CalDAV: Free, Busy). A value the destination can't store is left unset, and the calendar's default applies. The intended value is always kept in the marker, so a later fan-out can still write Tentative to a calendar that supports it. The GUI offers only the statuses each recipient supports.

## Consolidated sync

A consolidated sync runs every contributor to the consolidated calendar (fan-in), then the consolidated calendar to every recipient (fan-out), sequentially in one process. `GUISettings.fanInSettings` and `fanOutSettings` build the routes for both the GUI and `--sync-gui-settings`, so they always behave identically.

- **Fan-in:** full details, `Account / Calendar: Title`, availability preserved, and events the app created are skipped as sources.
- **Fan-out:** busy blocks with the configured title and availability per recipient. Free and declined events are skipped by default, and nothing goes back to its originating calendar.

## Background jobs and health

`SyncAgentInstaller` installs three LaunchAgents under the label prefix `io.github.tinleg.coordinatedcalendar.`:

- **`.watch`** runs `--watch` (`ChangeWatcher`) and is kept alive by launchd, except after a clean exit, which it makes when Calendar access is missing. It observes `EKEventStoreChanged`, waits for a quiet spell (`ChangeDebouncer`: 15 seconds, at most 60 after the first change), waits for a running sync to finish, and then `launchctl kickstart`s the sync job. It never syncs itself, so every run goes through the one sync job. It checks its own executable every few seconds: replaced (an update) means exit 75, which launchd answers by starting the new version; gone for good (the app was deleted) means a clean exit, so launchd leaves it stopped. `package-app.sh` does not wait for it.
- **`.sync`** runs `--sync-gui-settings --execute` over a rolling window, when the watcher starts it, at the interval chosen on the Schedule page, and at login. It first computes a `SyncSignature` of every event in every calendar it touches plus the saved settings, the effective settings of every route it would run, the window, the app version and the build (the executable's file identity), and stops when that matches the signature recorded when the last successful full sync started (`sync-signature.json`) and that sync is under six hours old. The recorded signature is the one from before the run, so a run's own writes lead to one confirming full run; a failed run records nothing.
- **`.health`** runs `--health-check --notify` every 15 minutes and does not run at load. It alerts when the last sync is older than four intervals or had failures. It repeats every six hours while a problem persists, and posts once on recovery.

A real consolidated sync records its outcome in `last-sync.json`. The Status page shows health, the last sync and each job's schedule, command, launchd state, run count, last exit code and logs. Installing refuses to run from a temporary folder.

## Uninstall

`removeAllCopies` (**Remove Everything** on the Status page, or `--remove-all-copies`) first removes the background jobs so nothing is recreated. It then deletes every event carrying the marker or mapped in the ledger, in every writable calendar, over a ±10-year window fetched in slices, and clears the ledger. A preview runs first by default. Events without the marker, including anything a user added to the consolidated calendar, are never touched.

## GUI

The window is a sidebar of pages:

- **Status:** Calendar access, background sync health, background job details, a setup summary, and uninstall.
- **Calendars:** fan-in contributors on the left, the consolidated card in the middle (picker, in/out counts, busy-block title, skip options), and fan-out recipients on the right with availability pickers. Curves are drawn from row anchors, and the card is centered on the calendar lists.
- **Schedule:** the sync interval and date window.
- **Preview & Run:** preview or execute a consolidated sync, and inspect every planned change.
- **Manual Copy:** a one-off copy between two calendars, with its own field options.

Two launch options help with documentation:

- `-initialPage <Page>` opens a given page.
- `-closeWindowAfter <seconds>` closes the window on a timer, as the red button does, so that closing and reopening can be checked from a script; clicking the button itself needs accessibility permission.
- `-demoMode YES` shows synthetic calendars and never reads or writes anything. With `-exportScreenshots DIR`, it saves each page as a PNG; the app images its own window, which needs no screen-recording permission.

## Command line

Run the app bundle's executable with a command, for example `~/Applications/CoordinatedCalendar.app/Contents/MacOS/CoordinatedCalendar --health-check`. Every command previews unless `--execute` is given.

| Command | Purpose |
|---|---|
| `--list-calendars` | Stable keys, names, writability, account type and supported availabilities. |
| `--copy`, `--delete` | One route between two calendars, and deleting its copies. |
| `--fan-in`, `--fan-out`, `--cycle` | Consolidated routes built from command-line options. |
| `--sync-gui-settings` | The consolidated sync from the GUI's saved settings, which is what the background job runs. |
| `--install-sync-agent` | Replace all of the app's LaunchAgents with the sync, change-watcher and health jobs. |
| `--watch` | Stay running and start the sync job shortly after the calendars change (the `.watch` job). |
| `--health-check [--notify]` | Check the last sync, optionally notifying. |
| `--remove-all-copies` | Uninstall: remove the jobs and every copy. |
| `--install-agent`, `--uninstall-agent` | The older single `--cycle` agent. |

Useful options include `--verbose` (list each action on stderr), `--busy-title`, `--include-free`, `--include-declined`, `--availability` and `--window-days-past`/`--window-days-future`. Errors always go to stderr.

## Local data

In `~/Library/Application Support/CoordinatedCalendar/`: `mappings.json` (ledger), `gui-settings.json`, `last-sync.json` and `health-alert.json`. Logs are in `~/Library/Logs/io.github.tinleg.coordinatedcalendar.*.log`.

## Build, test and release

- **Build and install:** `scripts/verify-on-mac.sh` runs the tests, builds a release binary and runs `scripts/package-app.sh`. Packaging assembles the bundle beside `~/Applications/CoordinatedCalendar.app`, signs it with a stable identity when one exists (ad-hoc otherwise), waits for any running sync, and swaps it in whole.
- **Icon and preview image:** `scripts/generate-icon.swift` draws the desk-calendar² icon and builds the `.icns`. `scripts/generate-social-preview.swift` renders the 1280×640 GitHub preview from it.
- **CI:** GitHub Actions runs `swift test` and a release build on a macOS runner, which currently has Swift 6.1 / Xcode 16.4. That is the supported minimum.
- **Releasing:** see [RELEASING.md](RELEASING.md).
