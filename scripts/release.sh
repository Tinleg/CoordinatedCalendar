#!/usr/bin/env bash
# Publishes a release: version bump, changelog, tests, CI, disk image, tag and GitHub release with the
# image and its checksum attached.
#
#   ./scripts/release.sh 0.3.0
#
# Run it on an up-to-date copy of main with nothing uncommitted. It stops before anything is published if
# the tests or CI fail, if the changelog has nothing under "## Unreleased", or if the image is not signed
# with the release certificate. The app is signed with COORDINATEDCALENDAR_SIGN_IDENTITY, or else the
# keychain's first "Apple Development" certificate: the same certificate every release, so the Calendar
# permission survives updates. The image is not notarized (see Docs/RELEASING.md).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Usage: $0 X.Y.Z" >&2; exit 1; }
TAG="v$VERSION"
PLIST="Packaging/Info.plist"
DMG="dist/CoordinatedCalendar-$VERSION.dmg"
fail() { echo "release: $*" >&2; exit 1; }

# Preconditions, before anything changes.
[[ -z "$(git status --porcelain)" ]] || fail "uncommitted changes; commit or stash them first"
git fetch --quiet origin main --tags
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "HEAD is not origin/main; pull or push first"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "$TAG already exists"
CURRENT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
# A run that stopped after pushing its release commit (CI, the image) picks up from there, including
# any fixes committed on top of it; the tag goes on the commit the image is built from.
RESUME=no
if [[ "$CURRENT" == "$VERSION" ]] && git log --format=%s | grep -qx "Release $VERSION"; then
  RESUME=yes
fi
[[ "$RESUME" == yes ]] || [[ "$(printf '%s\n%s\n' "$CURRENT" "$VERSION" | sort -V | tail -1)" == "$VERSION" && "$CURRENT" != "$VERSION" ]] \
  || fail "$VERSION is not newer than $CURRENT"
HEADING="$([[ "$RESUME" == yes ]] && echo "$VERSION" || echo Unreleased)"
UNRELEASED="$(awk -v h="## $HEADING" '$0 == h {on=1; next} /^## /{on=0} on' CHANGELOG.md | sed '/^[[:space:]]*$/d')"
[[ -n "$UNRELEASED" ]] || fail "nothing under ## $HEADING in CHANGELOG.md"
IDENTITY="${COORDINATEDCALENDAR_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/"Apple Development/ && !found {print $2; found=1}')}"
[[ -n "$IDENTITY" ]] || fail "no Apple Development certificate in the keychain; set COORDINATEDCALENDAR_SIGN_IDENTITY"
export COORDINATEDCALENDAR_SIGN_IDENTITY="$IDENTITY"
command -v gh >/dev/null || fail "the GitHub CLI (gh) is required"

echo "Releasing $VERSION, signed with: $IDENTITY"

if [[ "$RESUME" == yes ]]; then
  echo "Resuming: the release commit is already pushed; releasing $(git log -1 --format='%h %s')."
else
  # Version and changelog.
  BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $((BUILD + 1))" "$PLIST"
  sed -i '' "s/^## Unreleased$/## $VERSION/" CHANGELOG.md

  echo "Running the tests..."
  swift test ${COORDINATEDCALENDAR_SCRATCH:+--scratch-path "$COORDINATEDCALENDAR_SCRATCH/test"} >/dev/null \
    || { git checkout -- "$PLIST" CHANGELOG.md; fail "tests failed; nothing was changed"; }

  git commit --quiet -m "Release $VERSION" -- "$PLIST" CHANGELOG.md
  git push --quiet origin HEAD:main
fi
COMMIT="$(git rev-parse HEAD)"

echo "Waiting for CI on $COMMIT..."
RUN=""
for _ in $(seq 1 60); do
  RUN="$(gh run list --commit "$COMMIT" --workflow CI --json databaseId -q '.[0].databaseId' 2>/dev/null || true)"
  [[ -n "$RUN" ]] && break
  sleep 5
done
[[ -n "$RUN" ]] || fail "CI did not start for $COMMIT; the release commit is pushed but nothing is tagged"
gh run watch "$RUN" --exit-status >/dev/null || fail "CI failed (run $RUN); the release commit is pushed but nothing is tagged"

echo "Building the disk image..."
./scripts/make-dmg.sh
[[ -f "$DMG" ]] || fail "no $DMG"
MOUNT="$(mktemp -d)"
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$MOUNT" "$DMG"
trap 'hdiutil detach -quiet "$MOUNT" 2>/dev/null || true' EXIT
# awk reads everything: exiting early would end codesign with SIGPIPE, which pipefail turns into a silent stop.
SIGNER="$(codesign -dvv "$MOUNT/CoordinatedCalendar.app" 2>&1 | awk -F= '/^Authority=/ && !found {print $2; found=1}')"
VERIFY_OK=yes; codesign --verify --strict "$MOUNT/CoordinatedCalendar.app" 2>/dev/null || VERIFY_OK=no
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MOUNT/CoordinatedCalendar.app/Contents/Info.plist")"
hdiutil detach -quiet "$MOUNT"
trap - EXIT
[[ "$SIGNER" == "$IDENTITY" && "$VERIFY_OK" == yes ]] || fail "the image's app is signed by '$SIGNER' (verify: $VERIFY_OK), not '$IDENTITY'"
[[ "$APP_VERSION" == "$VERSION" ]] || fail "the image holds version $APP_VERSION"
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"

NOTES="$(mktemp)"
{
  echo "$UNRELEASED"
  echo
  echo "## Install"
  echo
  echo "Download \`CoordinatedCalendar-$VERSION.dmg\` below, open it and drag CoordinatedCalendar to Applications. The app is signed but not notarized by Apple, so the first time you open it macOS says it can't check it: click **Done**, then **System Settings > Privacy & Security > Open Anyway**. Updating from an earlier download: replace the app in Applications; settings, the Calendar permission and background jobs carry over."
  echo
  echo "SHA-256: \`$SHA\`"
  echo
  echo "Requires macOS 14 or later on a Mac with Apple silicon. Build from source: see [Install](https://github.com/Tinleg/CoordinatedCalendar#build-from-source) (Swift 6.1 or later, Xcode 16.4+)."
  echo
  echo "Licensed under MIT with the Commons Clause (see [LICENSE](https://github.com/Tinleg/CoordinatedCalendar/blob/$TAG/LICENSE))."
} > "$NOTES"

git tag -a "$TAG" -m "CoordinatedCalendar $VERSION" "$COMMIT"
git push --quiet origin "$TAG"
gh release create "$TAG" "$DMG" --title "CoordinatedCalendar $VERSION" --latest --notes-file "$NOTES"
rm -f "$NOTES"
echo "Released $VERSION: $(gh release view "$TAG" --json url -q .url)"
