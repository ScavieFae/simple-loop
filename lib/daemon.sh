#!/bin/bash
# Simple Loop Daemon — heartbeat loop for autonomous agent work
#
# Usage: bash lib/daemon.sh <project_dir> [heartbeat_seconds]
#
# Architecture:
#   Each tick: assess state → run conductor or worker → push → sleep.
#   Conductor: reads state, decides what to do (evaluate, dispatch, idle).
#   Worker: does ONE task from the active brief, commits, exits.
#   Both run as fresh Claude Code sessions. No long-lived processes.

set -uo pipefail

PROJECT_DIR="${1:?Usage: daemon.sh <project_dir> [heartbeat_seconds]}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
LOOP_DIR="$PROJECT_DIR/.loop"

# Source project config
[ -f "$LOOP_DIR/config.sh" ] && source "$LOOP_DIR/config.sh"

STATE_DIR="$LOOP_DIR/state"
SIGNALS_DIR="$STATE_DIR/signals"
LOG_DIR="$LOOP_DIR/logs"
PID_FILE="$STATE_DIR/daemon.pid"
METRICS_FILE="$STATE_DIR/metrics.jsonl"
RUNNING_FILE="$STATE_DIR/running.json"
CONDUCTOR_PROMPT="$LOOP_DIR/prompts/conductor.md"
WORKER_PROMPT="$LOOP_DIR/prompts/worker.md"

HEARTBEAT_INTERVAL="${2:-${HEARTBEAT_INTERVAL:-300}}"
WORKER_COOLDOWN="${WORKER_COOLDOWN:-30}"
MAX_ITERATIONS="${MAX_ITERATIONS:-20}"
NTFY_TOPIC="${NTFY_TOPIC:-}"
GIT_REMOTE="${GIT_REMOTE:-origin}"
GIT_MAIN_BRANCH="${GIT_MAIN_BRANCH:-main}"

# Tracking
CONSECUTIVE_SKIPS=0
CONSECUTIVE_WORKER_FAILURES=0

# Find lib directory (co-located with this script)
DAEMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ensure directories exist
mkdir -p "$STATE_DIR/signals" "$LOG_DIR"

# Ensure state files exist
[ -f "$RUNNING_FILE" ] || echo '{"active":[],"completed_pending_eval":[],"history":[]}' > "$RUNNING_FILE"

echo ""
echo "╔══════════════════════════════════════╗"
echo "║       Simple Loop Daemon             ║"
echo "╚══════════════════════════════════════╝"
echo ""
echo "  Project:   ${PROJECT_NAME:-$(basename "$PROJECT_DIR")}"
echo "  Directory: $PROJECT_DIR"
echo "  Idle interval: ${HEARTBEAT_INTERVAL}s"
echo "  Worker cooldown: ${WORKER_COOLDOWN}s (max $MAX_ITERATIONS/brief)"
echo "  PID:       $$"
echo ""

# Kill existing daemon
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "  Killing existing daemon (PID $OLD_PID)"
        kill -9 "$OLD_PID" 2>/dev/null
        sleep 1
    fi
fi
echo $$ > "$PID_FILE"

# ╔══════════════════════════════════════════════════════════════════╗
# ║  Helpers                                                        ║
# ╚══════════════════════════════════════════════════════════════════╝

daemon_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_DIR/daemon.log"
}

notify() {
    [ -z "$NTFY_TOPIC" ] && return
    local title="${PROJECT_NAME:-Simple Loop}"
    curl -s \
        -H "Title: $title" \
        -H "Priority: high" \
        -d "$1" \
        "https://ntfy.sh/$NTFY_TOPIC" >/dev/null 2>&1
}

