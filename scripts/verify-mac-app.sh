#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/AI Balance Whale.app}"
EXPECTED_VERSION="${VERSION:-$(node -p "require('$ROOT/package.json').version")}"
[[ -d "$APP" ]] || { echo "App bundle missing: $APP" >&2; exit 1; }
[[ -f "$APP/Contents/Resources/app.asar" ]] || { echo "app.asar missing" >&2; exit 1; }
BINARY="$APP/Contents/MacOS/AI Balance Whale"
[[ -x "$BINARY" ]] || { echo "main executable missing" >&2; exit 1; }
file "$BINARY" | grep -Eqi 'arm64|universal' || { echo "main executable is not arm64: $(file "$BINARY")" >&2; exit 1; }
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$PLIST_VERSION" == "$EXPECTED_VERSION" ]] || { echo "version mismatch: $PLIST_VERSION != $EXPECTED_VERSION" >&2; exit 1; }
for required in assets/DSniang1.png assets/whale-widget.js desktop/ui/widget.html runtime/dispatcher.mjs lib/widget-host.mjs; do
  npx --no-install asar list "$APP/Contents/Resources/app.asar" | grep -Fq "$required" || { echo "missing packaged resource: $required" >&2; exit 1; }
done
codesign --verify --deep --strict --verbose=2 "$APP"
printf 'verified App=%s version=%s arch=arm64\n' "$APP" "$PLIST_VERSION"
