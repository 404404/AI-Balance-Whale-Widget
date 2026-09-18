#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE="${1:-source}"
CONTRACT="$ROOT/MacOSApp/acceptance/required-tests.json"
REPORT="$ROOT/MacOSApp/scripts/acceptance_report.py"
# These classes exercise native/WebKit production paths against the built bundle.
UI_FILTER='WidgetWebViewTests|BrowserAuthAcceptanceTests|BubbleNativeAcceptanceTests|BubbleBindingAcceptanceTests|BubbleEditorAcceptanceTests|BubbleLayoutAcceptanceTests'

test -s "$CONTRACT"
command -v jq >/dev/null
jq -e '.requiredCheck == "acceptance-gate" and (.source | length > 0) and (.auth | length > 0) and (.packaged | length > 0)' "$CONTRACT" >/dev/null
FIXTURE="$ROOT/MacOSApp/acceptance/upstream-bubble-defaults.json"
test -s "$FIXTURE"
jq -e 'length == 2 and .[0].kind == "custom" and .[1].kind == "choice" and .[1].options[0].w == 10 and .[1].options[1].w == 1 and (.[1].options[0].item.modules[0].lines | length) == 48' "$FIXTURE" >/dev/null

run_xctest() {
  local log_path="$1"
  local xml_path="$2"
  shift 2
  local test_status=0 report_status=0
  # Never let an earlier invocation's report stand in for this run.
  rm -f "$xml_path"
  swift test "$@" 2>&1 | tee "$log_path" || test_status=$?
  python3 "$REPORT" convert --log "$log_path" --xml "$xml_path" \
    --contract "$CONTRACT" --phase "$MODE" || report_status=$?
  if [[ "$test_status" -ne 0 ]]; then return "$test_status"; fi
  return "$report_status"
}

case "$MODE" in
  source)
    RESULTS="${WHALE_ACCEPTANCE_RESULTS:-${RUNNER_TEMP:-/tmp}/ai-balance-whale-acceptance}"
    mkdir -p "$RESULTS"
    python3 -m unittest discover -s "$ROOT/MacOSApp/acceptance" \
      -p 'test_acceptance_report.py' -v 2>&1 | tee "$RESULTS/gate-parser.log"
    bash "$ROOT/MacOSApp/scripts/verify-source.sh" 2>&1 | tee "$RESULTS/source-static.log"
    run_xctest "$RESULTS/source.log" "$RESULTS/source.xml" --package-path "$ROOT/MacOSApp" --skip "$UI_FILTER"
    ;;
  packaged)
    : "${WHALE_WIDGET_RESOURCE_ROOT:?WHALE_WIDGET_RESOURCE_ROOT must point to this build Resources}"
    test -f "$WHALE_WIDGET_RESOURCE_ROOT/WhaleWidget.html"
    test -f "$WHALE_WIDGET_RESOURCE_ROOT/Settings.html"
    test -f "$WHALE_WIDGET_RESOURCE_ROOT/upstream-bubble-defaults.json"
    RESULTS="${WHALE_ACCEPTANCE_RESULTS:-${RUNNER_TEMP:-/tmp}/ai-balance-whale-acceptance}"
    mkdir -p "$RESULTS"
    run_xctest "$RESULTS/packaged.log" "$RESULTS/packaged.xml" --package-path "$ROOT/MacOSApp" --filter "$UI_FILTER"
    ;;
  *)
    echo "usage: $0 source|packaged" >&2
    exit 2
    ;;
esac
echo "acceptance-gate $MODE passed"
