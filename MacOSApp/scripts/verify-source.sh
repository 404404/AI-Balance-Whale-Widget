#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HTML="$ROOT/MacOSApp/Resources/WhaleWidget.html"
SETTINGS="$ROOT/MacOSApp/Resources/Settings.html"
WINDOW="$ROOT/MacOSApp/Sources/AIBalanceWhale/WhaleWindowController.swift"
STORE="$ROOT/MacOSApp/Sources/AIBalanceWhale/WhaleConfigurationStore.swift"

for pattern in 'contextmenu' 'pointerup' 'pointercancel' 'dragEnd' 'setLayout' 'overflow: hidden' 'navigationToken' 'bubbleLayout' 'dshwv-bshape' 'dshwv-b1' 'dshwv-b2'; do
  grep -Fq "$pattern" "$HTML" || { echo "missing WhaleWidget pattern: $pattern" >&2; exit 1; }
done
for pattern in 'data-page="general"' 'data-page="models"' 'data-page="resources"' 'data-page="bubbles"' 'data-page="sounds"' 'data-page="reminders"' 'data-page="about"' 'messageHandlers.settings' 'saveCredential' 'importResource'; do
  grep -Fq "$pattern" "$SETTINGS"
done
grep -Fq 'WhaleLayout.contentSize' "$WINDOW"
grep -Fq 'saved.width - newSize.width' "$WINDOW"
grep -Fq 'resourceDataURL' "$WINDOW"
grep -Fq 'Application Support' "$SETTINGS"
grep -Fq 'Keychain' "$SETTINGS"
grep -Fq 'schemaVersion' "$STORE"
grep -Fq 'builtin-dsniang' "$STORE"
test -s "$SETTINGS"
echo "source regression checks passed"