# Parse metrics from Claude JSON output.
# Args: $1=json_file, $2=log_file, $3=source, $4=extra_fields (python dict literal)
parse_metrics() {
    local json_file="$1" log_file="$2" source="$3" extra="$4"
    python3 -c "
import json, sys, datetime
try:
    with open('$json_file') as f:
        data = json.load(f)
    with open('$log_file', 'a') as f:
        f.write(data.get('result', ''))

    def get_tokens(data, *keys):
        for k in keys:
            v = data.get(k, 0)
            if v: return v
        usage = data.get('usage', {})
        if isinstance(usage, dict):
            for k in keys:
                v = usage.get(k, 0)
                if v: return v
        return 0

    entry = {
        'timestamp': datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
        'source': '$source',
        'heartbeat': $TURN,
        'session_id': data.get('session_id', ''),
        'duration_ms': data.get('duration_ms', 0),
        'duration_api_ms': data.get('duration_api_ms', 0),
        'num_turns': data.get('num_turns', 0),
        'cost_usd': data.get('total_cost_usd', 0),
        'input_tokens': get_tokens(data, 'input_tokens', 'inputTokens'),
        'output_tokens': get_tokens(data, 'output_tokens', 'outputTokens'),
        'cache_read_tokens': get_tokens(data, 'cache_read_input_tokens', 'cache_read_tokens', 'cacheReadTokens'),
        'cache_write_tokens': get_tokens(data, 'cache_creation_input_tokens', 'cache_creation_tokens', 'cacheWriteTokens'),
        'is_error': data.get('is_error', False),
    }
    entry.update($extra)
    with open('$METRICS_FILE', 'a') as f:
        f.write(json.dumps(entry) + '\n')
except Exception as e:
    print(f'Metrics parse error: {e}', file=sys.stderr)
    with open('$json_file') as src, open('$log_file', 'a') as dst:
        dst.write(src.read())
" 2>>"$log_file"
}

# Handle rate limit: parse reset time, sleep until then.
handle_rate_limit() {
    local log_file="$1"
    RESET_INFO=$(grep -o "resets [0-9]*[ap]m" "$log_file" 2>/dev/null | head -1)
    if [ -n "$RESET_INFO" ]; then
        RESET_HOUR=$(echo "$RESET_INFO" | grep -o '[0-9]*')
        RESET_AMPM=$(echo "$RESET_INFO" | grep -o '[ap]m')
        if [ "$RESET_AMPM" = "pm" ] && [ "$RESET_HOUR" -ne 12 ]; then
            RESET_HOUR=$((RESET_HOUR + 12))
        elif [ "$RESET_AMPM" = "am" ] && [ "$RESET_HOUR" -eq 12 ]; then
            RESET_HOUR=0
        fi
        NOW_EPOCH=$(date +%s)
        RESET_TODAY=$(date -v${RESET_HOUR}H -v0M -v0S +%s 2>/dev/null || date -d "today ${RESET_HOUR}:00:00" +%s 2>/dev/null)
        if [ -n "$RESET_TODAY" ]; then
            if [ "$RESET_TODAY" -le "$NOW_EPOCH" ]; then
                RESET_TODAY=$((RESET_TODAY + 86400))
            fi
            SLEEP_SECS=$(( RESET_TODAY - NOW_EPOCH + 300 ))
            daemon_log "RATE LIMITED: sleeping $((SLEEP_SECS / 3600))h $(((SLEEP_SECS % 3600) / 60))m until ${RESET_HOUR}:00"
            notify "Rate limited — sleeping until ${RESET_HOUR}:00"
            sleep "$SLEEP_SECS"
            return
        fi
    fi
    daemon_log "RATE LIMITED: couldn't parse reset time. Sleeping 1h."
    sleep 3600
}

# ╔══════════════════════════════════════════════════════════════════╗
# ║  State Assessment                                               ║
# ╚══════════════════════════════════════════════════════════════════╝

assess_state() {
    python3 "$DAEMON_LIB_DIR/assess.py" "$PROJECT_DIR" 2>/dev/null || {
        echo "CONDUCTOR:error"
        echo "NONE"
    }
}

# ╔══════════════════════════════════════════════════════════════════╗
# ║  Conductor Invocation                                           ║
# ╚══════════════════════════════════════════════════════════════════╝

