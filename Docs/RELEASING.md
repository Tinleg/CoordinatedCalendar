# Releasing

How a CoordinatedCalendar release is made. Releases are source-only snapshots of `main`, tagged `vX.Y.Z`.

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

1. **Changelog:** make sure every user-visible change since the last release is under `## Unreleased` in `CHANGELOG.md`, then rename that heading to the new version.
2. **Version:** in `Packaging/Info.plist`, set `CFBundleShortVersionString` to the new version and increase `CFBundleVersion` by one:

   ```bash
   /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.1.3" -c "Set :CFBundleVersion 4" Packaging/Info.plist
   ```

3. **Visuals:** if the icon, pages or wording changed, regenerate the assets:

   ```bash
   swift scripts/generate-icon.swift
   swift scripts/generate-social-preview.swift
   ~/Applications/CoordinatedCalendar.app/Contents/MacOS/CoordinatedCalendar -demoMode YES -exportScreenshots /tmp/cc-shots
   ```

   Copy the needed screenshots from `/tmp/cc-shots` into `Docs/images/`, scaling them to about 1300 px wide with `sips -Z 1300`.
4. **Commit and push:** commit as "Release X.Y.Z" and push `main`.
5. **Wait for CI:** the workflow must pass on that commit, because it builds with the oldest supported toolchain.
6. **Tag:** tag the commit and push the tag:

   ```bash
   git tag -a vX.Y.Z -m "CoordinatedCalendar X.Y.Z" <commit>
   git push origin vX.Y.Z
   ```

7. **Publish:** create the GitHub release from the tag, marked **Latest**. Use the changelog section as the notes, plus the license line and the build-from-source line from earlier releases:

   ```bash
   gh release create vX.Y.Z --title "CoordinatedCalendar X.Y.Z" --latest --notes "..."
   ```

8. **Social preview:** if the preview image changed, upload `Docs/images/social-preview.png` in the repository's Settings > General > Social preview. It's a repository setting, not part of the release.

## Rules

- **Never move or re-create a published tag.** Fix mistakes with a new patch release.
- **Keep the fingerprint test green.** `fingerprintWithoutPlaceIsUnchangedFromPriorReleases` pins a plain event's fingerprint. If it fails, a change would rewrite every existing copy; make the new part conditional instead.
- **Don't change `BridgeEventMetadata.identityNamespace`** without a two-phase migration (see DESIGN-DECISIONS.md).
