#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HTML="$ROOT/MacOSApp/Resources/WhaleWidget.html"
ASSET="$ROOT/assets/whale-widget.js"
SETTINGS="$ROOT/MacOSApp/Resources/Settings.html"
WINDOW="$ROOT/MacOSApp/Sources/AIBalanceWhale/WhaleWindowController.swift"
STORE="$ROOT/MacOSApp/Sources/AIBalanceWhale/WhaleConfigurationStore.swift"
HOST="$ROOT/MacOSApp/Sources/AIBalanceWhale/WhaleHostAdapter.swift"
CODEX="$ROOT/MacOSApp/Sources/AIBalanceWhale/CodexAppServerClient.swift"

for pattern in "__AIWhaleStandalone" "__AIWhaleHostResponse" "navigationToken" "bubbleLayout" "whale-widget.js"; do
  grep -Fq "$pattern" "$HTML" || { echo "missing standalone WhaleWidget pattern: $pattern" >&2; exit 1; }
done
for pattern in "contextmenu" "pointerup" "pointercancel" "dshwv-bshape" "dshwv-b1" "dshwv-b2" "BUBBLE_DEFAULT_ITEMS" "bubblePickLine" "bubblePlanWinOptions" "__AIWhaleStandalone"; do
  grep -Fq "$pattern" "$ASSET" || { echo "missing upstream asset pattern: $pattern" >&2; exit 1; }
done
for pattern in 'data-page="general"' 'data-page="models"' 'data-page="resources"' 'data-page="bubbles"' 'data-page="sounds"' 'data-page="reminders"' 'data-page="about"' 'messageHandlers.settings' 'messageHandlers.bridge' 'saveCredential' 'importResource' '__AIWhaleEditorMount'; do
  grep -Fq "$pattern" "$SETTINGS" || { echo "missing settings pattern: $pattern" >&2; exit 1; }
done
if grep -Fq '<iframe' "$SETTINGS"; then
  echo "settings must mount the upstream editor directly, not through an iframe" >&2
  exit 1
fi
grep -Fq 'WhaleLayout.contentSize' "$WINDOW"
grep -Fq 'saved.width - newSize.width' "$WINDOW"
grep -Fq 'frame.origin.y = saved.minY' "$WINDOW"
grep -Fq 'frame.origin.y = old.minY' "$WINDOW"
grep -Fq 'resourceDataURL' "$WINDOW"
grep -Fq 'Application Support' "$SETTINGS"
grep -Fq 'Keychain' "$SETTINGS"
grep -Fq 'schemaVersion' "$STORE"
grep -Fq 'builtin-dsniang' "$STORE"
grep -Fq 'account/rateLimits/read' "$CODEX"
grep -Fq 'upstreamBubble' "$HOST"
grep -Fq 'upload-fragment' "$HOST"
grep -Fq 'saveCredential' "$HOST"
test -s "$SETTINGS"
echo "source regression checks passed"
