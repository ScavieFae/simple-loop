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
#
# Model tier policy (2026-04-21, revised from brief-003 baseline):
#   heartbeat = haiku  (reserved — no heartbeat Claude calls today; assess.py is pure Python)
#   conductor = opus   (substantive state-transition reasoning, taste calls)
#   validator = sonnet (spec-fit review — Sonnet is sufficient; opt up per-brief if needed)
#   worker    = per-brief from **Model:** frontmatter, default sonnet
#                (set **Model:** opus in brief frontmatter for hard work)
# Any new `claude` invocation in this file MUST name a --model flag explicitly.

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
# Validator default agent spec (per-brief **Validator:** override lands in task 5).
VALIDATOR_AGENT_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/core/agents/reviewer.md"

HEARTBEAT_INTERVAL="${2:-${HEARTBEAT_INTERVAL:-300}}"
WORKER_COOLDOWN="${WORKER_COOLDOWN:-30}"
MAX_ITERATIONS="${MAX_ITERATIONS:-20}"
NTFY_TOPIC="${SIMPLE_LOOP_NTFY_TOPIC:-${NTFY_TOPIC:-}}"
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
[ -f "$RUNNING_FILE" ] || echo '{"active":[],"completed_pending_eval":[],"pending_merges":[],"awaiting_review":[],"history":[]}' > "$RUNNING_FILE"

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
    # bin-loop's `>> "$LOG_FILE" 2>&1` outer redirect already appends stdout
    # (and stderr) to daemon.log. `tee -a` here would double-write each line,
    # which made `loop logs -f` print every entry twice.
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
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

    # Tier: conductor = opus (see top-of-file model tier policy).
    claude --model opus --dangerously-skip-permissions \
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

        # Brief-003 Thread 7: Auto-merge layer.
        # If the conductor wrote an `escalate.json` with reason
        # `human_approval_required_for_merge`, check whether the brief opted in
        # via `**Auto-merge:** true` + validator verdict == `pass` + no
        # `.loop/state/pause-auto-merge` kill-switch. When all three hold, swap
        # escalate.json → pending-merge.json and log `auto_merge_approved`.
        # Any other escalation class (infra failure, validator_block, etc.)
        # still pages a human — auto-merge is strictly opt-in per brief.
        if [ -f "$SIGNALS_DIR/escalate.json" ]; then
            AM_OUT=$(python3 "$DAEMON_LIB_DIR/auto_merge.py" check-escalate "$PROJECT_DIR" 2>&1)
            AM_RC=$?
            if [ "$AM_RC" -eq 0 ] && [ -n "$AM_OUT" ]; then
                daemon_log "AUTO-MERGE: $AM_OUT"
            fi
        fi

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

    # Resolve worktree — create if needed
    local WORKTREE_DIR="$PROJECT_DIR/.loop/worktrees/$brief_id"

    if [ ! -d "$WORKTREE_DIR" ]; then
        daemon_log "WORKER: creating worktree for $brief_id"
        mkdir -p "$PROJECT_DIR/.loop/worktrees"

        if git -C "$PROJECT_DIR" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
            git -C "$PROJECT_DIR" worktree add "$WORKTREE_DIR" "$branch" -q 2>/dev/null
        elif git -C "$PROJECT_DIR" show-ref --verify --quiet "refs/remotes/${GIT_REMOTE}/$branch" 2>/dev/null; then
            git -C "$PROJECT_DIR" worktree add "$WORKTREE_DIR" "$branch" -q 2>/dev/null
        else
            daemon_log "WORKER: creating branch $branch from $GIT_MAIN_BRANCH"
            git -C "$PROJECT_DIR" worktree add -b "$branch" "$WORKTREE_DIR" "$GIT_MAIN_BRANCH" -q 2>/dev/null
        fi

        if [ ! -d "$WORKTREE_DIR" ]; then
            daemon_log "WORKER ERROR: failed to create worktree for $branch"
            return 1
        fi
    fi

    daemon_log "WORKER: starting iteration for $brief_id in worktree"

    # Pull latest into worktree (doesn't touch main tree)
    git -C "$WORKTREE_DIR" pull --ff-only "$GIT_REMOTE" "$branch" -q 2>/dev/null || true

    # Initialize progress.json if missing (in worktree)
    local PROGRESS_FILE="$WORKTREE_DIR/.loop/state/progress.json"
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

        if [ -z "$brief_file" ] || [ ! -f "$WORKTREE_DIR/$brief_file" ]; then
            daemon_log "WORKER: no brief file found for $brief_id — skipping"
            return 0
        fi

        daemon_log "WORKER: initializing progress.json for $brief_id"
        mkdir -p "$(dirname "$PROGRESS_FILE")"
        echo "{\"brief\": \"$brief_id\", \"brief_file\": \"$brief_file\", \"iteration\": 0, \"status\": \"running\", \"tasks_completed\": [], \"tasks_remaining\": [], \"learnings\": []}" > "$PROGRESS_FILE"
        git -C "$WORKTREE_DIR" add ".loop/state/progress.json"
        git -C "$WORKTREE_DIR" commit -m "Initialize progress for $brief_id" -q 2>/dev/null
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
        git -C "$WORKTREE_DIR" add ".loop/state/progress.json"
        git -C "$WORKTREE_DIR" commit -m "Max iterations reached — marking blocked" -q 2>/dev/null
        git -C "$WORKTREE_DIR" push -u "$GIT_REMOTE" "$branch" 2>&1 || true
        return 0
    fi

    # Tier: worker = per-brief (see top-of-file model tier policy).
    # Default sonnet; override from brief frontmatter **Model:** line (e.g. "opus").
    local WORKER_MODEL="sonnet"
    local brief_file_path
    brief_file_path=$(python3 -c "import json; print(json.load(open('$PROGRESS_FILE')).get('brief_file', ''))" 2>/dev/null)
    if [ -n "$brief_file_path" ] && [ -f "$WORKTREE_DIR/$brief_file_path" ]; then
        local brief_model
        brief_model=$(grep -m1 '^\*\*Model:\*\*' "$WORKTREE_DIR/$brief_file_path" 2>/dev/null | sed 's/.*\*\*Model:\*\*[[:space:]]*//' | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        if [ -n "$brief_model" ]; then
            WORKER_MODEL="$brief_model"
            if [ "$brief_model" != "sonnet" ]; then
                daemon_log "WORKER: using model '$brief_model' (from brief)"
            fi
        fi
    fi

    # Run one iteration IN THE WORKTREE (main tree untouched)
    local WORKER_LOG="$LOG_DIR/worker_${brief_id}_$(date +%Y%m%d_%H%M%S).log"
    local WORKER_JSON=$(mktemp)
    local WORKER_START=$(date +%s)

    # Read prompt from main tree (canonical), execute in worktree
    local PROMPT_CONTENT
    PROMPT_CONTENT=$(cat "$WORKER_PROMPT")

    cd "$WORKTREE_DIR"

    claude --model "$WORKER_MODEL" --dangerously-skip-permissions \
        --output-format json \
        -p "$PROMPT_CONTENT" \
        > "$WORKER_JSON" 2>>"$WORKER_LOG"

    local WORKER_EXIT=$?
    local WORKER_END=$(date +%s)
    local WORKER_DURATION=$((WORKER_END - WORKER_START))

    cd "$PROJECT_DIR"

    parse_metrics "$WORKER_JSON" "$WORKER_LOG" "worker" "{'brief': '$brief_id', 'model': '$WORKER_MODEL', 'exit_code': $WORKER_EXIT}"
    rm -f "$WORKER_JSON"

    # Push results from worktree
    if [ "$WORKER_EXIT" -eq 0 ]; then
        git -C "$WORKTREE_DIR" push -u "$GIT_REMOTE" "$branch" 2>&1 || daemon_log "WORKER: push failed (non-fatal)"
        daemon_log "WORKER: iteration complete (${WORKER_DURATION}s), pushed to $branch"
        notify "$brief_id: iteration done (${WORKER_DURATION}s)"
        CONSECUTIVE_WORKER_FAILURES=0
    else
        daemon_log "WORKER: iteration FAILED (exit $WORKER_EXIT, ${WORKER_DURATION}s)"
        notify "$brief_id: worker FAILED (exit $WORKER_EXIT)"
        CONSECUTIVE_WORKER_FAILURES=$((CONSECUTIVE_WORKER_FAILURES + 1))

        if [ "$WORKER_DURATION" -le 10 ] && grep -q "out of extra usage" "$WORKER_LOG" 2>/dev/null; then
            handle_rate_limit "$WORKER_LOG"
            return 1
        fi
    fi

    # No checkout needed — main tree was never touched

    return $WORKER_EXIT
}

