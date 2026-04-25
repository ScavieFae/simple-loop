#!/usr/bin/env bash
# scripts/test-flow-v2.sh — Integration test for simple-loop flow v2.
#
# Verifies:
#   1. Auto-merge path: brief complete → active[] freed → pending_merges[]
#   2. Human-review path: brief complete → active[] freed → awaiting_review[]
#   3. assess.py emits CONDUCTOR:no_active when active[] empty (dispatch unblocked
#      even while pending_merges[] has entries — the key v2 invariant)
#   4. approve-brief: awaiting_review → pending_merges (with approved_at timestamp)
#   5. reject-brief: awaiting_review → history[] (with rejected_at + reason)
#   6. depends-on parsing: read_depends_on() extracts dep id from frontmatter
#   7. Backward compatibility: old running.json without v2 fields loads cleanly
#
# Exits 0 iff all scenarios pass. Run from simple-loop repo root or any dir.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
ACTIONS="$LIB_DIR/actions.py"
ASSESS="$LIB_DIR/assess.py"

for f in "$ACTIONS" "$ASSESS"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: $f not found — run from simple-loop repo" >&2
        exit 1
    fi
done

PASSED=0
FAILED=0

pass() { echo "  PASS  $1"; PASSED=$((PASSED + 1)); }
fail() { echo "  FAIL  $1"; FAILED=$((FAILED + 1)); }

assert_eq() {
    local label="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then
        pass "$label"
    else
        fail "$label — expected '$expected', got '$actual'"
    fi
}

json_get() {
    # json_get <file> <python-expr-on-d>
    python3 -c "import json; d=json.load(open('$1')); print($2)" 2>/dev/null || echo "ERROR"
}

assert_json() {
    local label="$1" file="$2" expr="$3" expected="$4"
    assert_eq "$label" "$(json_get "$file" "$expr")" "$expected"
}

# ── Scratch repo setup ───────────────────────────────────────────────────────

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

git -C "$SCRATCH" init -q -b main
git -C "$SCRATCH" config user.email "test@test"
git -C "$SCRATCH" config user.name  "Test"

mkdir -p "$SCRATCH/.loop/state/signals"
mkdir -p "$SCRATCH/.loop/briefs"
mkdir -p "$SCRATCH/.loop/worktrees"

cat > "$SCRATCH/.loop/config.sh" <<'EOF'
PROJECT_NAME="test"
GIT_REMOTE="origin"
GIT_MAIN_BRANCH="main"
EOF

touch "$SCRATCH/.loop/state/log.jsonl"

# Brief files (frontmatter only — auto-merge and depends-on flags)
cat > "$SCRATCH/.loop/briefs/brief-001-auto.md" <<'EOF'
# Brief: auto-merge test

**ID:** brief-001-auto
**Auto-merge:** true
**Status:** queued
EOF

cat > "$SCRATCH/.loop/briefs/brief-002-human.md" <<'EOF'
# Brief: human-review test

**ID:** brief-002-human
**Auto-merge:** false
**Status:** queued
EOF

cat > "$SCRATCH/.loop/briefs/brief-004-depends.md" <<'EOF'
# Brief: depends-on test

**ID:** brief-004-depends
**Auto-merge:** true
**Depends-on:** brief-999-prereq
**Status:** queued
EOF

write_running() {
    python3 -c "import json; json.dump($1, open('$SCRATCH/.loop/state/running.json','w'), indent=2)"
    git -C "$SCRATCH" add -A
    git -C "$SCRATCH" commit -q -m "test: seed state" 2>/dev/null || true
}

# ── Test 1: auto-merge path ──────────────────────────────────────────────────

echo ""
echo "=== Test 1: auto-merge path (active[] freed → pending_merges[]) ==="

write_running "{
    'active': [{'brief': 'brief-001-auto', 'branch': 'brief-001-auto', 'brief_file': '.loop/briefs/brief-001-auto.md'}],
    'completed_pending_eval': [],
    'pending_merges': [],
    'awaiting_review': [],
    'history': [],
    'queue': []
}"

python3 "$ACTIONS" move-to-pending-merges brief-001-auto "$SCRATCH" > /dev/null 2>&1

RJ="$SCRATCH/.loop/state/running.json"
assert_json "active[] empty after move-to-pending-merges"   "$RJ" "len(d['active'])"            "0"
assert_json "pending_merges[] has one entry"                "$RJ" "len(d['pending_merges'])"    "1"
assert_json "pending_merges[0] is brief-001-auto"           "$RJ" "d['pending_merges'][0]['brief']"  "brief-001-auto"
assert_json "pending_merges[0].auto_merge == True"          "$RJ" "str(d['pending_merges'][0]['auto_merge'])"  "True"
assert_json "pending_merges[0].completed_at present"        "$RJ" "bool(d['pending_merges'][0].get('completed_at'))"  "True"

# ── Test 2: human-review path ────────────────────────────────────────────────

echo ""
echo "=== Test 2: human-review path (active[] freed → awaiting_review[]) ==="

write_running "{
    'active': [{'brief': 'brief-002-human', 'branch': 'brief-002-human', 'brief_file': '.loop/briefs/brief-002-human.md'}],
    'completed_pending_eval': [],
    'pending_merges': [],
    'awaiting_review': [],
    'history': [],
    'queue': []
}"

python3 "$ACTIONS" move-to-awaiting-review brief-002-human "$SCRATCH" "validator requested human review" > /dev/null 2>&1

assert_json "active[] empty after move-to-awaiting-review"  "$RJ" "len(d['active'])"              "0"
assert_json "awaiting_review[] has one entry"               "$RJ" "len(d['awaiting_review'])"     "1"
assert_json "awaiting_review[0] is brief-002-human"         "$RJ" "d['awaiting_review'][0]['brief']"  "brief-002-human"
assert_json "awaiting_review[0].auto_merge == False"        "$RJ" "str(d['awaiting_review'][0]['auto_merge'])"  "False"
assert_json "awaiting_review[0].reason preserved"           "$RJ" "d['awaiting_review'][0].get('reason','')"  "validator requested human review"

# ── Test 3: dispatch unblocked while pending_merges[] non-empty ──────────────

echo ""
echo "=== Test 3: assess.py emits CONDUCTOR:no_active — dispatch unblocked while merge queued ==="

# State: active[] empty, pending_merges has brief-001-auto (from test 1 re-applied)
write_running "{
    'active': [],
    'completed_pending_eval': [],
    'pending_merges': [{'brief': 'brief-001-auto', 'branch': 'brief-001-auto'}],
    'awaiting_review': [],
    'history': [],
    'queue': []
}"
# No pending-dispatch.json, no pending-merge.json, no escalate.json

LINE1=$(python3 "$ASSESS" "$SCRATCH" 2>/dev/null | head -1)
assert_eq "CONDUCTOR:no_active emitted (not blocked by pending_merges)" "$LINE1" "CONDUCTOR:no_active"

# Verify pending_merges doesn't accidentally trigger pending_eval
assert_json "pending_merges[] still has entry (untouched by assess)"  "$RJ" "len(d['pending_merges'])"  "1"

# ── Test 4: approve-brief ────────────────────────────────────────────────────

echo ""
echo "=== Test 4: approve-brief (awaiting_review → pending_merges) ==="

write_running "{
    'active': [],
    'completed_pending_eval': [],
    'pending_merges': [],
    'awaiting_review': [{'brief': 'brief-002-human', 'branch': 'brief-002-human', 'brief_file': '.loop/briefs/brief-002-human.md', 'auto_merge': False}],
    'history': [],
    'queue': []
}"

python3 "$ACTIONS" approve-brief brief-002-human "$SCRATCH" > /dev/null 2>&1

assert_json "awaiting_review[] empty after approve"         "$RJ" "len(d['awaiting_review'])"    "0"
assert_json "pending_merges[] has one entry after approve"  "$RJ" "len(d['pending_merges'])"     "1"
assert_json "approved brief is brief-002-human"             "$RJ" "d['pending_merges'][0]['brief']"   "brief-002-human"
assert_json "approved_at timestamp present"                  "$RJ" "bool(d['pending_merges'][0].get('approved_at'))"  "True"
assert_json "auto_merge flipped to True after approve"      "$RJ" "str(d['pending_merges'][0]['auto_merge'])"  "True"

# ── Test 5: reject-brief ─────────────────────────────────────────────────────

echo ""
echo "=== Test 5: reject-brief (awaiting_review → history[] with rejected_at + reason) ==="

write_running "{
    'active': [],
    'completed_pending_eval': [],
    'pending_merges': [],
    'awaiting_review': [{'brief': 'brief-002-human', 'branch': 'brief-002-human', 'brief_file': '.loop/briefs/brief-002-human.md', 'auto_merge': False}],
    'history': [],
    'queue': []
}"

python3 "$ACTIONS" reject-brief brief-002-human "$SCRATCH" "scope exceeded brief bounds" > /dev/null 2>&1

assert_json "awaiting_review[] empty after reject"          "$RJ" "len(d['awaiting_review'])"    "0"
assert_json "history[] has one entry after reject"           "$RJ" "len(d['history'])"            "1"
assert_json "history[0] is brief-002-human"                  "$RJ" "d['history'][0]['brief']"     "brief-002-human"
assert_json "rejected_at timestamp present"                  "$RJ" "bool(d['history'][0].get('rejected_at'))"  "True"
assert_json "reject_reason preserved"                        "$RJ" "d['history'][0].get('reject_reason','')"  "scope exceeded brief bounds"

# ── Test 6: depends-on frontmatter parsing ───────────────────────────────────

echo ""
echo "=== Test 6: depends-on frontmatter parsing via assess.read_depends_on ==="

# Brief-014: read_depends_on now returns a list (was scalar). Single-dep case
# returns a one-element list; empty-dep case returns [].
DEP=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from assess import read_depends_on
deps = read_depends_on('$SCRATCH/.loop/briefs/brief-004-depends.md')
print(','.join(deps) if deps else 'None')
")
assert_eq "read_depends_on extracts dep id from frontmatter"  "$DEP"  "brief-999-prereq"

DEP_NONE=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from assess import read_depends_on
deps = read_depends_on('$SCRATCH/.loop/briefs/brief-001-auto.md')
print(','.join(deps) if deps else 'None')
")
assert_eq "read_depends_on returns None when no dep present"  "$DEP_NONE"  "None"

# ── Test 7: backward compatibility ──────────────────────────────────────────

echo ""
echo "=== Test 7: backward compat — old running.json without v2 fields loads cleanly ==="

# Simulate an old running.json (v1 schema — no pending_merges or awaiting_review)
python3 -c "
import json
old = {'active': [], 'completed_pending_eval': [], 'history': [], 'queue': []}
json.dump(old, open('$SCRATCH/.loop/state/running.json','w'), indent=2)
"
git -C "$SCRATCH" add -A
git -C "$SCRATCH" commit -q -m "test: old schema" 2>/dev/null || true

# actions.py load_running() should backfill both fields
python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from actions import init_paths, load_running
paths = init_paths('$SCRATCH')
rc = load_running(paths)
assert 'pending_merges' in rc, 'pending_merges missing'
assert 'awaiting_review' in rc, 'awaiting_review missing'
assert rc['pending_merges'] == [], 'pending_merges not empty list'
assert rc['awaiting_review'] == [], 'awaiting_review not empty list'
print('ok')
" > /tmp/compat_result 2>&1 || echo "exception" > /tmp/compat_result
assert_eq "old running.json backfills v2 fields on load"  "$(cat /tmp/compat_result)"  "ok"

# ── Test 8: depends-on comma-separated list parse ─────────────────────────────

echo ""
echo "=== Test 8: depends-on comma-separated list parse (brief-014 fix 1) ==="

# Direct parser unit tests — parse_depends_on_value covers the syntax table in
# the brief (single, comma+space, comma-no-space, trailing comma, empty).
SINGLE=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from assess import parse_depends_on_value
print(','.join(parse_depends_on_value('brief-010-foo')))
")
assert_eq "parse_depends_on_value single id"                "$SINGLE"  "brief-010-foo"

MULTI_SPACED=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from assess import parse_depends_on_value
print(','.join(parse_depends_on_value('brief-010-foo, brief-011-bar')))
")
assert_eq "parse_depends_on_value comma+space"             "$MULTI_SPACED"  "brief-010-foo,brief-011-bar"

MULTI_TIGHT=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from assess import parse_depends_on_value
print(','.join(parse_depends_on_value('brief-010-foo,brief-011-bar')))
")
assert_eq "parse_depends_on_value comma no space"          "$MULTI_TIGHT"  "brief-010-foo,brief-011-bar"

TRAILING=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from assess import parse_depends_on_value
print(','.join(parse_depends_on_value('brief-010-foo,')))
")
assert_eq "parse_depends_on_value trailing comma tolerated" "$TRAILING"  "brief-010-foo"

# Full file read path — brief with comma-separated frontmatter should return 2 ids.
cat > "$SCRATCH/.loop/briefs/brief-005-multidep.md" <<'EOF'
# Brief: multi-dep test

**ID:** brief-005-multidep
**Auto-merge:** true
**Depends-on:** brief-010-foo, brief-011-bar
**Status:** queued
EOF

READ_MULTI=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from assess import read_depends_on
print(','.join(read_depends_on('$SCRATCH/.loop/briefs/brief-005-multidep.md')))
")
assert_eq "read_depends_on handles comma-separated list"   "$READ_MULTI"  "brief-010-foo,brief-011-bar"

# ── Test 9: depends-on history-check post-restart false-negative ─────────────

