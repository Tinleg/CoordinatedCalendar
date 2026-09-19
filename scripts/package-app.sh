#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${COORDINATEDCALENDAR_SCRATCH:-$ROOT_DIR/.build}"
APP_DIR="${COORDINATEDCALENDAR_APP_DIR:-$HOME/Applications/CoordinatedCalendar.app}"
APP_LINK="$ROOT_DIR/.build/CoordinatedCalendar.app"
# Assemble next to the destination, then swap it in, so a scheduled sync never finds a half-built app.
STAGE_DIR="$(dirname "$APP_DIR")/.CoordinatedCalendar.app.staging"
CONTENTS_DIR="$STAGE_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BINARY="$BUILD_ROOT/release/CoordinatedCalendar"

if [[ ! -x "$BINARY" ]]; then
  swift build -c release --scratch-path "$BUILD_ROOT"
fi

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

if command -v codesign >/dev/null 2>&1; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -F "$SIGN_IDENTITY" >/dev/null; then
    codesign --force --sign "$SIGN_IDENTITY" "$STAGE_DIR" >/dev/null
  elif FIRST_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/valid identities found/{exit} /"/{print $2; exit}')" && [[ -n "$FIRST_IDENTITY" ]]; then
    codesign --force --sign "$FIRST_IDENTITY" "$STAGE_DIR" >/dev/null
  else
    codesign --force --sign - "$STAGE_DIR" >/dev/null
  fi
fi

# Wait for a running scheduled sync (the GUI runs without arguments and is not waited on).
while pgrep -f "$APP_DIR/Contents/MacOS/CoordinatedCalendar --" >/dev/null 2>&1; do
  echo "Waiting for the running CoordinatedCalendar sync to finish..."
  sleep 5
done
rm -rf "$APP_DIR"
mv "$STAGE_DIR" "$APP_DIR"

mkdir -p "$ROOT_DIR/.build"
rm -rf "$APP_LINK"
ln -s "$APP_DIR" "$APP_LINK"
