# Releasing

How a CoordinatedCalendar release is made. A release is a snapshot of `main`, tagged `vX.Y.Z`, with a disk image of the app attached.

## How `main`, "Unreleased" and releases relate

- `main` is the current code. Anyone building from it gets the latest changes.
- A release is a frozen, numbered snapshot of `main` at one commit. It never changes after publishing.
- Changes land on `main` under **Unreleased** in `CHANGELOG.md` until the next release gives them a version number.

## Versioning

`MAJOR.MINOR.PATCH`, starting from 0.1.0:

- **Patch** (0.1.x): fixes, visual changes, documentation and license changes.
- **Minor** (0.x.0): new features or settings.
- **Before 1.0**, a minor version may also change behavior users rely on. Call it out in the release notes.

The version lives in `Packaging/Info.plist`: `CFBundleShortVersionString` is the version, and `CFBundleVersion` is a build number that increases by one each release.

## Checklist

1. **Changelog:** make sure every user-visible change since the last release is under `## Unreleased` in `CHANGELOG.md`. The script turns that heading into the version and uses the section as the release notes.
2. **Visuals:** if the icon, pages or wording changed, regenerate the assets and commit them first:

   ```bash
   swift scripts/generate-icon.swift
   swift scripts/generate-social-preview.swift
   swift scripts/generate-dmg-background.swift
   ~/Applications/CoordinatedCalendar.app/Contents/MacOS/CoordinatedCalendar -demoMode YES -exportScreenshots /tmp/cc-shots
   ```

   Copy the needed screenshots from `/tmp/cc-shots` into `Docs/images/`, scaling them to about 1300 px wide with `sips -Z 1300`. The disk image background's geometry must match `make-dmg.sh`.
3. **Release**, from an up-to-date `main` with nothing uncommitted:

   ```bash
   ./scripts/release.sh X.Y.Z
   ```

   It checks the version is newer and the changelog has something to release, then:
   - sets `CFBundleShortVersionString` to the version and increases `CFBundleVersion` by one in `Packaging/Info.plist`, and renames `## Unreleased`;
   - runs the tests, commits "Release X.Y.Z", pushes `main` and waits for CI to pass on that commit;
   - builds the disk image (`scripts/make-dmg.sh`), and checks that the app inside is the new version and is signed with the release certificate;
   - tags the commit, pushes the tag, and publishes the GitHub release, marked **Latest**, with the image attached and its SHA-256 checksum, install steps and the license line in the notes.

   It stops before tagging if anything fails. If that happens after the release commit is pushed, fix the problem and run the same command again: it resumes from the release commit. Once a tag is published, never reuse its number.
4. **Check the download:** open the release page, download the image, and open it: the "drag to Applications" window should appear with the first-launch instructions. The first run of `make-dmg.sh` asks to let the terminal control Finder, which lays out that window; without it the image still works, with Finder's default window.
5. **Social preview:** if the preview image changed, upload `Docs/images/social-preview.png` in the repository's Settings > General > Social preview. It's a repository setting, not part of the release.

## Signing

Releases are signed with the maintainer's **Apple Development** certificate and the hardened runtime, and are **not notarized**; notarization needs a paid Apple Developer Program membership. So:

- The first launch on another Mac is blocked until the person clicks **Open Anyway** in System Settings > Privacy & Security. The README, the disk image window and the release notes all say so.
- Every release must be signed with **the same certificate**. macOS ties the Calendar permission to the signer; a different one makes every user grant access again. `release.sh` refuses an image signed by anything but `COORDINATEDCALENDAR_SIGN_IDENTITY` (default: the keychain's first Apple Development certificate).
- The certificate's name, which includes the maintainer's Apple ID email, is readable in the app's signature.

With a Developer ID certificate and stored `notarytool` credentials, `make-dmg.sh` signs with Developer ID and notarizes instead (`COORDINATEDCALENDAR_NOTARY_PROFILE=<profile>`), and the warning goes away. Switching to it changes the signer once, so users grant Calendar access again after that update; say so in its release notes.

## Rules

- **Never move or re-create a published tag.** Fix mistakes with a new patch release.
- **Keep the fingerprint test green.** `fingerprintWithoutPlaceIsUnchangedFromPriorReleases` pins a plain event's fingerprint. If it fails, a change would rewrite every existing copy; make the new part conditional instead.
- **Don't change `BridgeEventMetadata.identityNamespace`** without a two-phase migration (see DESIGN-DECISIONS.md).
