#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE="${1:-source}"
CONTRACT="$ROOT/MacOSApp/acceptance/required-tests.json"

test -s "$CONTRACT"
command -v jq >/dev/null
jq -e '.requiredCheck == "acceptance-gate" and (.source | length > 0) and (.auth | length > 0) and (.packaged | length > 0)' "$CONTRACT" >/dev/null
FIXTURE="$ROOT/MacOSApp/acceptance/upstream-bubble-defaults.json"
test -s "$FIXTURE"
jq -e 'length == 2 and .[0].kind == "custom" and .[1].kind == "choice" and .[1].options[0].w == 10 and .[1].options[1].w == 1 and (.[1].options[0].item.modules[0].lines | length) == 48' "$FIXTURE" >/dev/null

check_junit() {
  python3 - "$1" <<'PY'
import sys
import xml.etree.ElementTree as ET
path = sys.argv[1]
root = ET.parse(path).getroot()
cases = root.findall('.//testcase')
if not cases:
    raise SystemExit(f'JUnit report has no testcases: {path}')
skipped = [c for c in cases if c.find('skipped') is not None]
if skipped:
    raise SystemExit(f'JUnit report contains skipped tests: {path}')
print(f'JUnit {path}: {len(cases)} testcases')
PY
}

case "$MODE" in
  source)
    bash "$ROOT/MacOSApp/scripts/verify-source.sh"
    RESULTS="${WHALE_ACCEPTANCE_RESULTS:-${RUNNER_TEMP:-/tmp}/ai-balance-whale-acceptance}"
    mkdir -p "$RESULTS"
    swift test --package-path "$ROOT/MacOSApp" --skip WidgetWebViewTests --xunit-output "$RESULTS/source.xml"
    test -s "$RESULTS/source.xml"
    check_junit "$RESULTS/source.xml"
    ;;
  packaged)
    : "${WHALE_WIDGET_RESOURCE_ROOT:?WHALE_WIDGET_RESOURCE_ROOT must point to this build Resources}"
    test -f "$WHALE_WIDGET_RESOURCE_ROOT/WhaleWidget.html"
    test -f "$WHALE_WIDGET_RESOURCE_ROOT/Settings.html"
    test -f "$WHALE_WIDGET_RESOURCE_ROOT/upstream-bubble-defaults.json"
    RESULTS="${WHALE_ACCEPTANCE_RESULTS:-${RUNNER_TEMP:-/tmp}/ai-balance-whale-acceptance}"
    mkdir -p "$RESULTS"
    swift test --package-path "$ROOT/MacOSApp" --filter WidgetWebViewTests --xunit-output "$RESULTS/packaged.xml"
    test -s "$RESULTS/packaged.xml"
    check_junit "$RESULTS/packaged.xml"
    ;;
  *)
    echo "usage: $0 source|packaged" >&2
    exit 2
    ;;
esac
echo "acceptance-gate $MODE passed"
