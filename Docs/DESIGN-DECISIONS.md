# Design decisions

The choices that shape CoordinatedCalendar, why they were made, and what would break if they were reversed. Each entry is short on purpose; see [ARCHITECTURE.md](ARCHITECTURE.md) for the mechanics.

## Work only through macOS Calendar (EventKit)

**Decision:** read and write calendars only through EventKit and the accounts already in macOS Calendar. No provider APIs, OAuth apps, API keys or stored credentials.

**Why:** sign-in, token refresh and re-authentication are Apple's problem. It works with any account the Calendar app can use, including Exchange tenants that block third-party calendar services. Nothing leaves the Mac.

**Cost:** a Mac has to be on and awake to sync, delivery rides on each provider's own sync delay, and only what EventKit exposes can be copied.

## Hub and spoke through one consolidated calendar

**Decision:** gather everything into one consolidated calendar with full details, and fan busy blocks out from there, instead of mirroring every calendar directly to every other.

**Why:** the user gets one complete private view, and N calendars need N fan-in routes plus N fan-out routes, not N×(N−1). Origin tracking stops a block going back to the calendar it came from.

**Cost:** the consolidated calendar holds readable details of every account, so it has to live in an account where that is acceptable (documented in the README).

## Busy blocks carry almost nothing, and the rule is enforced every run

**Decision:** a busy block carries only its title, times, availability, the private flag where supported, and the marker. Every fan-out run strips existing blocks back to that. Events marked Free and declined meetings get no block by default.

**Why:** the point is to share *when* you are busy without leaking *what* you are doing between accounts. Accounts sometimes add default alerts or other fields after creation; enforcing on every run keeps blocks clean regardless. Free and declined events don't take up your time.

## The notes marker, not the ledger, identifies copies

**Decision:** every copy carries a marker in its notes with deterministic identities. The local ledger is only a cache.

**Why:** the marker travels with the event, so any Mac can recognize, update, deduplicate and clean up copies another Mac made, and a lost ledger costs nothing.

**Consequences:**
- IDs must be computed identically everywhere. They derive from the event's cross-device identifier, the occurrence start and calendar display names, so account and calendar names must match on every Mac.
- When two Macs create the same copy before syncing, duplicates are resolved by a deterministic keeper (earliest created, then smallest cross-device identifier) so both Macs keep the same one.

## Markers reveal no names, except in your own hub

**Decision:** calendar names inside the marker are `sha256:` tokens, and IDs are hashes. The marker holds no event content. **A full-detail copy is the exception:** in the consolidated calendar it also names its source event and source calendar in the clear.

**Why:** a busy block sits in someone else's account (a client's Exchange calendar, say). Anyone who decodes its notes should learn nothing about your other calendars. The consolidated calendar is not someone else's account — it is your own hub, and tools that read it need to know which event a copy came from. Hashing that away forced them to match on title and time, which fails exactly when an event is edited: a moved meeting looks like a different meeting. Naming the source ends that class of bug.

**The boundary is enforced, not just intended:** the builder writes those fields only on full-detail copies, and `FreeBusyCompliance` treats a source reference on a busy block as a violation and strips it on the next run, whatever put it there.

## The identity namespace is part of every ID

**Decision:** identities and name tokens hash in a namespace string (`CoordinatedCalendar`).

**Why and cost:** changing it changes every copy's ID, which would make the app treat every existing copy as foreign, delete and recreate them, and change their event IDs. Any future change must be a two-phase migration: ship a build that recognizes both namespaces and rewrites markers in place, confirm nothing old remains, then remove the old namespace. That is how the namespace was changed once already.

## Survive an account being removed and re-added

**Decision:** trust the ledger's calendar keys only while those calendars exist, fall back to the marker's calendar names, and re-link a copy to its source in place when the source is plainly the same event under new identifiers.

**Why:** removing and re-adding an account is the standard fix when macOS Calendar drops events, and it changes both the account's calendar keys and every event's identifiers. Before this, the app treated the account's own events as foreign — putting a busy block on top of each of them, in a calendar other people can see — and deleted and recreated every copy it had made from that account, changing their event IDs.

