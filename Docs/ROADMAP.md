# Roadmap and future thinking

Ideas, known limitations and open questions. Nothing here is committed to; it's a place to think out loud about where CoordinatedCalendar could go. Items that would change what other tools read from the consolidated calendar (fields, marker format, event IDs) should be designed as migrations; see [DESIGN-DECISIONS.md](DESIGN-DECISIONS.md).

## Likely next steps

### Filters
Let a user exclude events from fan-out (or fan-in) by title keyword, calendar, or all-day status, per recipient. For example, keep "Focus time" or "Lunch" out of a client's calendar, or don't block time for all-day informational events. Filters would slot into the same "non-blocking" step that already skips Free and declined events, so blocks for newly excluded events are removed automatically.

### Per-recipient busy titles
Today one busy title applies everywhere. Some users want `Busy – Work` on a client calendar but plain `Busy` on a personal one. Store an optional title per recipient, falling back to the global one. Changing a title already retitles existing blocks through the fingerprint.

### Menu bar presence
A small menu bar item showing health (last sync, next run, problems) and a "Sync now" action, so the full window is only needed for setup.

### Status notifications with detail
The health notification says something is wrong; it could also say which route failed and link to the Status page.

## Distribution

### Downloadable, notarized app
Source-only releases ask users to build with Xcode tools. A signed, notarized DMG attached to each GitHub release would let non-developers install it. This needs an Apple Developer ID. If added, release automation should build, sign and notarize on CI.

### Homebrew
A Homebrew cask (once there's a notarized build) or a formula that builds from source would make installing and updating one command.

### Update checks
Once there are downloadable builds, a lightweight "a new version is available" check against GitHub releases.

## Sync behavior

### Faster reaction to changes
Syncing runs on a timer (5 minutes by default). Observing `EKEventStoreChanged` while the app or a small agent runs could trigger a sync shortly after a change, with the timer as a fallback. Needs care to debounce bursts of changes and to coexist with the background job.

### Busy blocks for tentative meetings
Tentative events already fan out, with availability preserved where the recipient supports it. Some users may want an option to skip tentative events entirely, like Free ones.

### Travel time and buffers
EventKit doesn't expose Calendar's travel time. An option to pad busy blocks (for example, 15 minutes before in-person meetings with a location) would approximate it.

### Working-hours awareness
Optionally fan out only events inside each recipient's working hours, or collapse evenings and weekends into one block.

### Consolidated calendar as an ICS feed
Serve (or export on a schedule) a read-only ICS file of the consolidated view for tools that can't read macOS Calendar. It would have to stay local or be explicitly published by the user, given the consolidated calendar's full details.

### More than one consolidated calendar
Some users might want separate hubs (say, work and personal) with different recipients. The route model already supports any source and destination, so this is mostly settings and UI.

## Robustness and multi-Mac

### Automatic scheduling ownership
Several Macs can run the app without duplicating copies, but running the scheduled sync on one Mac is simplest. A lightweight "who owns the schedule" marker (for example, a note on a hidden event in the consolidated calendar) could let a second Mac take over automatically if the first stops syncing.

### Graceful handling of provider outages
When one account fails (expired sign-in, server down), other routes still run and the failure is reported. A per-route "last success" on the Status page would make partial outages clearer.

### Calendar renames
Copy identities include calendar display names, so renaming a calendar (or an account in Calendar settings) makes its existing copies look foreign: they're removed and recreated. A rename-aware migration could match old and new names by stable key on the Mac where the rename happened, and rewrite markers in place. (The opposite case — same names, new keys and event identifiers, which is what re-adding an account produces — is handled as of 0.2.0; see DESIGN-DECISIONS.md.)

## Code health

### Engine tests against a fake event store
Unit tests cover identities, markers, fingerprints, compliance, details, slicing, duplicates and health, but the route logic in `CoordinatedCalendarEngine.run` is verified only against real calendars. Abstracting the few EventKit calls behind a protocol would allow end-to-end tests of fan-in, fan-out, updates, reconciliation, skips and uninstall with synthetic calendars.

### Retire migration code
Two migrations have run everywhere they need to, and could be removed in a future version (each removal is harmless for current copies):
- the `hasPlainCalendarNames` path, which rewrites markers from before calendar names were hashed;
- the `notes:verbatim` fingerprint part, which re-copied notes damaged by an old CRLF bug. Removing it would re-copy those events once, so batch it with another change that touches fan-in copies.

### Split the engine
`CoordinatedCalendarEngine.swift` is large. The cleanup pass, reconciliation, per-event processing and uninstall could live in separate files or types without changing behavior.

### Localization and accessibility
Strings are English-only and inline. Moving them to a string catalog would allow translations; a VoiceOver pass over the Calendars page (checkboxes, curves) would help accessibility.

## Known limitations (by design or platform)

- A Mac has to be on, awake and logged in for syncing to happen.
- Delivery to other devices depends on each provider's sync speed.
- Declined meetings are only detectable when the account keeps them with your attendee status; some providers delete them instead.
- Attendees, organizer and status can't be written onto copies (EventKit), so they appear as text in the consolidated copy's notes.
- Account and calendar names must match on every Mac that runs the app.
- Edits made directly to a copy are overwritten; edit the original event.