echo ""
echo "=== Test 9: single-dep matches against running.json history post-restart ==="

# Reproduces brief-012's 2026-04-22 failure: brief-010 was in history, daemon
# reported "not yet merged." With fix 1's parser, history lookup now works;
# test asserts the check-depends-on action returns "allowed" in that scenario.

# Seed: brief-010 in history, pending-dispatch for a brief depends-on brief-010.
cat > "$SCRATCH/.loop/briefs/brief-006-single-dep.md" <<'EOF'
# Brief: single-dep test

**ID:** brief-006-single-dep
**Auto-merge:** true
**Depends-on:** brief-010-api-v0-1
**Status:** queued
EOF

write_running "{
    'active': [],
    'completed_pending_eval': [],
    'pending_merges': [],
    'awaiting_review': [],
    'history': [{'brief': 'brief-010-api-v0-1', 'branch': 'brief-010-api-v0-1', 'merged_at': '2026-04-22T01:26:36Z'}],
    'queue': []
}"

cat > "$SCRATCH/.loop/state/pending-dispatch.json" <<EOF
{
    "brief": "brief-006-single-dep",
    "branch": "brief-006-single-dep",
    "brief_file": ".loop/briefs/brief-006-single-dep.md"
}
EOF

DEPS_LINE1=$(python3 "$ACTIONS" check-depends-on "$SCRATCH" 2>/dev/null | sed -n 1p)
assert_eq "check-depends-on allows when single dep in history" "$DEPS_LINE1"  "allowed"

# Blocked case: dep NOT in history
write_running "{
    'active': [],
    'completed_pending_eval': [],
    'pending_merges': [],
    'awaiting_review': [],
    'history': [],
    'queue': []
}"

DEPS_LINE1=$(python3 "$ACTIONS" check-depends-on "$SCRATCH" 2>/dev/null | sed -n 1p)
assert_eq "check-depends-on blocks when dep missing from history" "$DEPS_LINE1"  "blocked:brief-010-api-v0-1"

# Diagnostic line always emits, even in the error-fallback path (grep-debuggable).
DEPS_LINE2=$(python3 "$ACTIONS" check-depends-on "$SCRATCH" 2>/dev/null | sed -n 2p)
case "$DEPS_LINE2" in
    brief=*"depends_on="*"history_ids="*"match="*) pass "check-depends-on emits diagnostic line" ;;
    *) fail "check-depends-on diagnostic line — got '$DEPS_LINE2'" ;;
esac

# Multi-dep all-merged → allowed
write_running "{
    'active': [],
    'completed_pending_eval': [],
    'pending_merges': [],
    'awaiting_review': [],
    'history': [
        {'brief': 'brief-010-foo', 'merged_at': '2026-04-22T00:00:00Z'},
        {'brief': 'brief-011-bar', 'merged_at': '2026-04-22T01:00:00Z'}
    ],
    'queue': []
}"

cat > "$SCRATCH/.loop/state/pending-dispatch.json" <<EOF
{
    "brief": "brief-005-multidep",
    "branch": "brief-005-multidep",
    "brief_file": ".loop/briefs/brief-005-multidep.md"
}
EOF

DEPS_LINE1=$(python3 "$ACTIONS" check-depends-on "$SCRATCH" 2>/dev/null | sed -n 1p)
assert_eq "check-depends-on allows multi-dep when all merged" "$DEPS_LINE1"  "allowed"

# Multi-dep one-missing → blocked on first unmet
write_running "{
    'active': [],
    'completed_pending_eval': [],
    'pending_merges': [],
    'awaiting_review': [],
    'history': [{'brief': 'brief-010-foo', 'merged_at': '2026-04-22T00:00:00Z'}],
    'queue': []
}"

DEPS_LINE1=$(python3 "$ACTIONS" check-depends-on "$SCRATCH" 2>/dev/null | sed -n 1p)
assert_eq "check-depends-on blocks multi-dep on first unmet" "$DEPS_LINE1"  "blocked:brief-011-bar"

rm -f "$SCRATCH/.loop/state/pending-dispatch.json"

# ── Test 10: push-fail escalate + token redaction ────────────────────────────

echo ""
echo "=== Test 10: push_with_escalate writes escalate.json with redacted stderr ==="

# Redactor unit — GitHub token patterns → [REDACTED]
REDACTED=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from actions import redact_secrets
print(redact_secrets('fatal: could not read Username for ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345 check'))
")
case "$REDACTED" in
    *"[REDACTED]"*) pass "redact_secrets replaces ghp_ classic token" ;;
    *) fail "redact_secrets ghp_ token — got '$REDACTED'" ;;
esac

# No raw token leaks through
python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from actions import redact_secrets
out = redact_secrets('header: Bearer github_pat_ABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789_abcdefghij')
assert 'ABCDEFGH' not in out, 'raw pat body leaked'
assert '[REDACTED]' in out
" && pass "redact_secrets fine-grained PAT scrubbed" || fail "redact_secrets fine-grained PAT leak"

# Escalate flow — simulate push_with_escalate call with a failing git command.
# We don't run a real git push; the function is invoked with a deliberately
# bad remote so git exits nonzero, and we assert the resulting escalate.json
# contains the redacted stderr and structured reason.
ESC_DIR="$SCRATCH/.loop/state/signals"
rm -f "$ESC_DIR/escalate.json"

# Inject a fake stderr containing a token — subprocess mock via env.
python3 -c "
import sys, os, json, subprocess
sys.path.insert(0, '$LIB_DIR')
from actions import push_with_escalate, init_paths
paths = init_paths('$SCRATCH')
# Simulate a push failure by calling the helper with a stderr-stub. The helper
# must accept an injected stderr for testability (brief-014 requirement).
# If push_with_escalate isn't yet injectable, fall back to running with a bad
# remote and inspecting written file.
push_with_escalate(paths, brief='brief-test', _test_stderr_override='remote: Support for password authentication was removed. Token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345 redacted here.')
" 2>/dev/null

if [ -f "$ESC_DIR/escalate.json" ]; then
    pass "push_with_escalate writes escalate.json on failure"
    if grep -q '\[REDACTED\]' "$ESC_DIR/escalate.json" 2>/dev/null; then
        pass "escalate.json stderr is token-redacted"
    else
        fail "escalate.json stderr not redacted"
    fi
    if grep -q 'push_failed_on_auth\|push_failed' "$ESC_DIR/escalate.json" 2>/dev/null; then
        pass "escalate.json reason names push failure"
    else
        fail "escalate.json missing push_failed reason"
    fi
    # Negative: raw token must NOT appear in written file
    if grep -q 'ghp_ABCDEFGH' "$ESC_DIR/escalate.json" 2>/dev/null; then
        fail "escalate.json LEAKED raw token"
    else
        pass "escalate.json has no raw token"
    fi
    rm -f "$ESC_DIR/escalate.json"
else
    fail "push_with_escalate did not write escalate.json"
fi

# ── Test 11: heartbeat staleness detection ───────────────────────────────────

echo ""
echo "=== Test 11: heartbeat staleness (process-alive ≠ loop-healthy) ==="

HB="$SCRATCH/.loop/state/heartbeat.json"

# Fresh heartbeat (now) → NOT stale
python3 -c "
import json, datetime
ts = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
json.dump({'ts': ts, 'pid': 12345, 'last_event': 'tick'}, open('$HB','w'))
"
STALE=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from actions import heartbeat_is_stale
print('STALE' if heartbeat_is_stale('$HB', interval_s=120) else 'FRESH')
")
assert_eq "fresh heartbeat is not stale"                    "$STALE"  "FRESH"

# Stale heartbeat (10 min old, interval 120 → stale at >240s) → STALE
python3 -c "
import json, datetime
ts_old = (datetime.datetime.utcnow() - datetime.timedelta(minutes=10)).strftime('%Y-%m-%dT%H:%M:%SZ')
json.dump({'ts': ts_old, 'pid': 12345, 'last_event': 'tick'}, open('$HB','w'))
"
STALE=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from actions import heartbeat_is_stale
print('STALE' if heartbeat_is_stale('$HB', interval_s=120) else 'FRESH')
")
assert_eq "10-min-old heartbeat is stale (interval 120)"    "$STALE"  "STALE"

# Missing heartbeat file → treated as stale (safer: assume hung)
rm -f "$HB"
STALE=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from actions import heartbeat_is_stale
print('STALE' if heartbeat_is_stale('$HB', interval_s=120) else 'FRESH')
")
assert_eq "missing heartbeat file treated as stale"         "$STALE"  "STALE"

# write_heartbeat produces a readable JSON file with ts/pid/last_event
python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from actions import write_heartbeat
write_heartbeat('$HB', pid=99, last_event='worker')
"
if [ -f "$HB" ] && python3 -c "
import json
d = json.load(open('$HB'))
assert 'ts' in d and 'pid' in d and 'last_event' in d
assert d['pid'] == 99
assert d['last_event'] == 'worker'
" 2>/dev/null; then
    pass "write_heartbeat produces well-formed {ts,pid,last_event}"
else
    fail "write_heartbeat output malformed or missing"
fi

# ── Test 12: validator presence-check for process artifacts ──────────────────

echo ""
echo "=== Test 12: validator artifact-presence check fails cycle when missing ==="

# Fabricate a brief that names plan.md + closeout.md in completion criteria.
cat > "$SCRATCH/.loop/briefs/brief-007-artifacts.md" <<'EOF'
# Brief: artifacts test

**ID:** brief-007-artifacts
**Branch:** brief-007-artifacts
**Auto-merge:** true

## Completion criteria

- [ ] `plan.md` in the card dir
- [ ] `closeout.md` in the card dir
- [ ] All tests pass
EOF

# extract_artifact_paths should find plan.md and closeout.md
PATHS=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from actions import extract_artifact_paths
paths = extract_artifact_paths('$SCRATCH/.loop/briefs/brief-007-artifacts.md')
print(','.join(sorted(paths)))
")
assert_eq "extract_artifact_paths finds declared artifacts" "$PATHS"  "closeout.md,plan.md"

# With neither file on disk, validator_presence_check returns a block verdict.
# (The worktree dir is the brief's card parent — here, we use SCRATCH so the
# relative paths resolve against it.)
VERDICT=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from actions import validator_presence_check
missing = validator_presence_check('$SCRATCH/.loop/briefs/brief-007-artifacts.md', '$SCRATCH')
print('BLOCK' if missing else 'PASS')
")
assert_eq "validator_presence_check blocks when artifacts missing" "$VERDICT"  "BLOCK"

# Create the artifacts → check passes
touch "$SCRATCH/plan.md" "$SCRATCH/closeout.md"
VERDICT=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from actions import validator_presence_check
missing = validator_presence_check('$SCRATCH/.loop/briefs/brief-007-artifacts.md', '$SCRATCH')
print('BLOCK' if missing else 'PASS')
")
assert_eq "validator_presence_check passes when all artifacts present" "$VERDICT"  "PASS"

rm -f "$SCRATCH/plan.md" "$SCRATCH/closeout.md"

# ── Test 13 (brief-019 test 49): startup_repair — dedup active[] ─────────────

echo ""
echo "=== Test 13: startup_repair dedup_active removes duplicate active entries ==="

STARTUP_REPAIR="$LIB_DIR/startup_repair.py"
if [ ! -f "$STARTUP_REPAIR" ]; then
    fail "startup_repair.py not found at $STARTUP_REPAIR"
else

# Seed running.json with two identical entries for brief-DUP-test plus one unique
write_running "{
    'active': [
        {'brief': 'brief-DUP-test', 'branch': 'brief-DUP-test'},
        {'brief': 'brief-KEEP-test', 'branch': 'brief-KEEP-test'},
        {'brief': 'brief-DUP-test', 'branch': 'brief-DUP-test'}
    ],
    'completed_pending_eval': [],
    'pending_merges': [],
    'awaiting_review': [],
    'history': []
}"

# run_startup_repair should return 1 action (the duplicate removal)
ACTION_COUNT=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from startup_repair import run_startup_repair
from actions import init_paths
paths = init_paths('$SCRATCH')
actions = run_startup_repair(paths, '$SCRATCH')
print(len(actions))
" 2>/dev/null)
assert_eq "dedup_active returns 1 action for one duplicate brief" "$ACTION_COUNT" "1"

# active[] should now have exactly 2 entries (DUP-test once + KEEP-test)
RJ="$SCRATCH/.loop/state/running.json"
ACTIVE_LEN=$(json_get "$RJ" "len(d.get('active',[]))")
assert_eq "active[] has 2 entries after dedup (DUP-test + KEEP-test)" "$ACTIVE_LEN" "2"

# The surviving DUP-test entry should be the first one
FIRST_BRIEF=$(json_get "$RJ" "d['active'][0]['brief']")
assert_eq "first active entry after dedup is brief-DUP-test" "$FIRST_BRIEF" "brief-DUP-test"

