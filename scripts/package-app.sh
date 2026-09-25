#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/signing-identity.sh"
BUILD_ROOT="${COORDINATEDCALENDAR_SCRATCH:-$ROOT_DIR/.build}"
DEFAULT_APP_DIR="$HOME/Applications/CoordinatedCalendar.app"
APP_DIR="${COORDINATEDCALENDAR_APP_DIR:-$DEFAULT_APP_DIR}"
APP_LINK="$ROOT_DIR/.build/CoordinatedCalendar.app"
# Assemble next to the destination, then swap it in, so a scheduled sync never finds a half-built app.
STAGE_DIR="$(dirname "$APP_DIR")/.CoordinatedCalendar.app.staging"
CONTENTS_DIR="$STAGE_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BINARY="$BUILD_ROOT/release/CoordinatedCalendar"

# Always build: skipping the build when a binary already existed repackaged a stale one, silently,
# with whatever the last release build happened to contain. The build is incremental, so it is cheap.
swift build -c release --scratch-path "$BUILD_ROOT"

rm -rf "$STAGE_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BINARY" "$MACOS_DIR/CoordinatedCalendar"
cp "$ROOT_DIR/Packaging/Info.plist" "$CONTENTS_DIR/Info.plist"
if [[ -f "$ROOT_DIR/Packaging/CoordinatedCalendar.icns" ]]; then
  cp "$ROOT_DIR/Packaging/CoordinatedCalendar.icns" "$RESOURCES_DIR/CoordinatedCalendar.icns"
fi

cat > "$CONTENTS_DIR/PkgInfo" <<'PKGINFO'
APPL????
PKGINFO

if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$STAGE_DIR" 2>/dev/null || true
fi

SIGN_IDENTITY="${COORDINATEDCALENDAR_SIGN_IDENTITY:-CoordinatedCalendar Local}"
# Hardened runtime on every build, whatever the identity, so the app always runs under the same rules a
# notarized download does. Calendar access is refused under it unless the entitlement below is declared.
SIGN_FLAGS=(--force --options runtime --entitlements "$ROOT_DIR/Packaging/CoordinatedCalendar.entitlements")

if command -v codesign >/dev/null 2>&1; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -F "$SIGN_IDENTITY" >/dev/null; then
    IDENTITY="$SIGN_IDENTITY"
  elif FIRST_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/valid identities found/{done=1} /"/ && !done {print $2; done=1}')" && [[ -n "$FIRST_IDENTITY" ]]; then
    IDENTITY="$FIRST_IDENTITY"
  else
    IDENTITY="-"
  fi
  # Notarization requires a secure timestamp, which only matters for (and only works with) Developer ID.
  if [[ "$IDENTITY" == "Developer ID Application"* ]]; then
    SIGN_FLAGS+=(--timestamp)
  fi
  # By fingerprint: a name can belong to more than one certificate (see signing-identity.sh).
  SIGN_WITH="$IDENTITY"
  [[ "$IDENTITY" == "-" ]] || SIGN_WITH="$(signing_identity "$IDENTITY")"
  codesign "${SIGN_FLAGS[@]}" --sign "${SIGN_WITH:-$IDENTITY}" "$STAGE_DIR" >/dev/null
fi

# Wait for a running scheduled sync. The GUI runs without arguments and is not waited on, nor is the change
# watcher (--watch), which never exits: it notices the replaced app and restarts itself on the new one.
running_commands() {
  pgrep -fl "$APP_DIR/Contents/MacOS/CoordinatedCalendar --" 2>/dev/null | grep -v -- "--watch" || true
}
while [[ -n "$(running_commands)" ]]; do
  echo "Waiting for the running CoordinatedCalendar sync to finish..."
  sleep 5
done
rm -rf "$APP_DIR"
mv "$STAGE_DIR" "$APP_DIR"

# The development shortcut follows the installed app only. Building a copy elsewhere — a release build,
# a test — used to re-point it at that copy.
if [[ "$APP_DIR" == "$DEFAULT_APP_DIR" ]]; then
  mkdir -p "$ROOT_DIR/.build"
  rm -rf "$APP_LINK"
  ln -s "$APP_DIR" "$APP_LINK"
fi
