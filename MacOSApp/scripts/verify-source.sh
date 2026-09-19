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
HTTP="$ROOT/MacOSApp/Sources/AIBalanceWhale/CodexHTTPUsageClient.swift"
COORD="$ROOT/MacOSApp/Sources/AIBalanceWhale/QuotaRefreshCoordinator.swift"
OAUTH="$ROOT/MacOSApp/Sources/AIBalanceWhale/CodexOAuthCoordinator.swift"
GROKOAUTH="$ROOT/MacOSApp/Sources/AIBalanceWhale/GrokOAuthCoordinator.swift"
CURSOROAUTH="$ROOT/MacOSApp/Sources/AIBalanceWhale/CursorOAuthCoordinator.swift"
KEYCHAIN="$ROOT/MacOSApp/Sources/AIBalanceWhale/CodexCredentialStore.swift"
COREOAUTH="$ROOT/MacOSApp/Sources/CodexCore/CodexOAuthSupport.swift"
GROKCORE="$ROOT/MacOSApp/Sources/CodexCore/GrokOAuthSupport.swift"
CURSORCORE="$ROOT/MacOSApp/Sources/CodexCore/CursorOAuthSupport.swift"
CATALOG="$ROOT/MacOSApp/Sources/CodexCore/AccountCatalog.swift"

for pattern in "__AIWhaleStandalone" "__AIWhaleHostResponse" "navigationToken" "bubbleLayout" "whale-widget.js"; do
  grep -Fq "$pattern" "$HTML" || { echo "missing standalone WhaleWidget pattern: $pattern" >&2; exit 1; }
done
for pattern in "contextmenu" "pointerup" "pointercancel" "dshwv-bshape" "dshwv-b1" "dshwv-b2" "BUBBLE_DEFAULT_ITEMS" "bubblePickLine" "bubbleReshowCurrent" "standaloneMetricText" "showEditorOverlay" "__AIWhaleStandalone" "dshwv-menu-btn-pinned" "stepsToBubbleCfg" "Codex 5小时" "Grok Bot" "Cursor Auto" "whaleWindowOf"; do
  grep -Fq "$pattern" "$ASSET" || { echo "missing upstream asset pattern: $pattern" >&2; exit 1; }
done
for pattern in 'data-page="general"' 'data-page="accounts"' 'data-page="bubbles"' 'data-page="appearance"' 'data-page="sounds"' 'data-page="alerts"' 'data-page="about"' 'messageHandlers.settings' 'saveCredential' 'Keychain' 'Application Support' '账户与额度' '气泡内容' 'loginCodex' 'refreshCodex' 'disconnectCodex' 'loginGrok' 'loginCursor' 'disconnectGrok' 'disconnectCursor'; do
  grep -Fq "$pattern" "$SETTINGS" || { echo "missing settings pattern: $pattern" >&2; exit 1; }
done
if grep -Fq '<iframe' "$SETTINGS"; then echo "settings must not use an iframe" >&2; exit 1; fi
if grep -Eq 'codexPath|codexHome|Codex CLI|app-server|sessionToken|WorkosCursorSessionToken|粘贴 grok' "$SETTINGS"; then
  echo "settings expose a forbidden CLI or pasted-auth field" >&2
  exit 1
fi
grep -Fq '__AIWhaleEditorMode' "$SETTINGS"
grep -Fq 'upstreamEditorMount' "$SETTINGS"
grep -Fq 'openBubbleEditor' "$SETTINGS"
for pattern in "刷新额度" "编辑气泡" 'data-action="settingsAccounts"' 'data-action="settings"'; do
  grep -Fq "$pattern" "$MENU" || { echo "missing native menu pattern: $pattern" >&2; exit 1; }
done
for pattern in 'WhaleLayout.contentSize' 'frame.origin.y = saved.minY' 'frame.origin.y = old.minY' 'resourceDataURL' 'showMenuButton' 'isMenuButtonPoint'; do
  grep -Fq "$pattern" "$WINDOW" || { echo "missing native layout pattern: $pattern" >&2; exit 1; }
done
for pattern in 'schemaVersion' 'builtin-dsniang' 'accounts' 'showMenuButton'; do grep -Fq "$pattern" "$STORE" || exit 1; done
for pattern in 'auth.openai.com' 'code_challenge_method' 'state' 'redirectURI'; do grep -Fq "$pattern" "$COREOAUTH" || { echo "missing OAuth core pattern: $pattern" >&2; exit 1; }; done
for pattern in 'auth.x.ai' '56121' 'code_challenge_method' 'Access-Control-Allow-Private-Network' 'referrer'; do grep -Fq "$pattern" "$GROKCORE" || { echo "missing Grok OAuth pattern: $pattern" >&2; exit 1; }; done
for pattern in 'loginDeepControl' 'auth/poll' 'redirectTarget'; do grep -Fq "$pattern" "$CURSORCORE" || { echo "missing Cursor OAuth pattern: $pattern" >&2; exit 1; }; done
test -s "$GROKOAUTH"
test -s "$CURSOROAUTH"
grep -Fq 'SubscriptionCredentialStore' "$GROKOAUTH"
grep -Fq 'SubscriptionCredentialStore' "$CURSOROAUTH"
for pattern in 'CodexCredentialStore' 'SecItem' 'app-keychain'; do grep -Fq "$pattern" "$KEYCHAIN" || exit 1; done
for pattern in 'chatgpt.com/backend-api/wham/usage' 'CodexCredentialStore' 'NoRedirectDelegate'; do grep -Fq "$pattern" "$HTTP" || exit 1; done
for pattern in 'CodexHTTPUsageClient' 'CodexCredentialStore' 'SubscriptionCredentialStore' 'requestID' 'generation'; do grep -Fq "$pattern" "$COORD" || exit 1; done
if grep -R -n -E 'CodexAppServerClient|CodexLoginCoordinator|CodexLocator|codexPath|codexHome|account/rateLimits/read|app-server' "$ROOT/MacOSApp/Sources" --include='*.swift'; then
  echo "deprecated CLI/app-server runtime path remains in production sources" >&2
  exit 1
fi
grep -Fq 'kind: "subscription"' "$CATALOG"
grep -Fq 'dashboard' "$CATALOG"
grep -Fq 'shouldLiveFetch' "$CATALOG"
grep -Fq 'bubbleRevision' "$CATALOG"
grep -Fq 'GetSandUsageStatus' "$ROOT/MacOSApp/Sources/AIBalanceWhale/ExternalProviderClient.swift" || { echo "missing Cursor Grok Bot sand usage fetch" >&2; exit 1; }
grep -Fq 'demoBubbleItems' "$WINDOW" || { echo "missing demo bubble payload" >&2; exit 1; }
grep -Fq 'defaultBubbleItems' "$CATALOG" || { echo "missing demo bubble items" >&2; exit 1; }
grep -Fq 'tapAdvance' "$HOST"
grep -Fq 'publicAccounts' "$HOST"
grep -Fq 'saveCredential' "$HOST"
test -s "$SETTINGS"
test -s "$MENU"
echo "source regression checks passed"
