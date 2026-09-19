#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/AI Balance Whale.app}"
OUT="${2:-$ROOT/qa-output/mac-smoke}"
[[ -d "$APP" ]] || { echo "App bundle missing: $APP" >&2; exit 1; }
rm -rf "$OUT"
mkdir -p "$OUT"
DATA="$OUT/data"
mkdir -p "$DATA"
LOG="$OUT/app.log"
WHALE_HOME="$DATA" "$APP/Contents/MacOS/AI Balance Whale" --standalone --whale-data="$DATA" >"$LOG" 2>&1 &
PID=$!
cleanup() { kill -TERM "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; }
trap cleanup EXIT
for _ in $(seq 1 60); do
  [[ -f "$DATA/startup-timings.json" ]] && break
  if ! kill -0 "$PID" 2>/dev/null; then cat "$LOG"; exit 1; fi
  sleep 1
done
[[ -f "$DATA/startup-timings.json" ]] || { cat "$LOG"; echo 'renderer did not become interactive' >&2; exit 1; }
python3 - "$DATA/startup-timings.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
for key in ('appReady','dispatcherReady','windowCreated','pageLoaded','imageAndInputReady','interactive'):
    if key not in p.get('phases', {}): raise SystemExit(f'missing startup phase: {key}')
PY
[[ ! -f "$DATA/desktop-error.json" ]] || { cat "$DATA/desktop-error.json"; exit 1; }
printf 'packaged Electron standalone smoke passed for pid %s\n' "$PID"