invoke_conductor() {
    local reason="$1"
    daemon_log "CONDUCTOR #$TURN: invoking ($reason)"

    if [ ! -f "$CONDUCTOR_PROMPT" ]; then
        daemon_log "ERROR: conductor prompt not found at $CONDUCTOR_PROMPT"
        return 1
    fi

    local TURN_LOG="$LOG_DIR/conductor_${TURN}_$(date +%Y%m%d_%H%M%S).log"
    local TURN_START=$(date +%s)
    local JSON_TMP=$(mktemp)

    cd "$PROJECT_DIR"

    claude --dangerously-skip-permissions \
        --output-format json \
        -p "$(cat "$CONDUCTOR_PROMPT")

Trigger reason: $reason" \
        > "$JSON_TMP" 2>>"$TURN_LOG"

    local EXIT_CODE=$?

    parse_metrics "$JSON_TMP" "$TURN_LOG" "conductor" "{'reason': '$reason', 'exit_code': $EXIT_CODE}"
    rm -f "$JSON_TMP"

    local TURN_END=$(date +%s)
    local TURN_DURATION=$((TURN_END - TURN_START))

    if [ "$EXIT_CODE" -ne 0 ]; then
        daemon_log "CONDUCTOR #$TURN: FAILED (exit $EXIT_CODE, ${TURN_DURATION}s)"
        notify "Conductor FAILED (exit $EXIT_CODE)"

        if [ "$TURN_DURATION" -le 10 ] && grep -q "out of extra usage" "$TURN_LOG" 2>/dev/null; then
            handle_rate_limit "$TURN_LOG"
            return 1
        fi
    else
        daemon_log "CONDUCTOR #$TURN: complete (${TURN_DURATION}s)"
        # Push after conductor (it may have committed state changes)
        git -C "$PROJECT_DIR" push "$GIT_REMOTE" "$GIT_MAIN_BRANCH" -q 2>/dev/null || true
    fi

    return 0
}

# ╔══════════════════════════════════════════════════════════════════╗
# ║  Worker Iteration                                               ║
# ╚══════════════════════════════════════════════════════════════════╝

