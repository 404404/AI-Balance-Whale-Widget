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
for resource in WhaleWidget.html Settings.html NativeContextMenu.html AppIcon.icns DSniang1.png Ya1.mp3 task-end-a.wav; do
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

codesign --verify --deep --strict --verbose=2 "$APP"
lipo -archs "$APP/Contents/MacOS/AIBalanceWhale" | grep -Eq '(^| )arm64( |$)'
echo "verified $APP ($TAG, marketing $SHORT, build $BUILD)"