# ╔══════════════════════════════════════════════════════════════════╗
# ║  Validator Iteration                                            ║
# ╚══════════════════════════════════════════════════════════════════╝
#
# Fires between Phase 2.5 and Phase 3 when assess.py emits a VALIDATOR target.
# Reads the builder commit fresh-context, writes a review artifact to
# .loop/modules/validator/state/reviews/<brief>-cycle-<N>.md on the brief
# branch. The validator is read-only on source (anti-pattern: "Don't put the
# validator in the commit path"); this function commits+pushes the review
# artifact on the validator's behalf after its Claude subprocess exits.

run_validator_iteration() {
    local brief_id="$1"
    local branch="$2"
    local commit_sha="$3"

    local WORKTREE_DIR="$PROJECT_DIR/.loop/worktrees/$brief_id"
    if [ ! -d "$WORKTREE_DIR" ]; then
        daemon_log "VALIDATOR: no worktree for $brief_id — skipping"
        return 0
    fi

    # Pull latest into worktree
    git -C "$WORKTREE_DIR" pull --ff-only "$GIT_REMOTE" "$branch" -q 2>/dev/null || true

    local PROGRESS_FILE="$WORKTREE_DIR/.loop/state/progress.json"
    if [ ! -f "$PROGRESS_FILE" ]; then
        daemon_log "VALIDATOR: no progress.json in worktree for $brief_id — skipping"
        return 0
    fi

    local cycle
    cycle=$(python3 -c "import json; print(json.load(open('$PROGRESS_FILE')).get('iteration', 0))" 2>/dev/null || echo "0")
    if [ -z "$cycle" ] || [ "$cycle" = "0" ]; then
        daemon_log "VALIDATOR: $brief_id cycle=0 — nothing to review yet"
        return 0
    fi

    local brief_file
    brief_file=$(python3 -c "import json; print(json.load(open('$PROGRESS_FILE')).get('brief_file', ''))" 2>/dev/null)

    # Per-brief validator override (Thread 1 scope item). Brief frontmatter
    # `**Validator:**` names an agent spec. Resolution:
    #   - bare name (e.g. `loop-reviewer`, `reviewer`, `security-reviewer`)
    #     → `core/agents/<name>.md` (with optional `loop-` prefix stripped)
    #   - path containing `/`
    #     → absolute path used as-is; relative path resolved under worktree
    # Unresolvable overrides log and fall back to default. VALIDATOR_NAME
    # carries through to the review artifact's `validator:` frontmatter.
    local VALIDATOR_NAME="loop-reviewer"
    local VALIDATOR_AGENT_FILE="$VALIDATOR_AGENT_DEFAULT"
    if [ -n "$brief_file" ] && [ -f "$WORKTREE_DIR/$brief_file" ]; then
        local brief_validator
        brief_validator=$(grep -m1 '^\*\*Validator:\*\*' "$WORKTREE_DIR/$brief_file" 2>/dev/null \
            | sed 's/.*\*\*Validator:\*\*[[:space:]]*//' | awk '{print $1}')
        if [ -n "$brief_validator" ]; then
            local resolved=""
            if [[ "$brief_validator" == /* ]]; then
                resolved="$brief_validator"
            elif [[ "$brief_validator" == */* ]]; then
                resolved="$WORKTREE_DIR/$brief_validator"
            else
                local base="${brief_validator#loop-}"
                resolved="$(dirname "$VALIDATOR_AGENT_DEFAULT")/${base}.md"
            fi
            if [ -f "$resolved" ]; then
                VALIDATOR_NAME="$brief_validator"
                VALIDATOR_AGENT_FILE="$resolved"
                daemon_log "VALIDATOR: using override '$brief_validator' (from brief)"
            else
                daemon_log "VALIDATOR: override '$brief_validator' unresolved at '$resolved' — using default loop-reviewer"
            fi
        fi
    fi

    daemon_log "VALIDATOR: reviewing $brief_id cycle $cycle (commit ${commit_sha:0:8})"

    mkdir -p "$WORKTREE_DIR/.loop/modules/validator/state/reviews"

    local REVIEW_REL=".loop/modules/validator/state/reviews/${brief_id}-cycle-${cycle}.md"

    # Build prompt: agent spec + per-run context + required schema.
    # Strip any leading YAML frontmatter — the claude CLI parses a prompt
    # starting with `---` as a flag and aborts with "unknown option '---".
    local AGENT_SPEC=""
    if [ -f "$VALIDATOR_AGENT_FILE" ]; then
        AGENT_SPEC=$(awk 'NR==1 && $0=="---"{in_fm=1; next} in_fm && $0=="---"{in_fm=0; next} !in_fm' "$VALIDATOR_AGENT_FILE")
    fi

    local NOW_ISO
    NOW_ISO=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    local VALIDATOR_PROMPT_BODY="$AGENT_SPEC

---

# This validation run

You are reviewing ONE builder cycle, fresh-context. No previous conversation.

- Brief ID: \`$brief_id\`
- Branch: \`$branch\`
- Cycle (iteration): $cycle
- Commit under review: \`$commit_sha\`
- Brief file: \`$brief_file\`

## What to read

1. Brief: \`cat $brief_file\`
2. Progress so far: \`cat .loop/state/progress.json\`
3. Diff under review: \`git show $commit_sha\`
4. Recent history: \`git log --oneline -10\`

## What to write

ONE file, at path:

\`\`\`
$REVIEW_REL
\`\`\`

Use this exact shape (YAML frontmatter + four fixed body buckets):

\`\`\`markdown
---
cycle: $cycle
commit: $commit_sha
brief: $brief_id
branch: $branch
verdict: pass   # one of: pass | issues | block
summary: <one-line verdict, <=120 chars>
validator: $VALIDATOR_NAME
reviewed_at: $NOW_ISO
---

## Bugs found
- _none_ OR bullet list

## Execution concerns
- _none_ OR bullet list

## Spec-fit notes
- _none_ OR bullet list

## Deferred items
- _none_ OR bullet list
\`\`\`

Verdict guide:
- \`pass\` — no issues, clean spec-fit. Conductor proceeds as today.
- \`issues\` — non-blocking concerns surfaced. Do NOT block merge; conductor reads at merge-time.
- \`block\` — show-stopper bug or spec violation. The daemon preempts conductor on the next tick with \`validator_blocked\`.

## Rules

- Read-only on source code. You may ONLY create/modify the review file above.
- Do NOT run git commit, git push, or any git write operation. The daemon commits the review on your behalf after you exit.
- Do NOT modify any file outside \`$REVIEW_REL\`.
- All four body buckets must appear. Empty buckets use the literal \`_none_\`.
- Keep \`summary\` tight — it's the at-a-glance line Mattie reads in the wiki."

    local VALIDATOR_LOG="$LOG_DIR/validator_${brief_id}_$(date +%Y%m%d_%H%M%S).log"
    local VALIDATOR_JSON=$(mktemp)
    local V_START=$(date +%s)

    cd "$WORKTREE_DIR"

    # Tier: validator = sonnet (see top-of-file model tier policy).
    claude --model sonnet --dangerously-skip-permissions \
        --output-format json \
        -p "$VALIDATOR_PROMPT_BODY" \
        > "$VALIDATOR_JSON" 2>>"$VALIDATOR_LOG"

    local V_EXIT=$?
    local V_END=$(date +%s)
    local V_DURATION=$((V_END - V_START))

    cd "$PROJECT_DIR"

    parse_metrics "$VALIDATOR_JSON" "$VALIDATOR_LOG" "validator" "{'brief': '$brief_id', 'cycle': $cycle, 'commit': '${commit_sha:0:12}', 'exit_code': $V_EXIT}"
    rm -f "$VALIDATOR_JSON"

    if [ "$V_EXIT" -ne 0 ]; then
        daemon_log "VALIDATOR: FAILED (exit $V_EXIT, ${V_DURATION}s)"
        notify "$brief_id: validator FAILED (exit $V_EXIT)"
        if [ "$V_DURATION" -le 10 ] && grep -q "out of extra usage" "$VALIDATOR_LOG" 2>/dev/null; then
            handle_rate_limit "$VALIDATOR_LOG"
            return 1
        fi
        return $V_EXIT
    fi

    if [ ! -f "$WORKTREE_DIR/$REVIEW_REL" ]; then
        daemon_log "VALIDATOR: expected review file not written at $REVIEW_REL — nothing to commit"
        return 0
    fi

    # Daemon commits + pushes the review artifact (validator is read-only).
    git -C "$WORKTREE_DIR" add "$REVIEW_REL"
    if git -C "$WORKTREE_DIR" diff --cached --quiet; then
        daemon_log "VALIDATOR: review file unchanged — skipping commit"
    else
        git -C "$WORKTREE_DIR" commit -m "[scav] validator: $brief_id cycle $cycle review" -q 2>/dev/null
        git -C "$WORKTREE_DIR" push -u "$GIT_REMOTE" "$branch" 2>&1 || daemon_log "VALIDATOR: push failed (non-fatal)"
        daemon_log "VALIDATOR: review committed for $brief_id cycle $cycle (${V_DURATION}s)"
        notify "$brief_id: validator review cycle $cycle"
    fi

    return 0
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

# ── Startup repair ──────────────────────────────────────────────────────────
# Reconcile running.json against ground truth (git log + filesystem) before
# the tick loop begins. Catches state drift across restarts and hand-merges.
# Disable with NT_DAEMON_STARTUP_REPAIR=false.
if [ "${NT_DAEMON_STARTUP_REPAIR:-true}" = "false" ]; then
    daemon_log "STARTUP REPAIR: disabled via NT_DAEMON_STARTUP_REPAIR=false"
else
    REPAIR_COUNT=$(python3 -c "
import sys
sys.path.insert(0, '$DAEMON_LIB_DIR')
from startup_repair import run_startup_repair
from actions import init_paths
paths = init_paths('$PROJECT_DIR')
actions = run_startup_repair(paths, '$PROJECT_DIR')
print(len(actions))
" 2>/dev/null || echo "0")
    daemon_log "STARTUP REPAIR: complete (${REPAIR_COUNT:-0} action(s))"
fi

notify "Daemon started (PID $$)"

# ╔══════════════════════════════════════════════════════════════════╗
# ║  Main Loop                                                      ║
# ╚══════════════════════════════════════════════════════════════════╝

TURN=0
LAST_CONDUCTOR_TRIGGER=""
LAST_ESCALATE_PRESENT=false

while true; do
    TURN=$((TURN + 1))

    # --- Escalate-resolved detection (breaks dedup on stale triggers) ---
    # When the conductor writes escalate.json, subsequent ticks with the same
    # trigger de-dup and the daemon goes silent. If a human (or scav) clears
    # the escalate, the daemon must re-run the conductor — otherwise it sits
    # deduped on a decision that no longer applies.  Track escalate presence
    # across ticks; on the tick where it disappears, reset the dedup marker.
    if [ -f "$SIGNALS_DIR/escalate.json" ]; then
        CURRENT_ESCALATE_PRESENT=true
    else
        CURRENT_ESCALATE_PRESENT=false
    fi
    if [ "$LAST_ESCALATE_PRESENT" = "true" ] && [ "$CURRENT_ESCALATE_PRESENT" = "false" ]; then
        daemon_log "CONDUCTOR: escalate.json resolved — resetting dedup so next conductor re-evaluates"
        LAST_CONDUCTOR_TRIGGER=""
    fi
    LAST_ESCALATE_PRESENT="$CURRENT_ESCALATE_PRESENT"

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

    # --- Git sync (worktree-safe: never stash, never force-checkout) ---
    cd "$PROJECT_DIR"
    git fetch "$GIT_REMOTE" --quiet 2>/dev/null

    CURRENT_BRANCH=$(git branch --show-current 2>/dev/null)
    if [ "$CURRENT_BRANCH" = "$GIT_MAIN_BRANCH" ]; then
        # Only pull if we're on main — don't disturb user's branch
        git pull --ff-only "$GIT_REMOTE" "$GIT_MAIN_BRANCH" -q 2>/dev/null || true
    else
        daemon_log "GIT SYNC: main tree on '$CURRENT_BRANCH' (not $GIT_MAIN_BRANCH) — fetch only"
    fi

    DID_WORK=false

    # ┌─────────────────────────────────────┐
    # │  Phase 1: Assess state              │
    # └─────────────────────────────────────┘
    # assess.py prints three lines: conductor trigger, worker target, validator target.
    ASSESS_OUTPUT=$(assess_state)
    CONDUCTOR_TRIGGER=$(echo "$ASSESS_OUTPUT" | sed -n 1p)
    WORKER_TARGET=$(echo "$ASSESS_OUTPUT" | sed -n 2p)
    VALIDATOR_TARGET=$(echo "$ASSESS_OUTPUT" | sed -n 3p)

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
                WORKER_TARGET=$(echo "$ASSESS_OUTPUT" | sed -n 2p)
                VALIDATOR_TARGET=$(echo "$ASSESS_OUTPUT" | sed -n 3p)
            fi
            ;;
    esac

    # ┌──────────────────────────────────────────────┐
    # │  Phase 2.5: Daemon-side state transitions   │
    # └──────────────────────────────────────────────┘
    DAEMON_ACTIONS="$DAEMON_LIB_DIR/actions.py"

    # Process completed briefs: free active slot immediately (v2 flow).
    # Reads auto-merge flag from brief frontmatter; routes to pending_merges
    # (auto) or awaiting_review (human). Active slot is freed on the same tick
    # completion is detected, so dispatch can fire without waiting for merge.
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
            # Read auto-merge flag from brief frontmatter on the brief branch
            AM_FLAG=$(python3 -c "
import json, subprocess, re, sys
RE = re.compile(r'^\s*\*\*Auto-merge:\*\*\s*(\S+)', re.IGNORECASE)
try:
    with open('$RUNNING_FILE') as f:
        rc = json.load(f)
    for b in rc.get('active', []):
        if b.get('brief') != '$active_entry':
            continue
        branch = b.get('branch', '')
        brief_file = b.get('brief_file', '')
        if not branch or not brief_file:
            break
        for ref in [branch, '$GIT_REMOTE/' + branch]:
            r = subprocess.run(['git', '-C', '$PROJECT_DIR', 'show', f'{ref}:{brief_file}'],
                capture_output=True, text=True, timeout=10)
            if r.returncode == 0:
                for line in r.stdout.splitlines():
                    m = RE.match(line)
                    if m:
                        val = m.group(1).strip().lower().strip('\"').strip(\"'\")
                        print('true' if val == 'true' else 'false')
                        sys.exit(0)
                print('false')
                sys.exit(0)
        break
except: pass
print('false')
" 2>/dev/null)

            if [ "$AM_FLAG" = "true" ]; then
                daemon_log "DAEMON ACTION: move-to-pending-merges $active_entry (auto-merge)"
                python3 "$DAEMON_ACTIONS" move-to-pending-merges "$active_entry" "$PROJECT_DIR" 2>>"$LOG_DIR/daemon.log" && DID_WORK=true
                notify "$active_entry complete → queued for auto-merge"
            else
                daemon_log "DAEMON ACTION: move-to-awaiting-review $active_entry (human approval required)"
                python3 "$DAEMON_ACTIONS" move-to-awaiting-review "$active_entry" "$PROJECT_DIR" 2>>"$LOG_DIR/daemon.log" && DID_WORK=true
                notify "$active_entry complete → awaiting human review (run: loop approve $active_entry)"
            fi
        fi
    done

    # Process pending dispatch queue
    if [ -f "$STATE_DIR/pending-dispatch.json" ]; then
        # Check **Depends-on:** frontmatter before dispatching.
        # If the brief's dependency hasn't merged yet, cancel this dispatch
        # so the conductor retries next tick (potentially picking a different brief).
        DEPS_CHECK=$(python3 -c "
import json, re, os, sys
RE_DEP = re.compile(r'^\s*\*\*Depends-on:\*\*\s*(\S+)', re.IGNORECASE)
try:
    with open('$STATE_DIR/pending-dispatch.json') as f:
        spec = json.load(f)
    brief_file = spec.get('brief_file', '')
    bf_path = os.path.join('$PROJECT_DIR', brief_file) if brief_file else ''
    depends_on = None
    if bf_path and os.path.exists(bf_path):
        with open(bf_path) as f:
            for line in f:
                m = RE_DEP.match(line)
                if m:
                    depends_on = m.group(1).strip()
                    break
    if not depends_on:
        print('allowed')
        sys.exit(0)
    with open('$RUNNING_FILE') as f:
        rc = json.load(f)
    history_ids = [h.get('brief', '') for h in rc.get('history', [])]
    if depends_on in history_ids:
        print('allowed')
    else:
        print('blocked:' + depends_on)
except Exception:
    print('allowed')  # fail open — don't block dispatch on parse errors
" 2>/dev/null)
        if [[ "${DEPS_CHECK:-allowed}" == blocked:* ]]; then
            DEP_ID="${DEPS_CHECK#blocked:}"
            BLOCKED_BRIEF=$(python3 -c "import json; print(json.load(open('$STATE_DIR/pending-dispatch.json')).get('brief',''))" 2>/dev/null || echo "unknown")
            daemon_log "DAEMON ACTION: dispatch blocked — $BLOCKED_BRIEF depends-on $DEP_ID (not yet merged)"
            notify "$BLOCKED_BRIEF dispatch blocked: depends on $DEP_ID (not merged yet)"
            rm -f "$STATE_DIR/pending-dispatch.json"
        else
            daemon_log "DAEMON ACTION: processing pending dispatch"
            if ! python3 "$DAEMON_ACTIONS" dispatch "$PROJECT_DIR" 2>>"$LOG_DIR/daemon.log"; then
                daemon_log "DAEMON ACTION: dispatch failed, retrying once"
                sleep 5
                python3 "$DAEMON_ACTIONS" dispatch "$PROJECT_DIR" 2>>"$LOG_DIR/daemon.log" || \
                    daemon_log "DAEMON ACTION: dispatch retry failed"
            fi
            DID_WORK=true
            ASSESS_OUTPUT=$(assess_state)
            WORKER_TARGET=$(echo "$ASSESS_OUTPUT" | sed -n 2p)
            VALIDATOR_TARGET=$(echo "$ASSESS_OUTPUT" | sed -n 3p)
        fi
    fi

    # Process pending_merges queue (peer to dispatch — runs same tick, does not block).
    # Pops one entry from running.json pending_merges[], writes pending-merge.json,
    # executes merge. Guard against double-processing if pending-merge.json already exists.
    PENDING_MERGE_COUNT=$(python3 -c "
import json
try:
    with open('$RUNNING_FILE') as f:
        rc = json.load(f)
    print(len(rc.get('pending_merges', [])))
except: print(0)
" 2>/dev/null || echo "0")
    if [ "${PENDING_MERGE_COUNT:-0}" -gt 0 ] && [ ! -f "$STATE_DIR/pending-merge.json" ]; then
        daemon_log "DAEMON ACTION: processing pending_merges queue ($PENDING_MERGE_COUNT entries)"
        python3 "$DAEMON_ACTIONS" process-pending-merges "$PROJECT_DIR" 2>>"$LOG_DIR/daemon.log"
        if [ $? -eq 0 ]; then
            notify "Brief merged to $GIT_MAIN_BRANCH"
        fi
        DID_WORK=true
        ASSESS_OUTPUT=$(assess_state)
        WORKER_TARGET=$(echo "$ASSESS_OUTPUT" | sed -n 2p)
        VALIDATOR_TARGET=$(echo "$ASSESS_OUTPUT" | sed -n 3p)
    fi

    # Legacy/manual merge path: pending-merge.json written directly (e.g. by loop approve).
    # process-pending-merges above creates+deletes this atomically, so if it persists
    # across ticks it means a manual stamp or a crash recovery case.
    if [ -f "$STATE_DIR/pending-merge.json" ]; then
        daemon_log "DAEMON ACTION: processing pending merge (legacy/manual path)"
        python3 "$DAEMON_ACTIONS" merge "$PROJECT_DIR" 2>>"$LOG_DIR/daemon.log"
        if [ $? -eq 0 ]; then
            notify "Brief merged to $GIT_MAIN_BRANCH"
        fi
        DID_WORK=true
        ASSESS_OUTPUT=$(assess_state)
        WORKER_TARGET=$(echo "$ASSESS_OUTPUT" | sed -n 2p)
        VALIDATOR_TARGET=$(echo "$ASSESS_OUTPUT" | sed -n 3p)
    fi

    # ┌─────────────────────────────────────┐
    # │  Phase 2.7: Validator (if pending)  │
    # └─────────────────────────────────────┘
    # Sits between 2.5 and 3: a builder commit lands on tick N (Phase 3),
    # assess.py sees it on tick N+1 with no matching review → emits
    # VALIDATOR:brief,branch,commit. Validator runs fresh-context; daemon
    # commits the review artifact on its behalf after the subprocess exits.
    case "$VALIDATOR_TARGET" in
        VALIDATOR:*)
            IFS=',' read -r V_BRIEF V_BRANCH V_COMMIT <<< "${VALIDATOR_TARGET#VALIDATOR:}"
            if [ -n "$V_BRIEF" ] && [ -n "$V_BRANCH" ] && [ -n "$V_COMMIT" ]; then
                run_validator_iteration "$V_BRIEF" "$V_BRANCH" "$V_COMMIT"
                DID_WORK=true
                LAST_CONDUCTOR_TRIGGER=""
            else
                daemon_log "VALIDATOR: malformed target '$VALIDATOR_TARGET' — skipping"
            fi
            ;;
    esac

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