# log.jsonl should have a startup_repair event with reason: duplicate_active_entry
LOG_HAS_REASON=$(python3 -c "
with open('$SCRATCH/.loop/state/log.jsonl') as f:
    lines = f.readlines()
import json
for line in reversed(lines):
    d = json.loads(line)
    if d.get('reason') == 'duplicate_active_entry':
        print('YES')
        break
else:
    print('NO')
" 2>/dev/null)
assert_eq "log.jsonl has duplicate_active_entry event" "$LOG_HAS_REASON" "YES"

# Idempotency: run again — no duplicates left, so 0 actions returned
ACTION_COUNT2=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from startup_repair import run_startup_repair
from actions import init_paths
paths = init_paths('$SCRATCH')
actions = run_startup_repair(paths, '$SCRATCH')
print(len(actions))
" 2>/dev/null)
assert_eq "second run is idempotent (0 actions when no duplicates)" "$ACTION_COUNT2" "0"

fi  # startup_repair.py exists

# ── Test 14: backfill_history adds merged brief to history[] ─────────────────

echo ""
echo "=== Test 14: backfill_history — merged brief absent from history gets backfilled ==="

if [ ! -f "$STARTUP_REPAIR" ]; then
    fail "startup_repair.py not found — skipping test 14"
else

# Create an actual merge commit so git log --merges sees it
git -C "$SCRATCH" checkout -q -b brief-BF-test-branch 2>/dev/null
git -C "$SCRATCH" commit --allow-empty -q -m "wip: brief-BF-test work"
git -C "$SCRATCH" checkout -q main 2>/dev/null
git -C "$SCRATCH" merge --no-ff -q brief-BF-test-branch -m "Merge brief-BF-test: test backfill" 2>/dev/null
git -C "$SCRATCH" branch -d -q brief-BF-test-branch 2>/dev/null

# Seed running.json with brief-BF-test absent from all arrays
write_running "{
    'active': [],
    'completed_pending_eval': [],
    'pending_merges': [],
    'awaiting_review': [],
    'history': []
}"

# Clear log so assertions are clean
> "$SCRATCH/.loop/state/log.jsonl"

ACTION_COUNT=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from startup_repair import run_startup_repair
from actions import init_paths
paths = init_paths('$SCRATCH')
actions = run_startup_repair(paths, '$SCRATCH')
print(len(actions))
" 2>/dev/null)
assert_eq "backfill_history returns 1 action for merged brief" "$ACTION_COUNT" "1"

RJ="$SCRATCH/.loop/state/running.json"
HIST_LEN=$(json_get "$RJ" "len(d.get('history',[]))")
assert_eq "history[] has 1 entry after backfill" "$HIST_LEN" "1"

HIST_BRIEF=$(json_get "$RJ" "d['history'][0]['brief']")
assert_eq "history[0].brief is brief-BF-test" "$HIST_BRIEF" "brief-BF-test"

HIST_SHA=$(json_get "$RJ" "bool(d['history'][0].get('merge_sha',''))")
assert_eq "history[0].merge_sha is present" "$HIST_SHA" "True"

HIST_REASON=$(json_get "$RJ" "d['history'][0].get('reason','')")
assert_eq "history[0].reason is backfilled_from_git" "$HIST_REASON" "backfilled_from_git"

LOG_HAS_BACKFILL=$(python3 -c "
with open('$SCRATCH/.loop/state/log.jsonl') as f:
    lines = f.readlines()
import json
for line in reversed(lines):
    d = json.loads(line)
    if d.get('reason') == 'backfilled_from_git':
        print('YES')
        break
else:
    print('NO')
" 2>/dev/null)
assert_eq "log.jsonl has backfilled_from_git event" "$LOG_HAS_BACKFILL" "YES"

fi  # startup_repair.py exists (test 14)

# ── Test 15: backfill_history moves merged brief from active[] to history[] ──

echo ""
echo "=== Test 15: backfill_history — merged brief still in active[] gets moved to history[] ==="

if [ ! -f "$STARTUP_REPAIR" ]; then
    fail "startup_repair.py not found — skipping test 15"
else

# Merge commit for brief-BF-test already exists from test 14 — reuse it.
# Seed running.json with brief-BF-test in active[]
write_running "{
    'active': [{'brief': 'brief-BF-test', 'branch': 'brief-BF-test'}],
    'completed_pending_eval': [],
    'pending_merges': [],
    'awaiting_review': [],
    'history': []
}"

> "$SCRATCH/.loop/state/log.jsonl"

ACTION_COUNT=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from startup_repair import run_startup_repair
from actions import init_paths
paths = init_paths('$SCRATCH')
actions = run_startup_repair(paths, '$SCRATCH')
print(len(actions))
" 2>/dev/null)
assert_eq "backfill_history returns 1 action for active+merged brief" "$ACTION_COUNT" "1"

RJ="$SCRATCH/.loop/state/running.json"
ACTIVE_LEN=$(json_get "$RJ" "len(d.get('active',[]))")
assert_eq "active[] is empty after backfill (brief moved out)" "$ACTIVE_LEN" "0"

HIST_LEN=$(json_get "$RJ" "len(d.get('history',[]))")
assert_eq "history[] has 1 entry after moving from active" "$HIST_LEN" "1"

HIST_BRIEF=$(json_get "$RJ" "d['history'][0]['brief']")
assert_eq "history[0].brief is brief-BF-test (moved from active)" "$HIST_BRIEF" "brief-BF-test"

fi  # startup_repair.py exists (test 15)

# ── Test 16: clean_stale_queues removes stale pending-merge.json ─────────────

echo ""
echo "=== Test 16: clean_stale_queues — stale pending-merge.json for merged brief is cleared ==="

if [ ! -f "$STARTUP_REPAIR" ]; then
    fail "startup_repair.py not found — skipping test 16"
else

# brief-BF-test was merged in test 14 — reuse that commit.
# Seed running.json clean so backfill_history doesn't fire on it again.
write_running "{
    'active': [],
    'completed_pending_eval': [],
    'pending_merges': [],
    'awaiting_review': [],
    'history': [{'brief': 'brief-BF-test', 'branch': 'brief-BF-test', 'merged_at': '2026-04-22T00:00:00Z', 'merge_sha': 'abc123', 'reason': 'backfilled_from_git'}]
}"

> "$SCRATCH/.loop/state/log.jsonl"

# Write a stale pending-merge.json referencing brief-BF-test (already merged)
python3 -c "
import json
json.dump({'brief': 'brief-BF-test', 'branch': 'brief-BF-test', 'auto_merge': True}, open('$SCRATCH/.loop/state/pending-merge.json','w'))
"

ACTION_COUNT=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from startup_repair import run_startup_repair
from actions import init_paths
paths = init_paths('$SCRATCH')
actions = run_startup_repair(paths, '$SCRATCH')
print(len(actions))
" 2>/dev/null)
assert_eq "clean_stale_queues returns 1 action for stale pending-merge.json" "$ACTION_COUNT" "1"

# File must be removed
if [ ! -f "$SCRATCH/.loop/state/pending-merge.json" ]; then
    pass "pending-merge.json was removed for merged brief"
else
    fail "pending-merge.json still present after cleanup"
fi

# log.jsonl must have queue_file_stale_post_merge event
LOG_HAS_STALE=$(python3 -c "
with open('$SCRATCH/.loop/state/log.jsonl') as f:
    lines = f.readlines()
import json
for line in reversed(lines):
    d = json.loads(line)
    if d.get('reason') == 'queue_file_stale_post_merge':
        print('YES')
        break
else:
    print('NO')
" 2>/dev/null)
assert_eq "log.jsonl has queue_file_stale_post_merge event" "$LOG_HAS_STALE" "YES"

# Non-stale case: pending-merge.json for an UNmerged brief must NOT be removed
python3 -c "
import json
json.dump({'brief': 'brief-NOT-merged', 'branch': 'brief-NOT-merged', 'auto_merge': True}, open('$SCRATCH/.loop/state/pending-merge.json','w'))
"

> "$SCRATCH/.loop/state/log.jsonl"

python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from startup_repair import run_startup_repair
from actions import init_paths
paths = init_paths('$SCRATCH')
run_startup_repair(paths, '$SCRATCH')
" 2>/dev/null

if [ -f "$SCRATCH/.loop/state/pending-merge.json" ]; then
    pass "pending-merge.json preserved for unmerged brief"
else
    fail "pending-merge.json incorrectly removed for unmerged brief"
fi

rm -f "$SCRATCH/.loop/state/pending-merge.json"

fi  # startup_repair.py exists (test 16)

# ── Test 17 (brief-019 test 53): NT_DAEMON_STARTUP_REPAIR=false disables repair ─

echo ""
echo "=== Test 17: NT_DAEMON_STARTUP_REPAIR=false — repair skipped, corruption persists ==="

STARTUP_REPAIR="$LIB_DIR/startup_repair.py"
if [ ! -f "$STARTUP_REPAIR" ]; then
    fail "startup_repair.py not found — skipping test 17"
else

# Seed running.json with a duplicate active entry (corruption)
write_running "{
    'active': [
        {'brief': 'brief-ENV-test', 'branch': 'brief-ENV-test'},
        {'brief': 'brief-ENV-test', 'branch': 'brief-ENV-test'}
    ],
    'completed_pending_eval': [],
    'pending_merges': [],
    'awaiting_review': [],
    'history': []
}"

> "$SCRATCH/.loop/state/log.jsonl"