**The re-link rule is deliberately narrow:** an exact match on the title the copy would have, start, end and all-day, and one-to-one on both sides. Two real events with the same title and times would be a guess, and recreating one copy is better than attaching it to the wrong event.

**Settings follow the calendar too.** Settings are keyed by calendar key, so they also record each selected calendar's name; a key that vanishes is re-attached to the one calendar now carrying its name, with its per-calendar settings. A selected calendar that is merely absent — an account offline for a while — stays selected and is reported, rather than being dropped as it used to be.

## Copy occurrences, never recurrence rules

**Decision:** EventKit expands recurring events, and each occurrence is copied as a single event. Copies never get recurrence rules; full-detail copies describe the rule in `Source details:`.

**Why:** putting a rule on a copied occurrence makes the destination expand it again, producing phantom busy time that no longer matches the source. This happened in practice before the rule was adopted.

## Updates happen in place

**Decision:** when a source changes, its copy is updated rather than deleted and recreated. Recreating is reserved for recurring copies, duplicates and uninstall.

**Why:** tools that read the consolidated calendar can key on event IDs. Stable IDs keep their references valid.

## Fingerprint parts are appended only when present

**Decision:** new inputs to the fingerprint (`place:`, `details:`, `notes:verbatim`) are added only when the source has them.

**Why:** a new fingerprint part would otherwise change every copy's fingerprint and rewrite every copy once. Appending conditionally limits a feature rollout to the copies it actually affects. A test pins the fingerprint of a plain event so this stays true.

**And every part must be the same in every run.** A recurrence rule's description begins with the object's memory address, which differs per process; hashing it made every recurring event's copy rewrite on every sync. Anything added to the fingerprint has to be checked for this: build it twice in one process and compare.

## Unsupported availability is left unset, and the intent is kept in the marker

**Decision:** write a status only if the destination supports it; otherwise leave it for the calendar's default, and store the intended status in the marker.

**Why:** iCloud can't store Tentative. Keeping the intent means a Tentative meeting that passed through an iCloud consolidated calendar still arrives as Tentative on an Exchange recipient.

## Fetch long windows in slices

**Decision:** fetch every window in one-year slices.

**Why:** `predicateForEvents` silently returns only the first four years of a longer range. The default window is about six years.

## One background job, not one per calendar

**Decision:** a single LaunchAgent runs every fan-in, then every fan-out, from the saved settings, plus a separate health check.

**Why:** separate per-calendar jobs could overlap and race. One sequential run is simpler to reason about, and fan-out always sees the freshest consolidated calendar. Per-calendar intervals were dropped for the same reason.

## The app lives in ~/Applications, never a temporary folder

**Decision:** packaging installs to `~/Applications`, and installing background jobs from a temporary location is refused.

**Why:** an early build ran from `/private/tmp`, which macOS clears on restart, so syncing stopped silently after a reboot. The health check exists partly because of that.

## Keep the GUI and CLI on one code path

**Decision:** `GUISettings.fanInSettings`/`fanOutSettings` build the routes for both the GUI and `--sync-gui-settings`.

**Why:** previewing in the GUI must mean exactly what the background job will do.

## Support Swift 6.1 / Xcode 16.4

**Decision:** CI builds with the oldest toolchain GitHub's macOS runner provides, and code must compile there.

**Why:** users build from source. One construct (a `@MainActor` closure passed into a view) crashed the Swift 6.1 compiler, although it built on newer toolchains; CI caught it.

## Source-available: MIT with the Commons Clause

**Decision:** from 0.1.1 on, MIT plus the Commons Clause: free to use, modify and share, including for work, but not to sell or to offer as a paid product or service built substantially on it. Version 0.1.0 was published under plain MIT.

**Why:** the author wants anyone, including consultants using it for their own calendars, to use it freely, but not to see it resold. The trade-off is that it isn't OSI open source.

## Distribute as source, not a signed download

**Decision:** releases are source-only; users build with `scripts/verify-on-mac.sh`.

**Why:** a downloadable app without a paid Apple Developer ID would trip macOS security warnings. Building locally avoids that and keeps the Calendar permission tied to the user's own signing identity.
