#!/usr/bin/env bash
set -euo pipefail

APP="${1:-}"
if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "usage: $0 /path/to/AI Balance Whale.app" >&2
  exit 2
fi

plist_print() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"
}

test -x "$APP/Contents/MacOS/AIBalanceWhale"
for resource in WhaleWidget.html Settings.html NativeContextMenu.html upstream-bubble-defaults.json AppIcon.icns DSniang1.png Ya1.mp3 task-end-a.wav; do
  test -f "$APP/Contents/Resources/$resource"
done

SHORT="$(plist_print CFBundleShortVersionString)"
TAG="$(plist_print AIAppReleaseTag)"
BUILD="$(plist_print CFBundleVersion)"
ICON="$(plist_print CFBundleIconFile)"

[[ "$SHORT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "invalid CFBundleShortVersionString: $SHORT" >&2; exit 2; }
[[ "$TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || { echo "invalid AIAppReleaseTag: $TAG" >&2; exit 2; }
[[ "$BUILD" =~ ^[1-9][0-9]*$ ]] || { echo "invalid CFBundleVersion: $BUILD" >&2; exit 2; }
test "$SHORT" = "${TAG%%-*}"
test "$ICON" = "AppIcon"

# Verify that the bundle was assembled from this checkout, rather than merely
# containing files with the right names. This also protects the DMG path when
# the build script is changed to copy resources from another location.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for pair in \
  "$ROOT/MacOSApp/Resources/WhaleWidget.html|$APP/Contents/Resources/WhaleWidget.html" \
  "$ROOT/MacOSApp/Resources/Settings.html|$APP/Contents/Resources/Settings.html" \
  "$ROOT/MacOSApp/Resources/NativeContextMenu.html|$APP/Contents/Resources/NativeContextMenu.html" \
  "$ROOT/assets/whale-widget.js|$APP/Contents/Resources/whale-widget.js" \
  "$ROOT/MacOSApp/acceptance/upstream-bubble-defaults.json|$APP/Contents/Resources/upstream-bubble-defaults.json"; do
  SOURCE_FILE="${pair%%|*}"
  BUNDLE_FILE="${pair#*|}"
  cmp -s "$SOURCE_FILE" "$BUNDLE_FILE" || { echo "bundle resource differs from checkout: $BUNDLE_FILE" >&2; exit 2; }
done

codesign --verify --deep --strict --verbose=2 "$APP"
lipo -archs "$APP/Contents/MacOS/AIBalanceWhale" | grep -Eq '(^| )arm64( |$)'
echo "verified $APP ($TAG, marketing $SHORT, build $BUILD)"
