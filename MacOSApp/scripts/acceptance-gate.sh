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

make_junit_from_xctest_log() {
  python3 - "$1" "$2" <<'PY'
import re
import sys
import xml.etree.ElementTree as ET

log_path, xml_path = sys.argv[1:]
pattern = re.compile(r"Test Case '-\[(.*?) (.*?)\]' (passed|failed) \(([0-9.]+) seconds\)")
cases = []
with open(log_path, encoding='utf-8', errors='replace') as handle:
    for line in handle:
        match = pattern.search(line)
        if match:
            cases.append(match.groups())
if not cases:
    raise SystemExit(f'XCTest log has no test cases: {log_path}')
suite = ET.Element('testsuite', {'name': 'AI-Balance-Whale acceptance', 'tests': str(len(cases))})
failures = 0
for name, method, result, seconds in cases:
    case = ET.SubElement(suite, 'testcase', {'classname': name, 'name': method, 'time': seconds})
    if result == 'failed':
        failures += 1
        ET.SubElement(case, 'failure', {'message': 'XCTest reported failure'})
suite.set('failures', str(failures))
suite.set('skipped', '0')
ET.ElementTree(suite).write(xml_path, encoding='utf-8', xml_declaration=True)
print(f'JUnit {xml_path}: {len(cases)} testcases, {failures} failures')
PY
}

run_xctest() {
  local log_path="$1"
  local xml_path="$2"
  shift 2
  set +e
  swift test "$@" 2>&1 | tee "$log_path"
  local status="${PIPESTATUS[0]}"
  set -e
  make_junit_from_xctest_log "$log_path" "$xml_path"
  return "$status"
}

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
    run_xctest "$RESULTS/source.log" "$RESULTS/source.xml" --package-path "$ROOT/MacOSApp" --skip WidgetWebViewTests
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
    run_xctest "$RESULTS/packaged.log" "$RESULTS/packaged.xml" --package-path "$ROOT/MacOSApp" --filter WidgetWebViewTests
    test -s "$RESULTS/packaged.xml"
    check_junit "$RESULTS/packaged.xml"
    ;;
  *)
    echo "usage: $0 source|packaged" >&2
    exit 2
    ;;
esac
echo "acceptance-gate $MODE passed"
