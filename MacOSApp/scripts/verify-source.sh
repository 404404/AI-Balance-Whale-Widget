#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HTML="$ROOT/MacOSApp/Resources/WhaleWidget.html"
ASSET="$ROOT/assets/whale-widget.js"
SETTINGS="$ROOT/MacOSApp/Resources/Settings.html"
MENU="$ROOT/MacOSApp/Resources/NativeContextMenu.html"
WINDOW="$ROOT/MacOSApp/Sources/AIBalanceWhale/WhaleWindowController.swift"
STORE="$ROOT/MacOSApp/Sources/AIBalanceWhale/WhaleConfigurationStore.swift"
HOST="$ROOT/MacOSApp/Sources/AIBalanceWhale/WhaleHostAdapter.swift"
CODEX="$ROOT/MacOSApp/Sources/AIBalanceWhale/CodexAppServerClient.swift"
HTTP="$ROOT/MacOSApp/Sources/AIBalanceWhale/CodexHTTPUsageClient.swift"
COORD="$ROOT/MacOSApp/Sources/AIBalanceWhale/QuotaRefreshCoordinator.swift"
CATALOG="$ROOT/MacOSApp/Sources/CodexCore/AccountCatalog.swift"

for pattern in "__AIWhaleStandalone" "__AIWhaleHostResponse" "navigationToken" "bubbleLayout" "whale-widget.js"; do
  grep -Fq "$pattern" "$HTML" || { echo "missing standalone WhaleWidget pattern: $pattern" >&2; exit 1; }
done
for pattern in "contextmenu" "pointerup" "pointercancel" "dshwv-bshape" "dshwv-b1" "dshwv-b2" "BUBBLE_DEFAULT_ITEMS" "bubblePickLine" "bubblePlanWinOptions" "__AIWhaleStandalone" "dshwv-menu-btn-pinned" "renderNowdexModule" "stepsToBubbleCfg"; do
  grep -Fq "$pattern" "$ASSET" || { echo "missing upstream asset pattern: $pattern" >&2; exit 1; }
done
for pattern in 'data-page="general"' 'data-page="accounts"' 'data-page="bubbles"' 'data-page="appearance"' 'data-page="sounds"' 'data-page="alerts"' 'data-page="about"' 'messageHandlers.settings' 'saveCredential' 'Keychain' 'Application Support' '账户与额度' '气泡内容'; do
  grep -Fq "$pattern" "$SETTINGS" || { echo "missing settings pattern: $pattern" >&2; exit 1; }
done
if grep -Fq '<iframe' "$SETTINGS"; then
  echo "settings must not use an iframe" >&2
  exit 1
fi
grep -Fq '__AIWhaleEditorMode' "$SETTINGS"
grep -Fq 'upstreamEditorMount' "$SETTINGS"
grep -Fq 'openBubbleEditor' "$SETTINGS"
if grep -Fq 'data-page="models"' "$SETTINGS" || grep -Fq 'data-page="resources"' "$SETTINGS"; then
  echo "settings must not keep the unopenable models/resources pages" >&2
  exit 1
fi
for pattern in "刷新额度" "编辑气泡" "data-action=\"settingsAccounts\"" "data-action=\"settings\""; do
  grep -Fq "$pattern" "$MENU" || { echo "missing native menu pattern: $pattern" >&2; exit 1; }
done
grep -Fq 'WhaleLayout.contentSize' "$WINDOW"
grep -Fq 'saved.width - newSize.width' "$WINDOW"
grep -Fq 'frame.origin.y = saved.minY' "$WINDOW"
grep -Fq 'frame.origin.y = old.minY' "$WINDOW"
grep -Fq 'resourceDataURL' "$WINDOW"
grep -Fq 'showMenuButton' "$WINDOW"
grep -Fq 'isMenuButtonPoint' "$WINDOW"
grep -Fq 'schemaVersion' "$STORE"
grep -Fq 'builtin-dsniang' "$STORE"
grep -Fq 'accounts' "$STORE"
grep -Fq 'showMenuButton' "$STORE"
grep -Fq 'account/rateLimits/read' "$CODEX"
grep -Fq 'chatgpt.com/backend-api/wham/usage' "$HTTP"
grep -Fq 'CodexAppServerClient' "$COORD"
grep -Fq 'CodexHTTPUsageClient' "$COORD"
grep -Fq 'kind: "subscription"' "$CATALOG"
grep -Fq 'dashboard' "$CATALOG"
grep -Fq 'shouldLiveFetch' "$CATALOG"
grep -Fq 'bubbleRevision' "$CATALOG"
grep -Fq 'tapAdvance' "$HOST"
grep -Fq 'native __AIWhale.update is the source of truth' "$ASSET"
grep -Fq 'Codex 登录由官方 CLI' "$SETTINGS"
grep -Fq '不要求粘贴 session、Cookie 或 token' "$SETTINGS"
grep -Fq 'publicAccounts' "$HOST"
grep -Fq 'saveCredential' "$HOST"
test -s "$SETTINGS"
test -s "$MENU"
echo "source regression checks passed"
