#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/AI Balance Whale.app}"
VERSION="${VERSION:-$(node -p "require('$ROOT/package.json').version")}"
OUTPUT="${2:-$ROOT/dist/AI-Balance-Whale-macos-${VERSION}-arm64.dmg}"
[[ -d "$APP" ]] || { echo "App bundle missing: $APP" >&2; exit 1; }
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/ai-whale-dmg.XXXXXX")"
MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/ai-whale-mount.XXXXXX")"
ATTACHED=0
cleanup() {
  if [[ "$ATTACHED" == 1 ]]; then hdiutil detach "$MOUNT" -quiet || true; fi
  rm -rf "$STAGE" "$MOUNT"
}
trap cleanup EXIT
cp -R "$APP" "$STAGE/AI Balance Whale.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT"
hdiutil create -volname "AI Balance Whale ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO "$OUTPUT" >/dev/null
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT" "$OUTPUT" >/dev/null
ATTACHED=1
[[ -d "$MOUNT/AI Balance Whale.app" ]] || { echo 'DMG missing App' >&2; exit 1; }
[[ -L "$MOUNT/Applications" ]] || { echo 'DMG missing Applications shortcut' >&2; exit 1; }
VERSION="$VERSION" bash scripts/verify-mac-app.sh "$MOUNT/AI Balance Whale.app"
hdiutil detach "$MOUNT" -quiet
ATTACHED=0
shasum -a 256 "$OUTPUT" | tee "${OUTPUT%.dmg}.sha256"
printf 'created %s\n' "$OUTPUT"
