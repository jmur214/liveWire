#!/usr/bin/env bash
# Server-side acceptance pass (DESIGN.md B5) against replay mode, from a clean data dir.
#
#   bash tests/acceptance.sh            # ~2 min; needs the server deps installed and ffmpeg
#   PORT=8010 bash tests/acceptance.sh  # use another port if 8000 is busy
#
# Starts the API, an APNs stub and a transcription stub, registers an alert
# device, replays tests/fixtures/lincoln_day.json at 200x while reading
# /api/stream, then runs every check script. Prints PASS/FAIL per item.
set -u
cd "$(dirname "$0")/.."

PORT="${PORT:-8000}"
export API_TOKEN="${API_TOKEN:-dev-token}"
export DATA_DIR="$(mktemp -d)"
export APNS_URL_OVERRIDE="http://127.0.0.1:8098" APNS_BUNDLE_ID="com.test.livewire"
export GROQ_URL="http://127.0.0.1:8099/v1/audio/transcriptions" GROQ_API_KEY="test" TRANSCRIBER="groq"
export ANTHROPIC_API_KEY=""
BASE="http://127.0.0.1:${PORT}"
LOG="$DATA_DIR/logs"; mkdir -p "$LOG"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

results=()
pass() { results+=("PASS  $1"); echo "PASS  $1"; }
fail() { results+=("FAIL  $1"); echo "FAIL  $1"; }
run() { # run <label> <command...>
  local label="$1"; shift
  if "$@" > "$LOG/$(echo "$label" | tr ' /' '__').log" 2>&1; then pass "$label"; else fail "$label  (see $LOG)"; fi
}
wait_for() { for _ in $(seq 1 60); do curl -fs -o /dev/null -H "Authorization: Bearer $API_TOKEN" "$1" && return 0; sleep 0.25; done; return 1; }

echo "data dir: $DATA_DIR"
uvicorn server:app --host 127.0.0.1 --port "$PORT" > "$LOG/api.log" 2>&1 & PIDS+=($!)
python3 tests/stub_apns.py 8098 > "$LOG/apns.log" 2>&1 & PIDS+=($!)
python3 tests/stub_transcriber.py 8099 > "$LOG/transcriber.log" 2>&1 & PIDS+=($!)
wait_for "$BASE/api/health" || { fail "API server start"; printf '%s\n' "${results[@]}"; exit 1; }
wait_for "http://127.0.0.1:8098/sent" && wait_for "http://127.0.0.1:8099/seen" || fail "stub servers start"

# Alert device: structure fire / shooting anywhere, plus a place next to 13th & South.
curl -fs -X POST "$BASE/api/device" -H "Authorization: Bearer $API_TOKEN" -H 'Content-Type: application/json' -d '{
  "token": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "city": "lincoln", "sandbox": true,
  "rules": {"enabled": true, "types": ["structure fire", "shooting"],
            "places": [{"name": "Home", "lat": 40.7960, "lon": -96.7100, "radius_mi": 0.5, "enabled": true}],
            "near_me": {"enabled": false, "radius_mi": 0.5},
            "quiet": {"enabled": false, "start": "23:00", "end": "07:00", "allow": []}}}' > /dev/null \
  && pass "POST /api/device stores rules" || fail "POST /api/device stores rules"

# Replay at 200x (~27 s) with the SSE checker reading concurrently for 36 s.
python3 main.py --replay tests/fixtures/lincoln_day.json --speed 200 > "$LOG/replay.log" 2>&1 & REPLAY=$!
run "/api/stream delivers transmission+incident events <1 s, pings every 15 s (curl -N)" python3 tests/check_stream.py "$BASE" 36
wait "$REPLAY" && pass "replay --speed 200 runs to completion with no exceptions" || fail "replay --speed 200 exited non-zero"
grep -qiE "traceback|error" "$LOG/replay.log" && fail "replay log has errors" || pass "replay log free of errors/tracebacks"

run "B3 endpoints: auth 401, health, cities, incidents (8-10, grouping, units, cleared), transmissions, audio, report" python3 tests/check_api.py "$BASE"

# Push: structure fire (type), shooting (type) and gas leak (place) → 3 pushes, one per incident.
PUSHES=$(curl -fs http://127.0.0.1:8098/sent | python3 -c 'import json,sys; s=json.load(sys.stdin)["sent"]; print(len(s), sorted(set(x["payload"]["incident_id"] for x in s)))')
[[ "$PUSHES" == "3 [1, 6, 10]" ]] && pass "alerts: replayed structure fire/shooting/place produce one push each ($PUSHES)" || fail "alerts: expected 3 pushes for incidents [1, 6, 10], got $PUSHES"
curl -fs http://127.0.0.1:8098/sent | python3 -c '
import json, sys
s = json.load(sys.stdin)["sent"]
p = next(x["payload"] for x in s if x["payload"]["incident_id"] == 1)
assert p["aps"]["alert"]["title"].startswith("Structure fire"), p
assert p["aps"]["alert"]["body"].startswith("1621 N 33rd St") and p["aps"]["sound"] == "default" and p["aps"]["thread-id"] == "lincoln", p
h = next(x["headers"] for x in s)
assert h.get("apns-push-type") == "alert" and h.get("apns-topic") == "com.test.livewire" and h.get("apns-priority") == "10", h
' && pass "push payload has aps.alert title/body, sound, thread-id, incident_id + APNs headers" || fail "push payload shape"

run "unit tests: grouping helpers, type vocabulary, haversine" python3 tests/test_units.py
run "unit tests: push rules, quiet hours, payload" python3 tests/test_push_rules.py

# Live pipeline on a synthetic WAV through the transcription stub (ffmpeg -> energy gate -> transcribe -> store).
BEFORE=$(curl -fs -H "Authorization: Bearer $API_TOKEN" "$BASE/api/transmissions?limit=1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["latest_id"])')
run "live pipeline: --source synthetic WAV -> 4 transmissions via Groq-shaped stub" python3 main.py --source tests/fixtures/audio/synthetic_dispatch.wav
AFTER=$(curl -fs -H "Authorization: Bearer $API_TOKEN" "$BASE/api/transmissions?since_id=$BEFORE" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["transmissions"]))')
[[ "$AFTER" == "4" ]] && pass "live pipeline stored 4 transcribed transmissions" || fail "live pipeline stored $AFTER transmissions (expected 4)"

# run_samples without a key must still run (extraction is skipped -> exit 1 is expected).
python3 tests/run_samples.py --no-geocode > "$LOG/run_samples.log" 2>&1; rc=$?
grep -q "passed; police delay estimate" "$LOG/run_samples.log" && pass "tests/run_samples.py runs (needs ANTHROPIC_API_KEY to pass; exit $rc without it)" || fail "tests/run_samples.py crashed"

echo; echo "==== results ===="; printf '%s\n' "${results[@]}"
echo "logs: $LOG"
grep -q '^FAIL' <<< "$(printf '%s\n' "${results[@]}")" && exit 1 || exit 0
