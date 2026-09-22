#!/usr/bin/env bash
# Builds dist/CoordinatedCalendar-<version>.dmg: the app next to a shortcut to Applications, over a
# background with an arrow, so opening the image shows the familiar "drag to Applications" window.
#
#   ./scripts/make-dmg.sh
#
# Signing and notarization happen when their prerequisites exist, and are reported either way:
#   - A "Developer ID Application" certificate in the keychain signs the app (hardened runtime, secure
#     timestamp) and the image. Without one, the app is signed with COORDINATEDCALENDAR_SIGN_IDENTITY
#     or the first code-signing identity (releases use the Apple Development certificate), and other
#     Macs ask for a one-time "Open Anyway" in System Settings > Privacy & Security.
#   - COORDINATEDCALENDAR_NOTARY_PROFILE, the name given to `xcrun notarytool store-credentials`,
#     notarizes and staples the image. Without it the image is not notarized.
#   - COORDINATEDCALENDAR_SKIP_LAYOUT=1 leaves Finder's default window, for machines where Finder
#     cannot be scripted (CI).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Packaging/Info.plist")"
VOLUME="CoordinatedCalendar"
DIST="$ROOT_DIR/dist"
WORK="$DIST/work"
OUTPUT="$DIST/CoordinatedCalendar-$VERSION.dmg"
BACKGROUND="$ROOT_DIR/Packaging/dmg-background.tiff"
# Window and icon geometry. Must match scripts/generate-dmg-background.swift.
WINDOW_WIDTH=660
WINDOW_HEIGHT=400
APP_X=170
APPLICATIONS_X=490
ICONS_Y=185

[[ -f "$BACKGROUND" ]] || { echo "Missing $BACKGROUND; run: swift scripts/generate-dmg-background.swift" >&2; exit 1; }
if hdiutil info | grep -q "/Volumes/$VOLUME"; then
  echo "A volume named $VOLUME is already mounted; eject it first." >&2
  exit 1
fi

DEVELOPER_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/"Developer ID Application/{print $2; exit}')"

rm -rf "$WORK" "$OUTPUT"
mkdir -p "$WORK/root/.background"

echo "Building CoordinatedCalendar $VERSION..."
if [[ -n "$DEVELOPER_ID" ]]; then
  COORDINATEDCALENDAR_SIGN_IDENTITY="$DEVELOPER_ID" COORDINATEDCALENDAR_APP_DIR="$WORK/root/CoordinatedCalendar.app" \
    "$ROOT_DIR/scripts/package-app.sh" >/dev/null
else
  COORDINATEDCALENDAR_APP_DIR="$WORK/root/CoordinatedCalendar.app" "$ROOT_DIR/scripts/package-app.sh" >/dev/null
fi
ln -s /Applications "$WORK/root/Applications"
cp "$BACKGROUND" "$WORK/root/.background/background.tiff"

echo "Laying out the disk image window..."
hdiutil create -quiet -volname "$VOLUME" -srcfolder "$WORK/root" -fs HFS+ -format UDRW -ov "$WORK/layout.dmg"
MOUNT="/Volumes/$VOLUME"
hdiutil attach -quiet -readwrite -noverify -noautoopen -mountpoint "$MOUNT" "$WORK/layout.dmg"
detach() { hdiutil detach -quiet "$MOUNT" 2>/dev/null || hdiutil detach -quiet -force "$MOUNT" 2>/dev/null || true; }
trap detach EXIT

# Finder stores the window's size, background and icon positions in the image's .DS_Store. The first time
# this runs, macOS asks to let the terminal control Finder; without that the image still works, just with
# Finder's default window.
# Finder notices a newly mounted disk a moment after it mounts; asking before then fails with "Can't get disk".
for _ in $(seq 1 20); do
  [[ "${COORDINATEDCALENDAR_SKIP_LAYOUT:-}" == 1 ]] && break
  [[ "$(osascript -e "tell application \"Finder\" to exists disk \"$VOLUME\"" 2>/dev/null)" == true ]] && break
  sleep 0.5
done
STYLED=yes
if [[ "${COORDINATEDCALENDAR_SKIP_LAYOUT:-}" == 1 ]]; then
  STYLED="skipped"
elif ! LAYOUT_ERROR="$(osascript 2>&1 >/dev/null <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLUME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    -- The bounds include the title bar, about 28 points.
    set the bounds of container window to {200, 120, 200 + $WINDOW_WIDTH, 120 + $WINDOW_HEIGHT + 28}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 13
    -- By full path: the relative form (file ".background:background.tiff") fails intermittently with -10006.
    set background picture of viewOptions to (POSIX file "$MOUNT/.background/background.tiff" as alias)
    set position of item "CoordinatedCalendar.app" of container window to {$APP_X, $ICONS_Y}
    set position of item "Applications" of container window to {$APPLICATIONS_X, $ICONS_Y}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT
)"; then
  STYLED=no
  echo "Finder could not lay out the window: $LAYOUT_ERROR" >&2
fi
sync
detach
trap - EXIT

hdiutil convert -quiet "$WORK/layout.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUTPUT"
rm -rf "$WORK"

SIGNED=no
if [[ -n "$DEVELOPER_ID" ]]; then
  codesign --sign "$DEVELOPER_ID" --timestamp "$OUTPUT"
  SIGNED=yes
fi

NOTARIZED=no
if [[ -n "${COORDINATEDCALENDAR_NOTARY_PROFILE:-}" ]]; then
  [[ "$SIGNED" == yes ]] || { echo "Notarization needs a Developer ID Application certificate." >&2; exit 1; }
  echo "Notarizing (this usually takes a few minutes)..."
  xcrun notarytool submit "$OUTPUT" --keychain-profile "$COORDINATEDCALENDAR_NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUTPUT"
  spctl --assess --type open --context context:primary-signature --verbose "$OUTPUT"
  NOTARIZED=yes
fi

echo
echo "Built $OUTPUT ($(du -h "$OUTPUT" | cut -f1 | tr -d ' '))"
echo "  window layout: $STYLED$([[ $STYLED == no ]] && echo ' — allow your terminal to control Finder in System Settings > Privacy & Security > Automation, then rerun')"
echo "  Developer ID signed: $SIGNED"
echo "  notarized: $NOTARIZED$([[ $NOTARIZED == no ]] && echo ' — other Macs need a one-time Open Anyway in System Settings > Privacy & Security')"
