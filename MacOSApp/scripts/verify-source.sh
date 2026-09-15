#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HTML="$ROOT/MacOSApp/Resources/WhaleWidget.html"
SETTINGS="$ROOT/MacOSApp/Resources/Settings.html"
WINDOW="$ROOT/MacOSApp/Sources/AIBalanceWhale/WhaleWindowController.swift"
STORE="$ROOT/MacOSApp/Sources/AIBalanceWhale/WhaleConfigurationStore.swift"

for pattern in 'contextmenu' 'pointerup' 'pointercancel' 'dragEnd' 'setLayout' 'overflow: hidden'; do
  rg -q "$pattern" "$HTML"
done
for pattern in 'data-page="general"' 'data-page="models"' 'data-page="resources"' 'data-page="bubbles"' 'data-page="sounds"' 'data-page="reminders"' 'data-page="about"' 'messageHandlers.settings' 'saveCredential' 'importResource'; do
  rg -q "$pattern" "$SETTINGS"
done
rg -q 'WhaleLayout.contentSize' "$WINDOW"
rg -q 'saved.width - newSize.width' "$WINDOW"
rg -q 'resourceDataURL' "$WINDOW"
rg -q 'Application Support' "$SETTINGS"
rg -q 'Keychain' "$SETTINGS"
rg -q 'schemaVersion' "$STORE"
rg -q 'builtin-dsniang' "$STORE"
test -s "$SETTINGS"
echo "source regression checks passed"