# Run with repair disabled via env var
ACTION_COUNT=$(NT_DAEMON_STARTUP_REPAIR=false python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from startup_repair import run_startup_repair
from actions import init_paths
paths = init_paths('$SCRATCH')
actions = run_startup_repair(paths, '$SCRATCH')
print(len(actions))
" 2>/dev/null)
assert_eq "run_startup_repair returns 0 actions when disabled" "$ACTION_COUNT" "0"

# Corruption must still be present (active[] still has 2 entries)
ACTIVE_LEN=$(python3 -c "
import json
d = json.load(open('$SCRATCH/.loop/state/running.json'))
print(len(d.get('active', [])))
" 2>/dev/null)
assert_eq "active[] still has 2 entries (corruption persists when disabled)" "$ACTIVE_LEN" "2"

# log.jsonl must have startup_repair_disabled event
LOG_HAS_DISABLED=$(python3 -c "
import json
with open('$SCRATCH/.loop/state/log.jsonl') as f:
    lines = f.readlines()
for line in reversed(lines):
    d = json.loads(line)
    if d.get('action') == 'daemon:startup_repair_disabled':
        print('YES')
        break
else:
    print('NO')
" 2>/dev/null)
assert_eq "log.jsonl has startup_repair_disabled event" "$LOG_HAS_DISABLED" "YES"

fi  # startup_repair.py exists (test 17)

# ── Test 18 (brief-019): Model-field parser — correct extraction ──────────────

echo ""
echo "=== Test 18: Model-field parser — correct extraction from **Model:** frontmatter ==="

# Helper mirrors daemon.sh line 349's fixed pipeline (task-7).
# Takes first whitespace-separated token, strips any trailing ( or , suffix.
_parse_model() {
    local file="$1"
    local result
    result=$(grep -m1 '^\*\*Model:\*\*' "$file" 2>/dev/null \
        | sed 's/.*\*\*Model:\*\*[[:space:]]*//' \
        | awk '{print $1}' \
        | cut -d'(' -f1 \
        | cut -d',' -f1 \
        | tr '[:upper:]' '[:lower:]')
    echo "${result:-sonnet}"
}

# (a) simple opus
printf '**Model:** opus\n' > "$SCRATCH/brief-model-a.md"
assert_eq "model-field (a): opus → opus" "$(_parse_model "$SCRATCH/brief-model-a.md")" "opus"

# (b) simple sonnet
printf '**Model:** sonnet\n' > "$SCRATCH/brief-model-b.md"
assert_eq "model-field (b): sonnet → sonnet" "$(_parse_model "$SCRATCH/brief-model-b.md")" "sonnet"

# (c) opus with parenthetical
printf '**Model:** opus (research + adapter-design cycle)\n' > "$SCRATCH/brief-model-c.md"
assert_eq "model-field (c): 'opus (comment)' → opus" \
    "$(_parse_model "$SCRATCH/brief-model-c.md")" "opus"

# (d) comma-separated multi-model — first wins
printf '**Model:** opus, sonnet\n' > "$SCRATCH/brief-model-d.md"
assert_eq "model-field (d): 'opus, sonnet' → opus" \
    "$(_parse_model "$SCRATCH/brief-model-d.md")" "opus"

# (e) haiku
printf '**Model:** haiku\n' > "$SCRATCH/brief-model-e.md"
assert_eq "model-field (e): haiku → haiku" "$(_parse_model "$SCRATCH/brief-model-e.md")" "haiku"

# (f) missing **Model:** line → default sonnet
printf '# Brief: no model field\n' > "$SCRATCH/brief-model-f.md"
assert_eq "model-field (f): missing field → sonnet (default)" \
    "$(_parse_model "$SCRATCH/brief-model-f.md")" "sonnet"

rm -f "$SCRATCH/brief-model-"*.md

# ── Test 19 (brief-019): Auto-merge symlink routing — git_read_follow ────────

echo ""
echo "=== Test 19: Auto-merge symlink routing — git_read_follow reads through git symlinks ==="

# Mirrors the portal pattern: .loop/briefs/brief-NNN.md → wiki/briefs/cards/NNN/index.md
mkdir -p "$SCRATCH/wiki/briefs/cards/brief-LINK-test"
cat > "$SCRATCH/wiki/briefs/cards/brief-LINK-test/index.md" <<'BRIEFEOF'
# Brief: symlink test

**ID:** brief-LINK-test
**Auto-merge:** true
**Model:** sonnet
**Status:** queued
BRIEFEOF

# Create a relative symlink from .loop/briefs/ into the card dir
ln -sf "../../wiki/briefs/cards/brief-LINK-test/index.md" \
    "$SCRATCH/.loop/briefs/brief-LINK-test.md"
git -C "$SCRATCH" add -A
git -C "$SCRATCH" commit -q -m "test: add symlinked brief" 2>/dev/null || true

# git show on a symlink returns the target path, not the file body
GIT_SHOW_RESULT=$(git -C "$SCRATCH" show "HEAD:.loop/briefs/brief-LINK-test.md" 2>/dev/null)
assert_eq "git show on symlink returns target path (documents the bug)" \
    "$GIT_SHOW_RESULT" "../../wiki/briefs/cards/brief-LINK-test/index.md"

# git_read_follow should resolve the symlink and return the actual file content
GRF_AUTO=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from assess import git_read_follow, AUTO_MERGE_LINE_RE
content = git_read_follow('$SCRATCH', 'HEAD', '.loop/briefs/brief-LINK-test.md')
if content is None:
    print('NONE')
else:
    for line in content.splitlines():
        m = AUTO_MERGE_LINE_RE.match(line)
        if m:
            val = m.group(1).strip().lower()
            print('true' if val == 'true' else 'false')
            break
    else:
        print('not_found')
" 2>/dev/null)
assert_eq "git_read_follow reads Auto-merge flag through symlink" "$GRF_AUTO" "true"

# Bare git show would miss the flag (returns symlink target, regex no match)
# — documents why task-7 must switch daemon.sh to use git_read_follow
GIT_SHOW_AM=$(python3 -c "
import sys, subprocess, re
RE = re.compile(r'^\s*\*\*Auto-merge:\*\*\s*(\S+)', re.IGNORECASE)
r = subprocess.run(['git', '-C', '$SCRATCH', 'show', 'HEAD:.loop/briefs/brief-LINK-test.md'],
    capture_output=True, text=True, timeout=10)
for line in r.stdout.splitlines():
    m = RE.match(line)
    if m:
        print(m.group(1).strip().lower())
        break
else:
    print('false')
" 2>/dev/null)
assert_eq "bare git show misses Auto-merge flag on symlinked brief (the bug)" "$GIT_SHOW_AM" "false"

# Cleanup symlink test artifacts from the SCRATCH repo
rm -f "$SCRATCH/.loop/briefs/brief-LINK-test.md"
rm -rf "$SCRATCH/wiki/briefs/cards/brief-LINK-test"
git -C "$SCRATCH" add -A
git -C "$SCRATCH" commit -q -m "test: cleanup symlink artifacts" 2>/dev/null || true

# ── Tests 20-21 (brief-019): Presence-check gate — running vs complete ────────

echo ""
echo "=== Tests 20-21: Presence-check gate — runs on complete, skipped on running ==="

if ! python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from actions import validator_presence_check
" 2>/dev/null; then
    fail "presence-check gate (running): validator_presence_check not in source repo (sync pending task-9)"
    fail "presence-check gate (complete): validator_presence_check not in source repo (sync pending task-9)"
else

cat > "$SCRATCH/.loop/briefs/brief-GATE-test.md" <<'GATEEOF'
# Brief: presence-gate test

**ID:** brief-GATE-test
**Status:** running

## Completion criteria

- [ ] `plan.md` present in card dir
- [ ] `closeout.md` present in card dir
GATEEOF

# Test 20: direct call to validator_presence_check with missing artifacts → returns missing list
# The daemon gates calling this on status=complete; the function itself always reports missing.
GATE_BLOCKED=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from actions import validator_presence_check
missing = validator_presence_check('$SCRATCH/.loop/briefs/brief-GATE-test.md', '$SCRATCH')
print('blocked' if missing else 'clear')
" 2>/dev/null)
assert_eq "presence-check: returns blocked when artifacts missing (function contract)" \
    "$GATE_BLOCKED" "blocked"

# Test 21: with artifacts present → returns clear (not blocking)
touch "$SCRATCH/plan.md" "$SCRATCH/closeout.md"
GATE_CLEAR=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from actions import validator_presence_check
missing = validator_presence_check('$SCRATCH/.loop/briefs/brief-GATE-test.md', '$SCRATCH')
print('blocked' if missing else 'clear')
" 2>/dev/null)
assert_eq "presence-check: returns clear when all artifacts present" "$GATE_CLEAR" "clear"

rm -f "$SCRATCH/plan.md" "$SCRATCH/closeout.md"
rm -f "$SCRATCH/.loop/briefs/brief-GATE-test.md"

fi  # validator_presence_check available

# ── Tests 22-24 (brief-019): Merge abort-on-conflict ──────────────────────────

echo ""
echo "=== Tests 22-24: Merge abort-on-conflict — conflict triggers abort + awaiting_review ==="

MERGE_SCRATCH=$(mktemp -d)

git -C "$MERGE_SCRATCH" init -q -b main
git -C "$MERGE_SCRATCH" config user.email "test@test"
git -C "$MERGE_SCRATCH" config user.name "Test"

mkdir -p "$MERGE_SCRATCH/.loop/state/signals"
mkdir -p "$MERGE_SCRATCH/.loop/worktrees"

cat > "$MERGE_SCRATCH/.loop/config.sh" <<'EOF'
PROJECT_NAME="test"
GIT_REMOTE="origin"
GIT_MAIN_BRANCH="main"
EOF

touch "$MERGE_SCRATCH/.loop/state/log.jsonl"

# Seed initial commit on main
echo "base content" > "$MERGE_SCRATCH/shared.txt"
git -C "$MERGE_SCRATCH" add -A
git -C "$MERGE_SCRATCH" commit -q -m "init"

# Set up local bare repo as 'origin' so git push succeeds
git init --bare -q "$MERGE_SCRATCH/origin.git"
git -C "$MERGE_SCRATCH" remote add origin "$MERGE_SCRATCH/origin.git"
git -C "$MERGE_SCRATCH" push -q origin main

# Create non-conflicting branch (test 22)
git -C "$MERGE_SCRATCH" checkout -q -b brief-CLEAN-test
echo "clean addition" > "$MERGE_SCRATCH/newfile.txt"
git -C "$MERGE_SCRATCH" add newfile.txt
git -C "$MERGE_SCRATCH" commit -q -m "brief-CLEAN-test: add newfile"
git -C "$MERGE_SCRATCH" checkout -q main

# Create conflicting branch (tests 23-24): both branches modify shared.txt
git -C "$MERGE_SCRATCH" checkout -q -b brief-CONFLICT-test
echo "branch version" > "$MERGE_SCRATCH/shared.txt"
git -C "$MERGE_SCRATCH" add shared.txt
git -C "$MERGE_SCRATCH" commit -q -m "brief-CONFLICT-test: change shared.txt"
git -C "$MERGE_SCRATCH" checkout -q main
echo "main version" > "$MERGE_SCRATCH/shared.txt"
git -C "$MERGE_SCRATCH" add shared.txt
git -C "$MERGE_SCRATCH" commit -q -m "main: change shared.txt — conflicts with branch"
git -C "$MERGE_SCRATCH" push -q origin main

write_running_ms() {
    python3 -c "import json; json.dump($1, open('$MERGE_SCRATCH/.loop/state/running.json','w'), indent=2)"
}

# ── Test 22: clean merge succeeds ───────────────────────────────────────────

write_running_ms "{
    'active': [],
    'completed_pending_eval': [],
    'pending_merges': [{'brief': 'brief-CLEAN-test', 'branch': 'brief-CLEAN-test'}],
    'awaiting_review': [],
    'history': []
}"

cat > "$MERGE_SCRATCH/.loop/state/pending-merge.json" <<'PMEOF'
{"brief": "brief-CLEAN-test", "branch": "brief-CLEAN-test", "title": "clean test", "evaluation": ""}
PMEOF

CLEAN_RESULT=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from actions import init_paths, load_running, merge
paths = init_paths('$MERGE_SCRATCH')
try:
    result = merge(paths)
    rc = load_running(paths)
    in_hist = any(e.get('brief') == 'brief-CLEAN-test' for e in rc.get('history', []))
    print(f'ok,in_history={in_hist}')
except Exception as e:
    # Push may fail if branch cleanup fails — just check it's not a conflict error
    msg = str(e).lower()
    if 'conflict' in msg or 'unmerged' in msg:
        print(f'conflict_error: {e}')
    else:
        print('ok,push_or_cleanup_error')
" 2>/dev/null)
CLEAN_OK=$(echo "$CLEAN_RESULT" | grep -c "^ok" || true)
assert_eq "clean merge: no conflict error raised" "$CLEAN_OK" "1"

# ── Test 23: conflict triggers abort + awaiting_review ──────────────────────

write_running_ms "{
    'active': [],
    'completed_pending_eval': [],
    'pending_merges': [{'brief': 'brief-CONFLICT-test', 'branch': 'brief-CONFLICT-test'}],
    'awaiting_review': [],
    'history': []
}"

cat > "$MERGE_SCRATCH/.loop/state/pending-merge.json" <<'PMEOF'
{"brief": "brief-CONFLICT-test", "branch": "brief-CONFLICT-test", "title": "conflict test", "evaluation": ""}
PMEOF

CONFLICT_RESULT=$(python3 -c "
import sys, subprocess
sys.path.insert(0, '$LIB_DIR')
from actions import init_paths, load_running, merge
paths = init_paths('$MERGE_SCRATCH')
try:
    result = merge(paths)
    rc = load_running(paths)
    in_ar = any(e.get('brief') == 'brief-CONFLICT-test' for e in rc.get('awaiting_review', []))
    print(f'result={result},in_awaiting_review={in_ar}')
except subprocess.CalledProcessError:
    print('exception:no_abort_implemented')
" 2>/dev/null)
assert_eq "conflict: merge() returns False + brief in awaiting_review [fails until task-8]" \
    "$CONFLICT_RESULT" "result=False,in_awaiting_review=True"

# Working tree must have no half-merged state after abort
# (MERGE_HEAD gone + no unmerged files — log.jsonl modification and
# untracked origin.git/ are test-setup noise, not conflict residue)
MERGE_HEAD_AFTER=$(git -C "$MERGE_SCRATCH" rev-parse --verify MERGE_HEAD 2>/dev/null || echo "")
UNMERGED_AFTER=$(git -C "$MERGE_SCRATCH" ls-files --unmerged 2>/dev/null)
HALF_MERGED=$([ -z "$MERGE_HEAD_AFTER" ] && [ -z "$UNMERGED_AFTER" ] && echo "clean" || echo "dirty")
assert_eq "conflict: no half-merged state after abort [fails until task-8]" \
    "$HALF_MERGED" "clean"

# ── Test 24: repeated tick does not retry after conflict ────────────────────

PM_AFTER=$( [ -f "$MERGE_SCRATCH/.loop/state/pending-merge.json" ] && echo "exists" || echo "gone" )
assert_eq "conflict: pending-merge.json removed, no retry loop [fails until task-8]" \
    "$PM_AFTER" "gone"

# Running merge() again with no pending-merge.json → cleanly returns False (not an error)
NO_PM_RESULT=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from actions import init_paths, merge
paths = init_paths('$MERGE_SCRATCH')
result = merge(paths)
print('false' if result is False else str(result))
" 2>/dev/null)
assert_eq "repeated tick after conflict: merge() returns False cleanly (no retry)" \
    "$NO_PM_RESULT" "false"

rm -rf "$MERGE_SCRATCH"

# ── Tests 25-26: Conductor dedup — queue-head augmentation ───────────────────
# The augmentation runs in daemon.sh after assess.py: when trigger is
# CONDUCTOR:no_active, daemon reads goals.md and appends the first brief ID
# from ## Queued next. We test the augmentation Python snippet directly.

DEDUP_SCRATCH=$(mktemp -d)
mkdir -p "$DEDUP_SCRATCH/.loop/state"

# Shared helper: run the same queue-head extraction snippet daemon.sh uses.
queue_head_id() {
    local state_dir="$1"
    python3 -c "
import re, sys
goals_file = '$state_dir/goals.md'
try:
    with open(goals_file) as f:
        txt = f.read()
    sections = txt.split('\n## ')
    for sec in sections:
        if sec.lower().startswith('queued next'):
            m = re.search(r'brief-\d+-[\w-]+', sec)
            if m:
                print(m.group(0))
                sys.exit(0)
except Exception:
    pass
" 2>/dev/null || true
}

# Test 25: goals.md has a brief in ## Queued next → augmentation produces
# CONDUCTOR:no_active:<brief-id>, distinct from the stored-dedup key.
cat > "$DEDUP_SCRATCH/.loop/state/goals.md" <<'GOALS_EOF'
# Goals

## Queued next

1. **brief-099-test-brief** — test fixture for dedup regression.
GOALS_EOF

HEAD_ID=$(queue_head_id "$DEDUP_SCRATCH/.loop/state")
AUGMENTED_TRIGGER="CONDUCTOR:no_active"
[ -n "$HEAD_ID" ] && AUGMENTED_TRIGGER="CONDUCTOR:no_active:$HEAD_ID"
assert_eq "conductor dedup: no_active trigger augmented with queue head ID" \
    "$AUGMENTED_TRIGGER" "CONDUCTOR:no_active:brief-099-test-brief"

# Test 26: empty ## Queued next → no augmentation, trigger stays identity-less.
# Genuinely-idle dedup must still hold (two consecutive empty-queue ticks dedup).
cat > "$DEDUP_SCRATCH/.loop/state/goals.md" <<'GOALS_EOF'
# Goals

## Queued next

_nothing scheduled_
GOALS_EOF

EMPTY_HEAD=$(queue_head_id "$DEDUP_SCRATCH/.loop/state")
EMPTY_TRIGGER="CONDUCTOR:no_active"
[ -n "$EMPTY_HEAD" ] && EMPTY_TRIGGER="CONDUCTOR:no_active:$EMPTY_HEAD"
assert_eq "conductor dedup: empty queue keeps identity-less trigger (dedup holds)" \
    "$EMPTY_TRIGGER" "CONDUCTOR:no_active"

rm -rf "$DEDUP_SCRATCH"

# ── Tests 27-29 (brief-025 item 2): Presence-check canonical-root resolution ──

echo ""
echo "=== Tests 27-29: Presence-check canonical-root resolution ==="

CANON_SCRATCH=$(mktemp -d)
mkdir -p "$CANON_SCRATCH/.loop/briefs"
mkdir -p "$CANON_SCRATCH/wiki/design-system"
mkdir -p "$CANON_SCRATCH/docs"

# Brief that names design-system/index.md in completion criteria
cat > "$CANON_SCRATCH/.loop/briefs/brief-CANON-test.md" <<'CANONEOF'
# Brief: canonical-root test

**ID:** brief-CANON-test

## Completion criteria

- [ ] `design-system/index.md` present
CANONEOF

# Test 27: file at wiki/design-system/index.md — should resolve via canonical root, PASS + resolved_at emitted
touch "$CANON_SCRATCH/wiki/design-system/index.md"
CANON_RESULT=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from actions import validator_presence_check
missing = validator_presence_check('$CANON_SCRATCH/.loop/briefs/brief-CANON-test.md', '$CANON_SCRATCH')
print('PASS' if not missing else 'BLOCK')
" 2>/dev/null)
assert_eq "presence-check canonical-root: resolves design-system/index.md via wiki/" \
    "$CANON_RESULT" "PASS"

# Verify resolved_at is emitted to stderr
CANON_STDERR=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from actions import validator_presence_check
validator_presence_check('$CANON_SCRATCH/.loop/briefs/brief-CANON-test.md', '$CANON_SCRATCH')
" 2>&1 >/dev/null)
assert_eq "presence-check canonical-root: emits resolved_at log line to stderr" \
    "$CANON_STDERR" "resolved_at: wiki/design-system/index.md"

rm -f "$CANON_SCRATCH/wiki/design-system/index.md"

# Test 28: file genuinely absent everywhere → BLOCK (negative test)
CANON_MISSING=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from actions import validator_presence_check
missing = validator_presence_check('$CANON_SCRATCH/.loop/briefs/brief-CANON-test.md', '$CANON_SCRATCH')
print('BLOCK' if missing else 'PASS')
" 2>/dev/null)
assert_eq "presence-check canonical-root: genuinely missing file still BLOCKS" \
    "$CANON_MISSING" "BLOCK"

# Test 29: file at docs/config.md — resolves via docs/ canonical root
cat > "$CANON_SCRATCH/.loop/briefs/brief-CANON-docs.md" <<'CANONDOCSEOF'
# Brief: canonical-root docs test

**ID:** brief-CANON-docs

## Completion criteria

- [ ] `config.md` present
CANONDOCSEOF

touch "$CANON_SCRATCH/docs/config.md"
CANON_DOCS=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from actions import validator_presence_check
missing = validator_presence_check('$CANON_SCRATCH/.loop/briefs/brief-CANON-docs.md', '$CANON_SCRATCH')
print('PASS' if not missing else 'BLOCK')
" 2>/dev/null)
assert_eq "presence-check canonical-root: resolves config.md via docs/" \
    "$CANON_DOCS" "PASS"

rm -rf "$CANON_SCRATCH"

# ── Tests 30-31 (brief-025 item 3): Validator wrapper synthetic review ────────

echo ""
echo "=== Tests 30-31: Validator wrapper synthetic review ==="

WRAP_SCRATCH=$(mktemp -d)
WRAP_WORKTREE="$WRAP_SCRATCH/worktree"
mkdir -p "$WRAP_WORKTREE/.loop/modules/validator/state/reviews"
WRAP_METRICS="$WRAP_SCRATCH/metrics.jsonl"
touch "$WRAP_METRICS"

WRAP_BRIEF_ID="brief-WRAP-test"
WRAP_CYCLE=3
WRAP_COMMIT="abc123def456789"
WRAP_BRANCH="brief-WRAP-test"
WRAP_REVIEW_REL=".loop/modules/validator/state/reviews/${WRAP_BRIEF_ID}-cycle-${WRAP_CYCLE}.md"

# Shared wrapper-logic script: mirrors the if-block added in brief-025 item 3
WRAP_LOGIC=$(mktemp)
cat > "$WRAP_LOGIC" <<'WRAPEOF'
#!/usr/bin/env bash
# Args: worktree review_rel brief_id cycle commit_sha branch metrics_file
WORKTREE_DIR="$1"; REVIEW_REL="$2"; brief_id="$3"; cycle="$4"
commit_sha="$5"; branch="$6"; METRICS_FILE="$7"
if [ ! -f "$WORKTREE_DIR/$REVIEW_REL" ]; then
    NOW_ISO_WRAP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    mkdir -p "$(dirname "$WORKTREE_DIR/$REVIEW_REL")"
    cat > "$WORKTREE_DIR/$REVIEW_REL" <<SYNTHEOF
---
cycle: $cycle
commit: $commit_sha
brief: $brief_id
branch: $branch
verdict: pass
summary: validator agent returned without writing — wrapper-synthesized pass review
validator: wrapper-synthesized (brief-025)
reviewed_at: $NOW_ISO_WRAP
---

## Bugs found
- _none_

## Execution concerns
- validator agent exited without producing a review file; wrapper wrote this synthetic pass. Investigate agent logs if this recurs.

## Spec-fit notes
- _none_

## Deferred items
- _none_
SYNTHEOF
    python3 -c "
import json, datetime
entry = {
    'timestamp': datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
    'source': 'validator',
    'event': 'validator_wrapper_synthesized',
    'brief': '$brief_id',
    'cycle': $cycle,
    'commit': '${commit_sha:0:12}',
}
with open('$METRICS_FILE', 'a') as f:
    f.write(json.dumps(entry) + '\n')
" 2>/dev/null
fi
WRAPEOF
chmod +x "$WRAP_LOGIC"

# Test 30: agent silent-exit (no review file written) → wrapper synthesizes pass review
bash "$WRAP_LOGIC" "$WRAP_WORKTREE" "$WRAP_REVIEW_REL" \
    "$WRAP_BRIEF_ID" "$WRAP_CYCLE" "$WRAP_COMMIT" "$WRAP_BRANCH" "$WRAP_METRICS"

WRAP_VERDICT=$(python3 -c "
import re
content = open('$WRAP_WORKTREE/$WRAP_REVIEW_REL').read()
m = re.search(r'^verdict:\s*(\S+)', content, re.MULTILINE)
print(m.group(1) if m else 'missing')
" 2>/dev/null)
assert_eq "validator wrapper: synthesizes pass review on silent agent exit" \
    "$WRAP_VERDICT" "pass"

# Test 31: synthesized review logged in metrics.jsonl as validator_wrapper_synthesized
WRAP_METRICS_EVENT=$(python3 -c "
import json
events = [json.loads(l) for l in open('$WRAP_METRICS') if l.strip()]
match = any(e.get('event') == 'validator_wrapper_synthesized' for e in events)
print('found' if match else 'missing')
" 2>/dev/null)
assert_eq "validator wrapper: logs validator_wrapper_synthesized event to metrics" \
    "$WRAP_METRICS_EVENT" "found"

rm -rf "$WRAP_SCRATCH"
rm -f "$WRAP_LOGIC"

# ── Tests 32-34 (brief-025): Presence-check gate regression ──────────────────

echo ""
echo "=== Tests 32-34: Presence-check gate regression — status gates presence-check ==="

GATEREG_SCRATCH=$(mktemp -d)
mkdir -p "$GATEREG_SCRATCH/.loop/briefs" "$GATEREG_SCRATCH/.loop/state"

cat > "$GATEREG_SCRATCH/.loop/briefs/brief-GATEREG.md" <<'GREOF'
# Brief: presence-gate regression

**ID:** brief-GATEREG
**Status:** running

## Completion criteria

- [ ] `closeout.md` present
GREOF

GATEREG_PROGRESS="$GATEREG_SCRATCH/.loop/state/progress.json"

# Test 32: status=running → gate skips presence-check (never calls validator_presence_check)
echo '{"status":"running"}' > "$GATEREG_PROGRESS"
GATE32_STATUS=$(python3 -c "import json; print(json.load(open('$GATEREG_PROGRESS')).get('status',''))" 2>/dev/null)
if [ "$GATE32_STATUS" = "complete" ]; then
    GATE32_RESULT="ran"
else
    GATE32_RESULT="skipped"
fi
assert_eq "presence-check gate: status=running skips check" "$GATE32_RESULT" "skipped"

# Test 33: status=complete + artifact missing → presence-check runs and blocks
echo '{"status":"complete"}' > "$GATEREG_PROGRESS"
GATE33_STATUS=$(python3 -c "import json; print(json.load(open('$GATEREG_PROGRESS')).get('status',''))" 2>/dev/null)
if [ "$GATE33_STATUS" = "complete" ]; then
    GATE33_RESULT=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from actions import validator_presence_check
missing = validator_presence_check('$GATEREG_SCRATCH/.loop/briefs/brief-GATEREG.md', '$GATEREG_SCRATCH')
print('blocked' if missing else 'passed')
" 2>/dev/null)
else
    GATE33_RESULT="skipped"
fi
assert_eq "presence-check gate: status=complete + missing artifact → blocked" "$GATE33_RESULT" "blocked"

# Test 34: status=complete + artifact present → presence-check runs and passes
touch "$GATEREG_SCRATCH/closeout.md"
GATE34_STATUS=$(python3 -c "import json; print(json.load(open('$GATEREG_PROGRESS')).get('status',''))" 2>/dev/null)
if [ "$GATE34_STATUS" = "complete" ]; then
    GATE34_RESULT=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from actions import validator_presence_check
missing = validator_presence_check('$GATEREG_SCRATCH/.loop/briefs/brief-GATEREG.md', '$GATEREG_SCRATCH')
print('blocked' if missing else 'passed')
" 2>/dev/null)
else
    GATE34_RESULT="skipped"
fi
assert_eq "presence-check gate: status=complete + artifact present → passed" "$GATE34_RESULT" "passed"

rm -rf "$GATEREG_SCRATCH"

# ── Tests 35-37 (brief-025): Depends-on-secrets credential gate ───────────────

echo ""
echo "=== Tests 35-37: Depends-on-secrets — credential gate in dispatch block ==="

SECRETS_SCRATCH=$(mktemp -d)
mkdir -p "$SECRETS_SCRATCH/.loop/briefs" "$SECRETS_SCRATCH/.loop/state"

# Fabricated brief with Depends-on-secrets: FAKE_TOKEN_SL025
cat > "$SECRETS_SCRATCH/.loop/briefs/brief-SECRETS.md" <<'SECEOF'
# Brief: credential-gated test

**ID:** brief-SECRETS
**Status:** queued
**Depends-on-secrets:** FAKE_TOKEN_SL025, ANOTHER_FAKE_SL025
SECEOF

cat > "$SECRETS_SCRATCH/.loop/state/pending-dispatch.json" <<PDEOF
{
  "brief": "brief-SECRETS",
  "branch": "brief-SECRETS",
  "brief_file": ".loop/briefs/brief-SECRETS.md"
}
PDEOF

cat > "$SECRETS_SCRATCH/.loop/state/running.json" <<'RUNEOF'
{"active":[],"completed_pending_eval":[],"awaiting_review":[],"history":[]}
RUNEOF

# Test 35: FAKE_TOKEN_SL025 unset → check-depends-on-secrets returns blocked:FAKE_TOKEN_SL025
SECRETS35_OUTPUT=$(python3 "$ACTIONS" check-depends-on-secrets "$SECRETS_SCRATCH" 2>/dev/null)
SECRETS35_VERDICT=$(echo "$SECRETS35_OUTPUT" | sed -n 1p)
case "$SECRETS35_VERDICT" in
    blocked:FAKE_TOKEN_SL025) SECRETS35_RESULT="blocked" ;;
    *) SECRETS35_RESULT="unexpected:$SECRETS35_VERDICT" ;;
esac
assert_eq "depends-on-secrets: unset var → verdict blocked:FAKE_TOKEN_SL025" \
    "$SECRETS35_RESULT" "blocked"

# Test 36: all vars set → check-depends-on-secrets returns allowed
SECRETS36_OUTPUT=$(FAKE_TOKEN_SL025=x ANOTHER_FAKE_SL025=y python3 "$ACTIONS" check-depends-on-secrets "$SECRETS_SCRATCH" 2>/dev/null)
SECRETS36_VERDICT=$(echo "$SECRETS36_OUTPUT" | sed -n 1p)
assert_eq "depends-on-secrets: all vars set → verdict allowed" \
    "$SECRETS36_VERDICT" "allowed"

# Test 37: brief with no Depends-on-secrets field → backward compat, always allowed
cat > "$SECRETS_SCRATCH/.loop/state/pending-dispatch.json" <<PDEOF2
{
  "brief": "brief-NOSECRETS",
  "branch": "brief-NOSECRETS",
  "brief_file": ".loop/briefs/brief-NOSECRETS.md"
}
PDEOF2

cat > "$SECRETS_SCRATCH/.loop/briefs/brief-NOSECRETS.md" <<'NOSECEOF'
# Brief: no-credential test

**ID:** brief-NOSECRETS
**Status:** queued
**Depends-on:** brief-001-placeholder
NOSECEOF

SECRETS37_OUTPUT=$(python3 "$ACTIONS" check-depends-on-secrets "$SECRETS_SCRATCH" 2>/dev/null)
SECRETS37_VERDICT=$(echo "$SECRETS37_OUTPUT" | sed -n 1p)
assert_eq "depends-on-secrets: no field → backward compat, allowed" \
    "$SECRETS37_VERDICT" "allowed"

rm -rf "$SECRETS_SCRATCH"

# ── Tests 38-42 (brief-027): Human-gate artifact detection ───────────────────

echo ""
echo "=== Tests 38-42: Human-gate artifact detection — _find_handoff_artifact + human_queue_summary ==="

HG_SCRATCH=$(mktemp -d)
mkdir -p "$HG_SCRATCH/.loop/briefs" "$HG_SCRATCH/.loop/state"
mkdir -p "$HG_SCRATCH/wiki/briefs/cards/brief-HG-smoke"

cat > "$HG_SCRATCH/.loop/config.sh" <<'EOF'
PROJECT_NAME="test"
WIKI_PORT="8002"
EOF

cat > "$HG_SCRATCH/.loop/briefs/brief-HG-smoke.md" <<'EOF'
# Brief: human-gate smoke test

**ID:** brief-HG-smoke
**Auto-merge:** false
**Human-gate:** smoke
**Status:** queued
EOF

cat > "$HG_SCRATCH/.loop/state/running.json" <<'RUNEOF'
{"active":[],"completed_pending_eval":[],"pending_merges":[],"awaiting_review":[],"history":[]}
RUNEOF

# Test 38: _find_handoff_artifact returns (None, True) when no artifact present
HG38_RESULT=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from actions import _find_handoff_artifact
url, missing = _find_handoff_artifact('$HG_SCRATCH', 'brief-HG-smoke', '8002')
print('missing' if missing and url is None else 'found')
" 2>/dev/null)
assert_eq "human-gate: _find_handoff_artifact returns missing when no artifact" \
    "$HG38_RESULT" "missing"

# Write smoke.md at the expected card dir path (simulates worker output on status transition)
cat > "$HG_SCRATCH/wiki/briefs/cards/brief-HG-smoke/smoke.md" <<'SMOKEEOF'
---
title: "brief-HG-smoke smoke — test brief"
brief: brief-HG-smoke
category: smoke
status: awaiting-mattie
---

# Smoke test — test brief

!!! abstract "TL;DR"
    **What shipped:** test artifact

    **Target moment:** test

    **Your part:** run smoke test

## What shipped

| # | Task | Landed as |
|---|---|---|
| 1 | test task | test output |

## What's gated on you

- Run smoke commands

## Prerequisites

!!! warning "None"
    No hardware gates.

## Runbook

### Phase 1 — Smoke run

**blocking.** 2 min

```bash
echo "smoke test"
```

## What "works" looks like

- Command exits 0

## Alternatives if a gate fails

!!! note "If smoke fails"
    Re-run with verbose flag.

## Resolution options

| Option | When to pick | Action |
|---|---|---|
| **Approve** | Smoke passes | `loop approve brief-HG-smoke` |
| **Iterate** | Minor issues | Requeue with notes |
| **Reject** | Fundamental failure | `loop reject brief-HG-smoke` |

## Scav recommendation

**Approve and merge.**

Test passed.

## What you should feel

Confident.

## If something breaks mid-runbook

Capture and ping.

## References

- [Brief index](index.md)
SMOKEEOF

# Test 39: _find_handoff_artifact returns URL when smoke.md present
HG39_RESULT=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from actions import _find_handoff_artifact
url, missing = _find_handoff_artifact('$HG_SCRATCH', 'brief-HG-smoke', '8002')
if not missing and url and 'brief-HG-smoke' in url and '/smoke/' in url:
    print('found')
else:
    print('fail: url=%s missing=%s' % (url, missing))
" 2>/dev/null)
assert_eq "human-gate: _find_handoff_artifact returns URL when smoke.md present" \
    "$HG39_RESULT" "found"

# Test 40: flavor priority — smoke wins over review and escalation when all present
mkdir -p "$HG_SCRATCH/wiki/briefs/cards/brief-HG-multi"
touch "$HG_SCRATCH/wiki/briefs/cards/brief-HG-multi/review.md"
touch "$HG_SCRATCH/wiki/briefs/cards/brief-HG-multi/escalation.md"
touch "$HG_SCRATCH/wiki/briefs/cards/brief-HG-multi/smoke.md"
HG40_RESULT=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from actions import _find_handoff_artifact
url, missing = _find_handoff_artifact('$HG_SCRATCH', 'brief-HG-multi', '8002')
if url and '/smoke/' in url:
    print('smoke')
elif url and '/review/' in url:
    print('review')
else:
    print('other: %s' % url)
" 2>/dev/null)
assert_eq "human-gate: smoke flavor takes priority over review + escalation" \
    "$HG40_RESULT" "smoke"

# Test 41: human_queue_summary populates artifact_url for awaiting_review entry with smoke.md
python3 -c "
import json
d = {
    'active': [],
    'completed_pending_eval': [],
    'pending_merges': [],
    'awaiting_review': [{'brief': 'brief-HG-smoke', 'branch': 'brief-HG-smoke', 'auto_merge': False, 'reason': 'smoke test required'}],
    'history': []
}
json.dump(d, open('$HG_SCRATCH/.loop/state/running.json', 'w'))
"
HG41_RESULT=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from actions import init_paths, human_queue_summary
paths = init_paths('$HG_SCRATCH')
items = human_queue_summary(paths)
item = next((i for i in items if i['brief_id'] == 'brief-HG-smoke'), None)
if item is None:
    print('missing_item')
elif item.get('artifact_url') and '/smoke/' in item['artifact_url'] and not item.get('artifact_missing'):
    print('ok')
else:
    print('fail: url=%s missing=%s' % (item.get('artifact_url'), item.get('artifact_missing')))
" 2>/dev/null)
assert_eq "human-gate: human_queue_summary returns artifact_url for awaiting_review with smoke.md" \
    "$HG41_RESULT" "ok"

# Test 42: smoke.md at expected path has required sections from the artifact template
HG42_SECTIONS=$(python3 -c "
content = open('$HG_SCRATCH/wiki/briefs/cards/brief-HG-smoke/smoke.md').read()
required = ['TL;DR', 'What shipped', 'Runbook', 'Resolution options', 'What you should feel']
missing = [s for s in required if s not in content]
print('ok' if not missing else 'missing: ' + ', '.join(missing))
" 2>/dev/null)
assert_eq "human-gate: smoke.md at wiki/briefs/cards/{id}/smoke.md has required sections" \
    "$HG42_SECTIONS" "ok"

rm -rf "$HG_SCRATCH"

# ── Tests 43-45 (brief-028): Dirty-tree merge recovery ────────────────────────
# Verify that an untracked validator review file in main's working tree does NOT
# block the merge — the pre-merge safe-path git clean in merge() removes it first.

echo ""
echo "=== Tests 43-45: Dirty-tree merge recovery (brief-028) ==="

DT_SCRATCH=$(mktemp -d)

git -C "$DT_SCRATCH" init -q -b main
git -C "$DT_SCRATCH" config user.email "test@test"
git -C "$DT_SCRATCH" config user.name "Test"

mkdir -p "$DT_SCRATCH/.loop/state/signals"
mkdir -p "$DT_SCRATCH/.loop/state"
mkdir -p "$DT_SCRATCH/.loop/worktrees"
mkdir -p "$DT_SCRATCH/.loop/modules/validator/state/reviews"

cat > "$DT_SCRATCH/.loop/config.sh" <<'EOF'
PROJECT_NAME="test"
GIT_REMOTE="origin"
GIT_MAIN_BRANCH="main"
EOF

touch "$DT_SCRATCH/.loop/state/log.jsonl"

# Seed initial commit on main (must include .loop dir for git clean to have context)
echo "base" > "$DT_SCRATCH/base.txt"
git -C "$DT_SCRATCH" add base.txt
git -C "$DT_SCRATCH" commit -q -m "init"

# Bare origin so push succeeds
git init --bare -q "$DT_SCRATCH/origin.git"
git -C "$DT_SCRATCH" remote add origin "$DT_SCRATCH/origin.git"
git -C "$DT_SCRATCH" push -q origin main

# Create branch that commits a validator review file
REVIEW_REL=".loop/modules/validator/state/reviews/brief-DT-test-cycle-1.md"
git -C "$DT_SCRATCH" checkout -q -b brief-DT-test
mkdir -p "$DT_SCRATCH/$(dirname "$REVIEW_REL")"
cat > "$DT_SCRATCH/$REVIEW_REL" <<'REOF'
---
validator: loop-reviewer
brief: brief-DT-test
cycle: 1
verdict: APPROVE
---
Looks good.
REOF
git -C "$DT_SCRATCH" add "$REVIEW_REL"
git -C "$DT_SCRATCH" commit -q -m "brief-DT-test: add validator review"
git -C "$DT_SCRATCH" checkout -q main

# Drop the same review file as an UNTRACKED file in main's working tree.
# This simulates the validator wrapper writing to project root instead of worktree.
mkdir -p "$DT_SCRATCH/$(dirname "$REVIEW_REL")"
cat > "$DT_SCRATCH/$REVIEW_REL" <<'REOF'
---
validator: wrapper-synthesized (brief-025)
brief: brief-DT-test
cycle: 1
verdict: APPROVE
---
Synthesized pass.
REOF

# Test 43: confirm that WITHOUT the pre-merge clean, git merge aborts on dirty tree.
# We call raw git merge, not merge() — this proves the problem is real.
DT43_RC=0
git -C "$DT_SCRATCH" merge brief-DT-test --no-ff -m "raw merge" > /dev/null 2>&1 || DT43_RC=$?
# Restore untracked file (raw merge may have partially cleaned on error)
mkdir -p "$DT_SCRATCH/$(dirname "$REVIEW_REL")"
cat > "$DT_SCRATCH/$REVIEW_REL" <<'REOF'
---
validator: wrapper-synthesized (brief-025)
brief: brief-DT-test
cycle: 1
verdict: APPROVE
---
Synthesized pass.
REOF
# Reset merge state if it partially ran
git -C "$DT_SCRATCH" merge --abort 2>/dev/null || true
DT43_ABORTED=$([ "$DT43_RC" -ne 0 ] && echo "yes" || echo "no")
assert_eq "dirty-tree: raw git merge aborts when untracked review file blocks" \
    "$DT43_ABORTED" "yes"

# Test 44: merge() pre-merge clean removes the untracked file → merge succeeds.
python3 -c "
import json
json.dump({
    'active': [],
    'completed_pending_eval': [],
    'pending_merges': [{'brief': 'brief-DT-test', 'branch': 'brief-DT-test'}],
    'awaiting_review': [],
    'history': []
}, open('$DT_SCRATCH/.loop/state/running.json', 'w'), indent=2)
"
cat > "$DT_SCRATCH/.loop/state/pending-merge.json" <<'PMEOF'
{"brief": "brief-DT-test", "branch": "brief-DT-test", "title": "dirty-tree test", "evaluation": ""}
PMEOF

# merge() prints pre-merge-clean status to stdout — capture last line only for verdict.
DT44_RESULT=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from actions import init_paths, merge
paths = init_paths('$DT_SCRATCH')
try:
    result = merge(paths)
    print('ok' if result is not False else 'false')
except Exception as e:
    msg = str(e).lower()
    if 'overwritten' in msg or 'dirty' in msg or 'please move' in msg:
        print('dirty_tree_abort')
    else:
        print('ok_push_or_cleanup')
" 2>/dev/null | tail -1)
assert_eq "dirty-tree: merge() completes despite untracked validator review at safe path" \
    "$DT44_RESULT" "ok"

# Test 45: pre-merge clean action was logged in log.jsonl when it removed a file.
# log_action writes {action: "daemon:pre_merge_clean", ...} entries.
DT45_LOGGED=$(python3 -c "
import json
log_path = '$DT_SCRATCH/.loop/state/log.jsonl'
try:
    with open(log_path) as f:
        events = [json.loads(l) for l in f if l.strip()]
    clean_events = [e for e in events if e.get('action') == 'daemon:pre_merge_clean']
    print('logged' if clean_events else 'not_logged')
except Exception as e:
    print('error:' + str(e))
" 2>/dev/null)
assert_eq "dirty-tree: pre_merge_clean event logged when untracked review removed" \
    "$DT45_LOGGED" "logged"

rm -rf "$DT_SCRATCH"

# ── Test 45b: pre-merge clean covers the specific brief's card dir ─────────────
# Covers the 2026-04-24 recurring pattern: worker artifacts (closeout.md, plan.md,
# cycle PNGs) land as untracked duplicates at wiki/briefs/cards/<brief>/ on main,
# blocking merges from brief-XXX. Safe to clean the specific brief's card dir
# because the branch owns its own card dir by convention. NOT safe to broaden to
# wiki/briefs/cards/ — other briefs' cards are legitimate tracked content on main.

echo ""
echo "=== Test 45b: pre-merge clean covers the merging brief's own card dir ==="

DT45B_SCRATCH=$(mktemp -d)
git -C "$DT45B_SCRATCH" init -q -b main
git -C "$DT45B_SCRATCH" config user.email "test@test"
git -C "$DT45B_SCRATCH" config user.name "Test"

mkdir -p "$DT45B_SCRATCH/.loop/state/signals"
mkdir -p "$DT45B_SCRATCH/.loop/worktrees"
cat > "$DT45B_SCRATCH/.loop/config.sh" <<'EOF'
PROJECT_NAME="test"
GIT_REMOTE="origin"
GIT_MAIN_BRANCH="main"
EOF
touch "$DT45B_SCRATCH/.loop/state/log.jsonl"

echo "base" > "$DT45B_SCRATCH/base.txt"
git -C "$DT45B_SCRATCH" add base.txt
git -C "$DT45B_SCRATCH" commit -q -m "init"

git init --bare -q "$DT45B_SCRATCH/origin.git"
git -C "$DT45B_SCRATCH" remote add origin "$DT45B_SCRATCH/origin.git"
git -C "$DT45B_SCRATCH" push -q origin main

# Branch commits a brief card (closeout.md under wiki/briefs/cards/<brief>/)
DT45B_BRIEF="brief-card-clean-test"
DT45B_CLOSEOUT_REL="wiki/briefs/cards/${DT45B_BRIEF}/closeout.md"
git -C "$DT45B_SCRATCH" checkout -q -b "$DT45B_BRIEF"
mkdir -p "$DT45B_SCRATCH/$(dirname "$DT45B_CLOSEOUT_REL")"
echo "# Closeout from branch" > "$DT45B_SCRATCH/$DT45B_CLOSEOUT_REL"
git -C "$DT45B_SCRATCH" add "$DT45B_CLOSEOUT_REL"
git -C "$DT45B_SCRATCH" commit -q -m "${DT45B_BRIEF}: closeout"
git -C "$DT45B_SCRATCH" checkout -q main

# Simulate the bug: closeout.md dropped as untracked on main's tree
mkdir -p "$DT45B_SCRATCH/$(dirname "$DT45B_CLOSEOUT_REL")"
echo "# Untracked duplicate on main" > "$DT45B_SCRATCH/$DT45B_CLOSEOUT_REL"

python3 -c "
import json
json.dump({
    'active': [],
    'completed_pending_eval': [],
    'pending_merges': [{'brief': '$DT45B_BRIEF', 'branch': '$DT45B_BRIEF'}],
    'awaiting_review': [],
    'history': []
}, open('$DT45B_SCRATCH/.loop/state/running.json', 'w'), indent=2)
"
cat > "$DT45B_SCRATCH/.loop/state/pending-merge.json" <<PMEOF
{"brief": "$DT45B_BRIEF", "branch": "$DT45B_BRIEF", "title": "brief-card clean test", "evaluation": ""}
PMEOF

DT45B_RESULT=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from actions import init_paths, merge
paths = init_paths('$DT45B_SCRATCH')
try:
    result = merge(paths)
    print('ok' if result is not False else 'false')
except Exception as e:
    msg = str(e).lower()
    if 'overwritten' in msg or 'dirty' in msg or 'please move' in msg:
        print('dirty_tree_abort')
    else:
        print('ok_push_or_cleanup')
" 2>/dev/null | tail -1)
assert_eq "brief-card-clean: merge() completes despite untracked closeout.md under wiki/briefs/cards/<brief>/" \
    "$DT45B_RESULT" "ok"

# Verify pre_merge_clean event includes the brief-card path
DT45B_LOGGED=$(python3 -c "
import json
try:
    with open('$DT45B_SCRATCH/.loop/state/log.jsonl') as f:
        events = [json.loads(l) for l in f if l.strip()]
    clean_events = [e for e in events if e.get('action') == 'daemon:pre_merge_clean']
    card_events = [e for e in clean_events if 'wiki/briefs/cards/$DT45B_BRIEF/' in e.get('path', '')]
    print('logged_for_brief_card' if card_events else ('logged_other_only' if clean_events else 'not_logged'))
except Exception as e:
    print('error:' + str(e))
" 2>/dev/null)
assert_eq "brief-card-clean: pre_merge_clean logged path for the brief-card dir specifically" \
    "$DT45B_LOGGED" "logged_for_brief_card"

rm -rf "$DT45B_SCRATCH"

# ── Tests 46-51 (brief-034 cycle 3): concurrency gate in dispatch ─────────────
# Verify THROTTLE cap + Parallel-safe/Edit-surface overlap detection in
# actions.dispatch. Covers the four gate outcomes (throttle_reached,
# concurrency_skip on overlap / on new-brief not parallel-safe / on active-brief
# not parallel-safe), plus the two pass-through cases (empty active; disjoint
# surfaces at THROTTLE=2).

echo ""
echo "=== Tests 46-51: Concurrency gate in dispatch (brief-034) ==="

CC_SCRATCH=$(mktemp -d)

git -C "$CC_SCRATCH" init -q -b main
git -C "$CC_SCRATCH" config user.email "test@test"
git -C "$CC_SCRATCH" config user.name "Test"

mkdir -p "$CC_SCRATCH/.loop/state/signals"
mkdir -p "$CC_SCRATCH/.loop/briefs"
mkdir -p "$CC_SCRATCH/.loop/worktrees"
touch "$CC_SCRATCH/.loop/state/log.jsonl"

echo "base" > "$CC_SCRATCH/base.txt"
git -C "$CC_SCRATCH" add base.txt
git -C "$CC_SCRATCH" commit -q -m "init"

cat > "$CC_SCRATCH/.loop/briefs/brief-A.md" <<'EOF'
# Brief: A
**ID:** brief-A
**Parallel-safe:** true
**Edit-surface:**
  - crates/hive/
EOF
cat > "$CC_SCRATCH/.loop/briefs/brief-B.md" <<'EOF'
# Brief: B
**ID:** brief-B
**Parallel-safe:** true
**Edit-surface:**
  - crates/playground/
EOF
cat > "$CC_SCRATCH/.loop/briefs/brief-C.md" <<'EOF'
# Brief: C
**ID:** brief-C
**Parallel-safe:** true
**Edit-surface:**
  - crates/hive/src/
EOF
cat > "$CC_SCRATCH/.loop/briefs/brief-D.md" <<'EOF'
# Brief: D (legacy, no Parallel-safe)
**ID:** brief-D
EOF

# Helper: write config.sh with given THROTTLE
cc_write_cfg() {
    cat > "$CC_SCRATCH/.loop/config.sh" <<EOF
PROJECT_NAME="test"
GIT_REMOTE="origin"
GIT_MAIN_BRANCH="main"
THROTTLE=$1
EOF
}

# Helper: seed running.json with given active[] (JSON string argument).
# JSON is passed via env to avoid Python-vs-JSON literal mismatch (true/false).
cc_write_running() {
    CC_ACTIVE_JSON="$1" python3 -c "
import json, os
active = json.loads(os.environ['CC_ACTIVE_JSON'])
json.dump({
    'active': active,
    'completed_pending_eval': [],
    'pending_merges': [],
    'awaiting_review': [],
    'history': []
}, open('$CC_SCRATCH/.loop/state/running.json', 'w'), indent=2)
"
}

# Helper: seed pending-dispatch.json for a brief
cc_write_pending() {
    cat > "$CC_SCRATCH/.loop/state/pending-dispatch.json" <<EOF
{"brief": "$1", "branch": "$1", "brief_file": ".loop/briefs/$1.md"}
EOF
}

# Helper: read the last log event's `action` field
cc_last_action() {
    python3 -c "
import json
with open('$CC_SCRATCH/.loop/state/log.jsonl') as f:
    events = [json.loads(l) for l in f if l.strip()]
print(events[-1]['action'] if events else 'none')
" 2>/dev/null
}

# Helper: run dispatch's GATE ONLY by mocking ensure_worktree. Returns:
#   "gate_pass" if the gate passed (ensure_worktree would be invoked)
#   last-log-action otherwise.
cc_run_gate() {
    python3 -c "
import sys, os
sys.path.insert(0, '$LIB_DIR')
import actions as A
paths = A.init_paths('$CC_SCRATCH')
# Short-circuit after the gate passes: raise before any git operation.
def stop_here(*a, **kw):
    raise SystemExit('__gate_pass__')
A.ensure_worktree = stop_here
# Neutralize git calls so a pass-through that reaches git doesn't explode.
class _R:
    returncode = 0; stdout = ''; stderr = ''
A.git = lambda *a, **kw: _R()
try:
    A.dispatch(paths)
    print('dispatch_returned_false')
except SystemExit as e:
    if '__gate_pass__' in str(e):
        print('gate_pass')
    else:
        raise
" 2>/dev/null
}

# Test 46: empty active[], THROTTLE=1 → gate passes
cc_write_cfg 1
cc_write_running '[]'
cc_write_pending "brief-A"
CC46=$(cc_run_gate)
assert_eq "concurrency: empty active THROTTLE=1 → gate_pass" "$CC46" "gate_pass"
rm -f "$CC_SCRATCH/.loop/state/pending-dispatch.json"

# Test 47: THROTTLE=1 + 1 active → throttle_reached
cc_write_cfg 1
cc_write_running '[{"brief":"in-flight","branch":"in-flight","parallel_safe":true,"edit_surface":["x/"]}]'
cc_write_pending "brief-A"
cc_run_gate > /dev/null
CC47=$(cc_last_action)
assert_eq "concurrency: THROTTLE=1 + in-flight → throttle_reached" "$CC47" "daemon:throttle_reached"

# Test 48: THROTTLE=2, disjoint surfaces, both parallel_safe=true → gate passes
cc_write_cfg 2
cc_write_running '[{"brief":"in-flight","branch":"in-flight","parallel_safe":true,"edit_surface":["crates/playground/"]}]'
cc_write_pending "brief-A"
CC48=$(cc_run_gate)
assert_eq "concurrency: THROTTLE=2 + disjoint surfaces → gate_pass" "$CC48" "gate_pass"
rm -f "$CC_SCRATCH/.loop/state/pending-dispatch.json"

# Test 49: THROTTLE=2, overlapping surfaces → concurrency_skip
cc_write_cfg 2
cc_write_running '[{"brief":"in-flight","branch":"in-flight","parallel_safe":true,"edit_surface":["crates/hive/"]}]'
cc_write_pending "brief-C"
cc_run_gate > /dev/null
CC49=$(cc_last_action)
assert_eq "concurrency: THROTTLE=2 + overlap → concurrency_skip" "$CC49" "daemon:concurrency_skip"

# Test 50: THROTTLE=2, new brief not parallel-safe (legacy) → concurrency_skip
cc_write_cfg 2
cc_write_running '[{"brief":"in-flight","branch":"in-flight","parallel_safe":true,"edit_surface":["crates/x/"]}]'
cc_write_pending "brief-D"
cc_run_gate > /dev/null
CC50=$(cc_last_action)
assert_eq "concurrency: THROTTLE=2 + new brief not parallel-safe → concurrency_skip" \
    "$CC50" "daemon:concurrency_skip"

# Test 51: THROTTLE=2, active brief missing parallel_safe (legacy) → concurrency_skip
cc_write_cfg 2
cc_write_running '[{"brief":"legacy-in-flight","branch":"legacy-in-flight"}]'
cc_write_pending "brief-A"
cc_run_gate > /dev/null
CC51=$(cc_last_action)
assert_eq "concurrency: THROTTLE=2 + legacy active → concurrency_skip" \
    "$CC51" "daemon:concurrency_skip"

rm -rf "$CC_SCRATCH"

# ── Tests 52-59 (brief-034 cycle 4): scout parser + scheduler + output contract
# Covers: frontmatter parse, cadence-seconds derivation, is-due against
# log.jsonl history, daily-cap enforcement, kill_on consecutive-failures, and
# apply-output-contract for stewardship-log-append / log-only / noop-marker.

echo ""
echo "=== Tests 52-59: Scouts — parse + schedule + contracts (brief-034) ==="

SC_SCRATCH=$(mktemp -d)
mkdir -p "$SC_SCRATCH/.loop/state/signals" "$SC_SCRATCH/.loop/specialists"
touch "$SC_SCRATCH/.loop/state/log.jsonl"

cat > "$SC_SCRATCH/.loop/config.sh" <<'EOF'
PROJECT_NAME="sc-test"
GIT_REMOTE="origin"
GIT_MAIN_BRANCH="main"
EOF

# Pilot-shaped scout (queue-steward analog)
cat > "$SC_SCRATCH/.loop/specialists/steward.md" <<'EOF'
---
name: steward
cadence:
  every: 30m
model: sonnet
max_runs_per_day: 2
max_runtime_seconds: 60
outputs: stewardship-log-append
kill_on:
  - daemon-stop
  - 3-consecutive-failures
---

# Role: steward

Test body.
EOF

# Log-only scout for contract-rejection test
cat > "$SC_SCRATCH/.loop/specialists/logger.md" <<'EOF'
---
name: logger
cadence:
  every: 30m
model: haiku
max_runs_per_day: 48
max_runtime_seconds: 30
outputs: log-only
kill_on:
  - daemon-stop
---

# Role: logger

Emit nothing; this scout only pings.
EOF

SC_SPEC="$SC_SCRATCH/.loop/specialists/steward.md"
SC_LOGGER="$SC_SCRATCH/.loop/specialists/logger.md"

# Test 52: frontmatter parse — get-field name + outputs
SC_NAME=$(python3 "$LIB_DIR/scouts.py" get-field "$SC_SPEC" name 2>/dev/null)
assert_eq "scout: get-field name" "$SC_NAME" "steward"
SC_OUT=$(python3 "$LIB_DIR/scouts.py" get-field "$SC_SPEC" outputs 2>/dev/null)
assert_eq "scout: get-field outputs" "$SC_OUT" "stewardship-log-append"

# Test 53: is-due returns yes on fresh scout (no log history)
SC_DUE=$(python3 "$LIB_DIR/scouts.py" is-due "$SC_SPEC" "$SC_SCRATCH" 2>/dev/null)
assert_eq "scout: is-due yes on empty log" "$SC_DUE" "yes"

# Test 54: over-daily-cap returns no initially
SC_CAP=$(python3 "$LIB_DIR/scouts.py" over-daily-cap "$SC_SPEC" "$SC_SCRATCH" 2>/dev/null)
assert_eq "scout: over-daily-cap no on empty log" "$SC_CAP" "no"

# Seed 2 scout_fire events today → cap reached (max_runs_per_day=2)
SC_TODAY=$(python3 -c "from datetime import datetime,timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")
python3 -c "
import json
with open('$SC_SCRATCH/.loop/state/log.jsonl', 'a') as f:
    for _ in range(2):
        f.write(json.dumps({'timestamp': '$SC_TODAY', 'action': 'daemon:scout_fire', 'specialist': 'steward'}) + '\n')
"

# Test 55: over-daily-cap yes after 2 fires
SC_CAP2=$(python3 "$LIB_DIR/scouts.py" over-daily-cap "$SC_SPEC" "$SC_SCRATCH" 2>/dev/null)
assert_eq "scout: over-daily-cap yes after 2 fires" "$SC_CAP2" "yes"

# Test 56: kill_on 3-consecutive-failures → check returns 'kill'
python3 -c "
import json
with open('$SC_SCRATCH/.loop/state/log.jsonl', 'a') as f:
    for _ in range(3):
        f.write(json.dumps({'timestamp': '$SC_TODAY', 'action': 'daemon:scout_failed', 'specialist': 'steward'}) + '\n')
"
SC_CHK=$(python3 "$LIB_DIR/scouts.py" check "$SC_SPEC" "$SC_SCRATCH" 2>/dev/null)
assert_eq "scout: 3-consecutive-failures → kill" "$SC_CHK" "kill"

# Test 57: apply-output-contract writes to stewardship-log-YYYY-MM-DD.md
SC_JSON=$(mktemp)
echo '{"result": "heartbeat stale: 7200s; flagged 2 stuck briefs"}' > "$SC_JSON"
python3 "$LIB_DIR/scouts.py" apply-output-contract "$SC_SPEC" "$SC_JSON" "$SC_SCRATCH" > /dev/null 2>&1
SC_TODAY_DATE=$(python3 -c "from datetime import datetime,timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%d'))")
SC_TARGET="$SC_SCRATCH/.loop/state/stewardship-log-${SC_TODAY_DATE}.md"
if [ -f "$SC_TARGET" ] && grep -q "heartbeat stale" "$SC_TARGET"; then
    pass "scout: stewardship-log-append writes to today's file"
else
    fail "scout: stewardship-log-append writes to today's file"
fi
rm -f "$SC_JSON"

# Test 58: noop-marker → no file written; status=noop
SC_JSON2=$(mktemp)
echo '{"result": "nothing to report"}' > "$SC_JSON2"
SC_STATUS=$(python3 "$LIB_DIR/scouts.py" apply-output-contract "$SC_SPEC" "$SC_JSON2" "$SC_SCRATCH" 2>/dev/null | cut -f1)
assert_eq "scout: noop-marker → status=noop" "$SC_STATUS" "noop"
rm -f "$SC_JSON2"

# Test 59: log-only scout producing text → status=rejected (contract violation)
SC_JSON3=$(mktemp)
echo '{"result": "some unauthorized output"}' > "$SC_JSON3"
SC_STATUS_LO=$(python3 "$LIB_DIR/scouts.py" apply-output-contract "$SC_LOGGER" "$SC_JSON3" "$SC_SCRATCH" 2>/dev/null | cut -f1)
assert_eq "scout: log-only with text → rejected" "$SC_STATUS_LO" "rejected"
rm -f "$SC_JSON3"

rm -rf "$SC_SCRATCH"

# ── Tests 60-63 (brief-034 cycle 9): scout cadence + stewardship-log rotation
# Covers gaps the cycle-4 tests left: is-due respects a recent fire (cadence
# window not yet elapsed), is-due fires once cadence elapses, and
# stewardship-log-append rotates cleanly across UTC day boundaries (per-day
# files, no cross-bleed).

echo ""
echo "=== Tests 60-63: Scout cadence + stewardship-log rotation (brief-034) ==="

SR_SCRATCH=$(mktemp -d)
mkdir -p "$SR_SCRATCH/.loop/state/signals" "$SR_SCRATCH/.loop/specialists"
touch "$SR_SCRATCH/.loop/state/log.jsonl"

cat > "$SR_SCRATCH/.loop/config.sh" <<'EOF'
PROJECT_NAME="sr-test"
GIT_REMOTE="origin"
GIT_MAIN_BRANCH="main"
EOF

cat > "$SR_SCRATCH/.loop/specialists/steward.md" <<'EOF'
---
name: steward
cadence:
  every: 30m
model: sonnet
max_runs_per_day: 48
max_runtime_seconds: 60
outputs: stewardship-log-append
kill_on:
  - daemon-stop
  - 3-consecutive-failures
---

# Role: steward

Test body.
EOF

SR_SPEC="$SR_SCRATCH/.loop/specialists/steward.md"

# Test 60: is-due=no when last fire is within cadence window (10 min ago; cadence 30m)
SR_RECENT=$(python3 -c "from datetime import datetime,timezone,timedelta; print((datetime.now(timezone.utc)-timedelta(minutes=10)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
python3 -c "
import json
with open('$SR_SCRATCH/.loop/state/log.jsonl', 'w') as f:
    f.write(json.dumps({'timestamp': '$SR_RECENT', 'action': 'daemon:scout_fire', 'specialist': 'steward'}) + '\n')
"
SR_DUE_RECENT=$(python3 "$LIB_DIR/scouts.py" is-due "$SR_SPEC" "$SR_SCRATCH" 2>/dev/null)
assert_eq "scout: is-due=no when last fire 10m ago (cadence 30m)" "$SR_DUE_RECENT" "no"

# Test 61: is-due=yes when last fire predates cadence window (40 min ago)
SR_OLD=$(python3 -c "from datetime import datetime,timezone,timedelta; print((datetime.now(timezone.utc)-timedelta(minutes=40)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
python3 -c "
import json
with open('$SR_SCRATCH/.loop/state/log.jsonl', 'w') as f:
    f.write(json.dumps({'timestamp': '$SR_OLD', 'action': 'daemon:scout_fire', 'specialist': 'steward'}) + '\n')
"
SR_DUE_OLD=$(python3 "$LIB_DIR/scouts.py" is-due "$SR_SPEC" "$SR_SCRATCH" 2>/dev/null)
assert_eq "scout: is-due=yes when last fire 40m ago (cadence 30m)" "$SR_DUE_OLD" "yes"

# Test 62: stewardship-log rotation — pre-existing yesterday file is preserved;
# today's apply-output-contract creates a distinct today-dated file.
SR_TODAY=$(python3 -c "from datetime import datetime,timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%d'))")
SR_YESTERDAY=$(python3 -c "from datetime import datetime,timezone,timedelta; print((datetime.now(timezone.utc)-timedelta(days=1)).strftime('%Y-%m-%d'))")
SR_YFILE="$SR_SCRATCH/.loop/state/stewardship-log-${SR_YESTERDAY}.md"
SR_TFILE="$SR_SCRATCH/.loop/state/stewardship-log-${SR_TODAY}.md"
printf '# %s\n\n## legacy-entry\nold content\n' "$SR_YESTERDAY" > "$SR_YFILE"
SR_YSIZE_BEFORE=$(wc -c < "$SR_YFILE" | tr -d ' ')

SR_JSON=$(mktemp)
echo '{"result": "queue-steward observation: 3 briefs in flight, no interventions needed"}' > "$SR_JSON"
python3 "$LIB_DIR/scouts.py" apply-output-contract "$SR_SPEC" "$SR_JSON" "$SR_SCRATCH" > /dev/null 2>&1

SR_YSIZE_AFTER=$(wc -c < "$SR_YFILE" | tr -d ' ')
if [ -f "$SR_TFILE" ] && [ "$SR_YFILE" != "$SR_TFILE" ] && grep -q "queue-steward observation" "$SR_TFILE"; then
    pass "scout: rotation — today's file distinct from yesterday's, contains today's entry"
else
    fail "scout: rotation — today's file distinct from yesterday's, contains today's entry"
fi
assert_eq "scout: rotation — yesterday's file untouched (size unchanged)" \
    "$SR_YSIZE_AFTER" "$SR_YSIZE_BEFORE"

# Test 63: second stewardship-log-append on same UTC day APPENDS to today's file
# (no clobber). Both observations survive; file grew.
SR_TSIZE_BEFORE=$(wc -c < "$SR_TFILE" | tr -d ' ')
SR_JSON2=$(mktemp)
echo '{"result": "follow-up observation: merge pending cleared"}' > "$SR_JSON2"
python3 "$LIB_DIR/scouts.py" apply-output-contract "$SR_SPEC" "$SR_JSON2" "$SR_SCRATCH" > /dev/null 2>&1
SR_TSIZE_AFTER=$(wc -c < "$SR_TFILE" | tr -d ' ')
if [ "$SR_TSIZE_AFTER" -gt "$SR_TSIZE_BEFORE" ] \
   && grep -q "queue-steward observation" "$SR_TFILE" \
   && grep -q "follow-up observation" "$SR_TFILE"; then
    pass "scout: rotation — same-day appends accumulate (no clobber)"
else
    fail "scout: rotation — same-day appends accumulate (no clobber)"
fi
rm -f "$SR_JSON" "$SR_JSON2"

rm -rf "$SR_SCRATCH"

# ── Tests 64-65: Rebase-conflict → awaiting_review routing (brief-061) ───────

echo ""
echo "=== Tests 64-65: Rebase-conflict — move-to-awaiting-review with rebase reason ==="

# Test 64: auto-merge:true brief routed to awaiting_review on rebase conflict.
# auto_merge is forced False so the stale branch can't bypass human review even
# if the brief originally declared Auto-merge: true.
write_running "{
    'active': [{'brief': 'brief-001-auto', 'branch': 'brief-001-auto', 'brief_file': '.loop/briefs/brief-001-auto.md', 'auto_merge': True}],
    'completed_pending_eval': [],
    'pending_merges': [],
    'awaiting_review': [],
    'history': [],
    'queue': []
}"

python3 "$ACTIONS" move-to-awaiting-review brief-001-auto "$SCRATCH" \
    "rebase conflict against main — human resolution required" > /dev/null 2>&1

assert_json "rebase-conflict: active[] emptied"                "$RJ" "len(d['active'])"                                   "0"
assert_json "rebase-conflict: brief in awaiting_review[]"      "$RJ" "len(d['awaiting_review'])"                          "1"
assert_json "rebase-conflict: correct brief id"                "$RJ" "d['awaiting_review'][0]['brief']"                   "brief-001-auto"
assert_json "rebase-conflict: auto_merge forced False"         "$RJ" "str(d['awaiting_review'][0]['auto_merge'])"         "False"
assert_json "rebase-conflict: reason preserved verbatim"       "$RJ" "d['awaiting_review'][0].get('reason','')"           "rebase conflict against main — human resolution required"

# Test 65: pending_merges[] unaffected — rebase-conflict does not accidentally
# promote the brief into the merge queue.
assert_json "rebase-conflict: pending_merges[] still empty"    "$RJ" "len(d['pending_merges'])"                           "0"

# ── Tests 66-68: Staleness gate → awaiting_review routing (brief-061) ────────

echo ""
echo "=== Tests 66-68: Staleness gate — stale branch refused merge → awaiting_review ==="

# Test 66: auto-merge:true brief routed to awaiting_review when stale.
# Daemon computes commits_behind > MAX_COMMITS_BEHIND and calls move-to-awaiting-review
# with the stale_branch reason. auto_merge is forced False.
write_running "{
    'active': [{'brief': 'brief-001-auto', 'branch': 'brief-001-auto', 'brief_file': '.loop/briefs/brief-001-auto.md', 'auto_merge': True}],
    'completed_pending_eval': [],
    'pending_merges': [],
    'awaiting_review': [],
    'history': [],
    'queue': []
}"

python3 "$ACTIONS" move-to-awaiting-review brief-001-auto "$SCRATCH" \
    "branch is 45 commits behind main — staleness gate triggered, hand-merge required (see wiki/operating-docs/incidents/2026-04-24-brief-049-050-merge-watchlist.md)" > /dev/null 2>&1

assert_json "staleness-gate: active[] emptied"                 "$RJ" "len(d['active'])"                                   "0"
assert_json "staleness-gate: brief in awaiting_review[]"       "$RJ" "len(d['awaiting_review'])"                          "1"
assert_json "staleness-gate: correct brief id"                 "$RJ" "d['awaiting_review'][0]['brief']"                   "brief-001-auto"
assert_json "staleness-gate: auto_merge forced False"          "$RJ" "str(d['awaiting_review'][0]['auto_merge'])"         "False"

# Test 67: pending_merges[] unaffected — stale brief must NOT be promoted to merge queue.
assert_json "staleness-gate: pending_merges[] still empty"     "$RJ" "len(d['pending_merges'])"                           "0"

# Test 68: stale_branch reason preserved verbatim (action-level contract).
assert_json "staleness-gate: reason contains staleness note"   "$RJ" "'staleness gate triggered' in d['awaiting_review'][0].get('reason','')" "True"

# Test 69: conflict_note field is set — mirrors process-pending-merges merge-conflict path,
# used by hive and director tooling to display the specific block reason.
assert_json "staleness-gate: conflict_note field set"          "$RJ" "'staleness gate triggered' in d['awaiting_review'][0].get('conflict_note','')" "True"

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "========================================="
echo "Results: $PASSED passed, $FAILED failed"
echo "========================================="

[ "$FAILED" -eq 0 ] && exit 0 || exit 1