run_worker_iteration() {
    local brief_id="$1"
    local branch="$2"

    daemon_log "WORKER: starting iteration for $brief_id on $branch"

    cd "$PROJECT_DIR"

    # Checkout brief branch
    git stash -q 2>/dev/null
    if ! git checkout "$branch" -q 2>/dev/null; then
        if git show-ref --verify --quiet "refs/remotes/${GIT_REMOTE}/$branch" 2>/dev/null; then
            git checkout -b "$branch" "${GIT_REMOTE}/$branch" -q 2>/dev/null || {
                daemon_log "WORKER ERROR: cannot checkout $branch"
                git checkout "$GIT_MAIN_BRANCH" -q 2>/dev/null
                return 1
            }
        else
            daemon_log "WORKER: creating branch $branch from $GIT_MAIN_BRANCH"
            git checkout -b "$branch" "$GIT_MAIN_BRANCH" -q 2>/dev/null || {
                daemon_log "WORKER ERROR: cannot create $branch"
                git checkout "$GIT_MAIN_BRANCH" -q 2>/dev/null
                return 1
            }
        fi
    fi

    git pull --ff-only "$GIT_REMOTE" "$branch" -q 2>/dev/null || true

    # Initialize progress.json if missing
    local PROGRESS_FILE="$LOOP_DIR/state/progress.json"
    if [ ! -f "$PROGRESS_FILE" ]; then
        local brief_file
        brief_file=$(python3 -c "
import json
with open('$RUNNING_FILE') as f:
    rc = json.load(f)
for b in rc.get('active', []):
    if b.get('brief') == '$brief_id':
        print(b.get('brief_file', ''))
        break
" 2>/dev/null)

        if [ -z "$brief_file" ] || [ ! -f "$PROJECT_DIR/$brief_file" ]; then
            daemon_log "WORKER: no brief file found for $brief_id — skipping"
            git checkout "$GIT_MAIN_BRANCH" -q 2>/dev/null
            return 0
        fi

        daemon_log "WORKER: initializing progress.json for $brief_id"
        echo "{\"brief\": \"$brief_id\", \"brief_file\": \"$brief_file\", \"iteration\": 0, \"status\": \"running\", \"tasks_completed\": [], \"tasks_remaining\": [], \"learnings\": []}" > "$PROGRESS_FILE"
        git add "$PROGRESS_FILE"
        git commit -m "Initialize progress for $brief_id" -q 2>/dev/null
    fi

    # Safety: check iteration count
    local iteration
    iteration=$(python3 -c "import json; print(json.load(open('$PROGRESS_FILE')).get('iteration', 0))" 2>/dev/null || echo "0")
    if [ "$iteration" -ge "$MAX_ITERATIONS" ]; then
        daemon_log "WORKER: max iterations ($MAX_ITERATIONS) reached — marking blocked"
        python3 -c "
import json
with open('$PROGRESS_FILE') as f:
    p = json.load(f)
p['status'] = 'blocked'
p['learnings'] = p.get('learnings', []) + ['Daemon: max iterations ($MAX_ITERATIONS) reached.']
with open('$PROGRESS_FILE', 'w') as f:
    json.dump(p, f, indent=2)
"
        git add "$PROGRESS_FILE" && git commit -m "Max iterations reached — marking blocked" -q 2>/dev/null
        git push -u "$GIT_REMOTE" "$branch" 2>&1 || true
        git checkout "$GIT_MAIN_BRANCH" -q 2>/dev/null
        return 0
    fi

    # Read model preference from brief
    local model=""
    local MODEL_FLAG=""
    local brief_file_path
    brief_file_path=$(python3 -c "import json; print(json.load(open('$PROGRESS_FILE')).get('brief_file', ''))" 2>/dev/null)
    if [ -n "$brief_file_path" ] && [ -f "$PROJECT_DIR/$brief_file_path" ]; then
        model=$(grep -m1 '^\*\*Model:\*\*' "$PROJECT_DIR/$brief_file_path" 2>/dev/null | sed 's/.*\*\*Model:\*\*[[:space:]]*//' | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        if [ -n "$model" ] && [ "$model" != "opus" ]; then
            MODEL_FLAG="--model $model"
            daemon_log "WORKER: using model '$model' (from brief)"
        fi
    fi

    # Run one iteration
    local WORKER_LOG="$LOG_DIR/worker_${brief_id}_$(date +%Y%m%d_%H%M%S).log"
    local WORKER_JSON=$(mktemp)
    local WORKER_START=$(date +%s)

    claude --dangerously-skip-permissions \
        --output-format json \
        $MODEL_FLAG \
        -p "$(cat "$WORKER_PROMPT")" \
        > "$WORKER_JSON" 2>>"$WORKER_LOG"

    local WORKER_EXIT=$?
    local WORKER_END=$(date +%s)
    local WORKER_DURATION=$((WORKER_END - WORKER_START))

    parse_metrics "$WORKER_JSON" "$WORKER_LOG" "worker" "{'brief': '$brief_id', 'model': '${model:-default}', 'exit_code': $WORKER_EXIT}"
    rm -f "$WORKER_JSON"

    # Push results
    if [ "$WORKER_EXIT" -eq 0 ]; then
        git push -u "$GIT_REMOTE" "$branch" 2>&1 || daemon_log "WORKER: push failed (non-fatal)"
        daemon_log "WORKER: iteration complete (${WORKER_DURATION}s), pushed to $branch"
        notify "$brief_id: iteration done (${WORKER_DURATION}s)"
        CONSECUTIVE_WORKER_FAILURES=0
    else
        daemon_log "WORKER: iteration FAILED (exit $WORKER_EXIT, ${WORKER_DURATION}s)"
        notify "$brief_id: worker FAILED (exit $WORKER_EXIT)"
        CONSECUTIVE_WORKER_FAILURES=$((CONSECUTIVE_WORKER_FAILURES + 1))

        if [ "$WORKER_DURATION" -le 10 ] && grep -q "out of extra usage" "$WORKER_LOG" 2>/dev/null; then
            git checkout "$GIT_MAIN_BRANCH" -q 2>/dev/null
            handle_rate_limit "$WORKER_LOG"
            return 1
        fi
    fi

    # Return to main branch
    git checkout "$GIT_MAIN_BRANCH" -q 2>/dev/null

    return $WORKER_EXIT
}

# ╔══════════════════════════════════════════════════════════════════╗
# ║  Signal Handling                                                ║
# ╚══════════════════════════════════════════════════════════════════╝

SHUTTING_DOWN=0
cleanup() {
    [ "$SHUTTING_DOWN" -eq 1 ] && return
    SHUTTING_DOWN=1
    echo ""
    daemon_log "SHUTDOWN: caught signal, exiting cleanly"
    notify "Daemon stopped"
    pkill -P $$ 2>/dev/null
    rm -f "$PID_FILE"
    exit 0
}
trap 'cleanup' SIGINT SIGTERM SIGHUP EXIT

notify "Daemon started (PID $$)"

# ╔══════════════════════════════════════════════════════════════════╗
# ║  Main Loop                                                      ║
# ╚══════════════════════════════════════════════════════════════════╝

TURN=0
LAST_CONDUCTOR_TRIGGER=""

while true; do
    TURN=$((TURN + 1))

    # --- Pause check ---
    if [ -f "$SIGNALS_DIR/pause.json" ]; then
        daemon_log "PAUSED: $(cat "$SIGNALS_DIR/pause.json")"
        notify "Paused"

        while [ -f "$SIGNALS_DIR/pause.json" ] && [ ! -f "$SIGNALS_DIR/resume.json" ]; do
            sleep 60
        done

        if [ -f "$SIGNALS_DIR/resume.json" ]; then
            daemon_log "RESUMED: $(cat "$SIGNALS_DIR/resume.json")"
            notify "Resumed"
            rm -f "$SIGNALS_DIR/pause.json" "$SIGNALS_DIR/resume.json"
        fi
    fi

    # --- Git sync ---
    cd "$PROJECT_DIR"
    CURRENT_BRANCH=$(git branch --show-current 2>/dev/null)
    if [ "$CURRENT_BRANCH" != "$GIT_MAIN_BRANCH" ]; then
        daemon_log "GIT CLEANUP: on '$CURRENT_BRANCH', switching to $GIT_MAIN_BRANCH"
        git stash -q 2>/dev/null
        git checkout "$GIT_MAIN_BRANCH" -q 2>/dev/null || git checkout -f "$GIT_MAIN_BRANCH" -q 2>/dev/null
    fi
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        git stash -q 2>/dev/null
    fi
    git fetch "$GIT_REMOTE" --quiet 2>/dev/null
    git pull --ff-only "$GIT_REMOTE" "$GIT_MAIN_BRANCH" -q 2>/dev/null || true

    DID_WORK=false

    # ┌─────────────────────────────────────┐
    # │  Phase 1: Assess state              │
    # └─────────────────────────────────────┘
    ASSESS_OUTPUT=$(assess_state)
    CONDUCTOR_TRIGGER=$(echo "$ASSESS_OUTPUT" | head -1)
    WORKER_TARGET=$(echo "$ASSESS_OUTPUT" | tail -1)

    # ┌─────────────────────────────────────┐
    # │  Phase 2: Conductor (if triggered)  │
    # └─────────────────────────────────────┘
    case "$CONDUCTOR_TRIGGER" in
        CONDUCTOR:*)
            REASON="${CONDUCTOR_TRIGGER#CONDUCTOR:}"

            # Dedup: skip if same trigger as last tick
            if [ "$CONDUCTOR_TRIGGER" = "$LAST_CONDUCTOR_TRIGGER" ]; then
                daemon_log "CONDUCTOR: dedup — same trigger ($REASON), skipping"
            else
                invoke_conductor "$REASON"
                LAST_CONDUCTOR_TRIGGER="$CONDUCTOR_TRIGGER"
                DID_WORK=true

                # Re-assess after conductor
                ASSESS_OUTPUT=$(assess_state)
                WORKER_TARGET=$(echo "$ASSESS_OUTPUT" | tail -1)
            fi
            ;;
    esac

    # ┌──────────────────────────────────────────────┐
    # │  Phase 2.5: Daemon-side state transitions   │
    # └──────────────────────────────────────────────┘
    DAEMON_ACTIONS="$DAEMON_LIB_DIR/actions.py"

    # Process completed briefs: move to eval
    for active_entry in $(python3 -c "
import json, subprocess
try:
    with open('$RUNNING_FILE') as f:
        rc = json.load(f)
    for b in rc.get('active', []):
        branch = b.get('branch', '')
        if not branch: continue
        for ref in [branch, f'$GIT_REMOTE/{branch}']:
            try:
                r = subprocess.run(['git', '-C', '$PROJECT_DIR', 'show', f'{ref}:.loop/state/progress.json'],
                    capture_output=True, text=True, timeout=10)
                if r.returncode == 0:
                    p = json.loads(r.stdout)
                    if p.get('status') == 'complete':
                        print(b.get('brief', ''))
                    break
            except: continue
except: pass
" 2>/dev/null); do
        if [ -n "$active_entry" ]; then
            daemon_log "DAEMON ACTION: move-to-eval $active_entry"
            python3 "$DAEMON_ACTIONS" move-to-eval "$active_entry" "$PROJECT_DIR" 2>>"$LOG_DIR/daemon.log" && DID_WORK=true
            notify "$active_entry complete → awaiting evaluation"
        fi
    done

    # Process pending dispatch queue
    if [ -f "$STATE_DIR/pending-dispatch.json" ]; then
        daemon_log "DAEMON ACTION: processing pending dispatch"
        if ! python3 "$DAEMON_ACTIONS" dispatch "$PROJECT_DIR" 2>>"$LOG_DIR/daemon.log"; then
            daemon_log "DAEMON ACTION: dispatch failed, retrying once"
            sleep 5
            python3 "$DAEMON_ACTIONS" dispatch "$PROJECT_DIR" 2>>"$LOG_DIR/daemon.log" || \
                daemon_log "DAEMON ACTION: dispatch retry failed"
        fi
        DID_WORK=true
        ASSESS_OUTPUT=$(assess_state)
        WORKER_TARGET=$(echo "$ASSESS_OUTPUT" | tail -1)
    fi

    # Process pending merge queue
    if [ -f "$STATE_DIR/pending-merge.json" ]; then
        daemon_log "DAEMON ACTION: processing pending merge"
        python3 "$DAEMON_ACTIONS" merge "$PROJECT_DIR" 2>>"$LOG_DIR/daemon.log"
        if [ $? -eq 0 ]; then
            notify "Brief merged to $GIT_MAIN_BRANCH"
        fi
        DID_WORK=true
        ASSESS_OUTPUT=$(assess_state)
        WORKER_TARGET=$(echo "$ASSESS_OUTPUT" | tail -1)
    fi

    # ┌─────────────────────────────────────┐
    # │  Phase 3: Worker (if active brief)  │
    # └─────────────────────────────────────┘
    case "$WORKER_TARGET" in
        WORKER:*)
            IFS=',' read -r BRIEF_ID BRIEF_BRANCH <<< "${WORKER_TARGET#WORKER:}"

            if [ "$CONSECUTIVE_WORKER_FAILURES" -ge 3 ]; then
                daemon_log "WORKER: 3 consecutive failures — escalating to conductor"
                notify "3 worker failures on $BRIEF_ID — escalating"
                invoke_conductor "worker_failures_${BRIEF_ID}"
                CONSECUTIVE_WORKER_FAILURES=0
            else
                run_worker_iteration "$BRIEF_ID" "$BRIEF_BRANCH"
                DID_WORK=true
                LAST_CONDUCTOR_TRIGGER=""
            fi
            ;;
    esac

    # ┌─────────────────────────────────────┐
    # │  Phase 4: Notifications             │
    # └─────────────────────────────────────┘
    if [ -f "$SIGNALS_DIR/escalate.json" ]; then
        ESCALATE_MSG=$(python3 -c "import json; print(json.load(open('$SIGNALS_DIR/escalate.json')).get('reason','Review needed'))" 2>/dev/null || echo "Review needed")
        if [ ! -f "$SIGNALS_DIR/.escalate_notified" ]; then
            notify "$ESCALATE_MSG"
            daemon_log "NOTIFY: escalation sent"
            touch "$SIGNALS_DIR/.escalate_notified"
        fi
    else
        rm -f "$SIGNALS_DIR/.escalate_notified"
    fi

    # ┌─────────────────────────────────────┐
    # │  Phase 5: Sleep (adaptive)          │
    # └─────────────────────────────────────┘
    if [ "$DID_WORK" = true ]; then
        CONSECUTIVE_SKIPS=0
        daemon_log "Sleeping ${WORKER_COOLDOWN}s before next tick"
        sleep "$WORKER_COOLDOWN"
    else
        CONSECUTIVE_SKIPS=$((CONSECUTIVE_SKIPS + 1))
        if [ "$CONSECUTIVE_SKIPS" -ge 6 ]; then
            SKIP_SLEEP=900   # 15 min
        elif [ "$CONSECUTIVE_SKIPS" -ge 3 ]; then
            SKIP_SLEEP=600   # 10 min
        else
            SKIP_SLEEP="$HEARTBEAT_INTERVAL"
        fi
        daemon_log "IDLE #$TURN: nothing to do — sleeping $((SKIP_SLEEP / 60))m (skip $CONSECUTIVE_SKIPS)"

        python3 -c "
import json, datetime
entry = {
    'timestamp': datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
    'source': 'daemon',
    'category': 'idle',
    'heartbeat': $TURN,
    'cost_usd': 0,
    'consecutive_skips': $CONSECUTIVE_SKIPS,
    'sleep_interval_s': $SKIP_SLEEP
}
with open('$METRICS_FILE', 'a') as f:
    f.write(json.dumps(entry) + '\n')
" 2>/dev/null

        sleep "$SKIP_SLEEP"
    fi
done
