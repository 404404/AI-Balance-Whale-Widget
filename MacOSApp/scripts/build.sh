#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT="$ROOT/MacOSApp"
APP_VERSION="${APP_VERSION:-0.1.0-beta.6}"
BUILD_NUMBER="${BUILD_NUMBER:-2}"
DIST="$PROJECT/dist"
APP="$DIST/AI Balance Whale.app"

if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "invalid APP_VERSION: $APP_VERSION" >&2
  exit 2
fi
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "invalid BUILD_NUMBER: $BUILD_NUMBER" >&2
  exit 2
fi
MARKETING_VERSION="${APP_VERSION%%-*}"

rm -rf "$DIST"
mkdir -p "$DIST"
cd "$PROJECT"
swift build -c release --arch arm64 --product AIBalanceWhale
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
test -x "$BIN_DIR/AIBalanceWhale"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/AIBalanceWhale" "$APP/Contents/MacOS/AIBalanceWhale"
cp "$PROJECT/Resources/WhaleWidget.html" "$APP/Contents/Resources/WhaleWidget.html"
cp "$PROJECT/Resources/Settings.html" "$APP/Contents/Resources/Settings.html"
cp "$PROJECT/Resources/Info.plist" "$APP/Contents/Info.plist"
for asset in DSniang1.png DSniang02.png D1.mp3 D2.mp3 Ya1.mp3 Ya2.mp3 bubble-money1.gif bubble-petpet.gif minecraft-exp-orb.wav rua.gif task-end-a.wav whale-widget.js; do
  test -f "$ROOT/assets/$asset"
  cp "$ROOT/assets/$asset" "$APP/Contents/Resources/$asset"
done

ICONSET="$APP/Contents/Resources/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  double=$((size * 2))
  sips -z "$size" "$size" "$ROOT/assets/DSniang1.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z "$double" "$double" "$ROOT/assets/DSniang1.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns --output "$APP/Contents/Resources/AppIcon.icns" "$ICONSET"
rm -rf "$ICONSET"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :AIAppReleaseTag $APP_VERSION" "$APP/Contents/Info.plist"

SIGNING_MODE="${SIGNING_MODE:-ad-hoc}"
if [[ "$SIGNING_MODE" == "developer-id" ]]; then
  [[ -n "${SIGNING_IDENTITY:-}" ]] || { echo "developer-id signing selected without SIGNING_IDENTITY" >&2; exit 3; }
  codesign --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
else
  [[ "$SIGNING_MODE" == "ad-hoc" ]] || { echo "unknown SIGNING_MODE: $SIGNING_MODE" >&2; exit 3; }
  codesign --force --deep --sign - --timestamp=none "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$MARKETING_VERSION"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" = "$BUILD_NUMBER"
test -f "$APP/Contents/Resources/WhaleWidget.html"
test -f "$APP/Contents/Resources/Settings.html"
test -f "$APP/Contents/Resources/AppIcon.icns"
test -f "$APP/Contents/Resources/DSniang1.png"
test -f "$APP/Contents/Resources/Ya1.mp3"
test -f "$APP/Contents/Resources/AppIcon.icns"
test -f "$APP/Contents/Resources/task-end-a.wav"
lipo -archs "$APP/Contents/MacOS/AIBalanceWhale" | grep -Eq '(^| )arm64( |$)'
echo "Built $APP ($APP_VERSION, build $BUILD_NUMBER, $SIGNING_MODE)"
