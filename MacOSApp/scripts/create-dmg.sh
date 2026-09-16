#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT="$ROOT/MacOSApp"
APP="$PROJECT/dist/AI Balance Whale.app"
APP_VERSION="${APP_VERSION:-0.1.0-beta.7}"
DMG_NAME="${DMG_NAME:-AI-Balance-Whale-macos-${APP_VERSION}-arm64.dmg}"
DMG="$PROJECT/dist/$DMG_NAME"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/ai-balance-whale-dmg.XXXXXX")"
MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/ai-balance-whale-mount.XXXXXX")"
ATTACHED=0
cleanup() {
  if [[ "$ATTACHED" == 1 ]]; then hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true; fi
  rm -rf "$STAGING" "$MOUNT"
}
trap cleanup EXIT

test -d "$APP"
cp -R "$APP" "$STAGING/AI Balance Whale.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "AI Balance Whale" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DMG" >/dev/null
ATTACHED=1
test -d "$MOUNT/AI Balance Whale.app"
test -e "$MOUNT/Applications"
test -f "$MOUNT/AI Balance Whale.app/Contents/Resources/WhaleWidget.html"
lipo -archs "$MOUNT/AI Balance Whale.app/Contents/MacOS/AIBalanceWhale" | grep -Eq '(^| )arm64( |$)'
hdiutil detach "$MOUNT" >/dev/null
ATTACHED=0
shasum -a 256 "$DMG" | awk '{print $1 "  " $2}' > "$PROJECT/dist/SHA256SUMS"
echo "Created $DMG"
