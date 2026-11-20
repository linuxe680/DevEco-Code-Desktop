#!/bin/bash
# End-to-end smoke test against a real deveco server.
#
# Starts an isolated `deveco serve` (throwaway data directory, no user data
# touched), accepts the product agreement, creates a session, sends a prompt,
# waits for the SSE `session.idle`, verifies the assistant reply, deletes the
# session, and shuts down. Exits 0 on success, 1 with a FAIL line otherwise.
#
# Usage:
#   Scripts/smoke-test.sh                      # auto-detect deveco binary
#   DEVECO_BIN=/path/to/deveco Scripts/smoke-test.sh
#   SMOKE_PORT=4800 Scripts/smoke-test.sh      # default 4700

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${DEVECO_BIN:-$HOME/.npm-global/bin/deveco}"
PORT="${SMOKE_PORT:-4700}"
BASE="http://127.0.0.1:$PORT"
WORK="$(mktemp -d /tmp/deveco-smoke.XXXXXX)"
LOG="$WORK/serve.log"
IDLE_FILE="$WORK/idle.json"
SERVER_PID=""
SESSION_ID=""

cleanup() {
    [ -n "$SESSION_ID" ] && curl -sf -X DELETE "$BASE/session/$SESSION_ID" >/dev/null 2>&1
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null && wait "$SERVER_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "PASS: $*"; }

# --- 1. binary -------------------------------------------------------------
[ -x "$BIN" ] || fail "deveco binary not found at '$BIN' (set DEVECO_BIN)"
pass "deveco binary: $BIN"

# --- 2. start server with a throwaway data directory -----------------------
export XDG_DATA_HOME="$WORK/data"
mkdir -p "$XDG_DATA_HOME"
"$BIN" serve --port "$PORT" --hostname 127.0.0.1 >"$LOG" 2>&1 &
SERVER_PID=$!

# --- 3. wait for health ----------------------------------------------------
healthy=0
for _ in $(seq 1 80); do
    if curl -sf "$BASE/global/health" >/dev/null 2>&1; then healthy=1; break; fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        fail "server exited during boot; log tail:
$(tail -8 "$LOG")"
    fi
    sleep 0.5
done
[ "$healthy" = 1 ] || fail "server did not become healthy in 40s; log tail:
$(tail -8 "$LOG")"
pass "server healthy at $BASE (pid $SERVER_PID, data: $XDG_DATA_HOME)"

# --- 4. accept the product agreement (fresh data dir starts unaccepted) ----
if "$BIN" auth consent --accept >/dev/null 2>&1; then
    pass "product agreement accepted"
else
    echo "WARN: could not run 'auth consent --accept' — prompt may be blocked"
fi

# --- 5. send without an explicit model -------------------------------------
# Deliberately no "model" field: the throwaway data directory has no user
# provider config, so the server default resolves to an opencode built-in
# free model. (Passing {"providerID":"opencode","modelID":"tidepool-alpha-free"}
# explicitly is rejected by deveco 0.3.0 with "Model not found" — probed and
# confirmed 2026-11-20; the desktop app passes user-configured magpie models
# with this shape, which does work.)
MODEL_PAYLOAD='{"parts":[{"type":"text","text":"Reply with exactly: SMOKE_OK"}]}'

# --- 6. create a session ---------------------------------------------------
session_json=$(curl -sf -X POST "$BASE/session" -H 'Content-Type: application/json' \
    -d '{"title":"Smoke Test"}') || fail "POST /session failed"
SESSION_ID=$(echo "$session_json" | jq -r '.id')
[ -n "$SESSION_ID" ] && [ "$SESSION_ID" != "null" ] || fail "no session id in response: $session_json"
pass "session created: $SESSION_ID"

# --- 7. watch SSE for session.idle before sending --------------------------
curl -sfN "$BASE/event" | sed -u 's/^data: //' \
    | jq --unbuffered -r "select(.properties.sessionID==\"$SESSION_ID\") | select(.type==\"session.idle\" or .type==\"session.error\")" \
    > "$IDLE_FILE" &
SSE_PID=$!

# --- 8. send the prompt ----------------------------------------------------
curl -sf -X POST "$BASE/session/$SESSION_ID/prompt_async" \
    -H 'Content-Type: application/json' -d "$MODEL_PAYLOAD" \
    >/dev/null || fail "prompt_async failed"
pass "prompt sent"

# --- 9. wait for idle (2 min cap: a real model call) -----------------------
idle=0
for _ in $(seq 1 240); do
    if [ -s "$IDLE_FILE" ]; then idle=1; break; fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        fail "server died while generating; log tail:
$(tail -8 "$LOG")"
    fi
    sleep 0.5
done
kill "$SSE_PID" 2>/dev/null
[ "$idle" = 1 ] || fail "no session.idle event within 120s (model unreachable or very slow?)"
if grep -q '"session.error"' "$IDLE_FILE" 2>/dev/null; then
    err=$(echo "$IDLE_FILE" | xargs cat | jq -r '.properties.error.data.message // .properties.error | tostring' 2>/dev/null | head -1)
    fail "session.error during generation: ${err:-unknown}"
fi
pass "session.idle received"

# --- 10. verify the assistant reply ----------------------------------------
reply=$(curl -sf "$BASE/session/$SESSION_ID/message") || fail "GET message failed"
assistant_count=$(echo "$reply" | jq '[.[] | select(.info.role=="assistant")] | length' 2>/dev/null)
[ "${assistant_count:-0}" -ge 1 ] || fail "no assistant message found in transcript (raw: $(echo "$reply" | head -c 400))"
pass "assistant reply present ($assistant_count message(s))"

# --- 11. delete the session ------------------------------------------------
curl -sf -X DELETE "$BASE/session/$SESSION_ID" >/dev/null || fail "DELETE session failed"
pass "session deleted"

echo
echo "SMOKE TEST PASSED ($(date '+%H:%M:%S'))"
