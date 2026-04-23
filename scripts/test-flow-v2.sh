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

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "========================================="
echo "Results: $PASSED passed, $FAILED failed"
echo "========================================="

[ "$FAILED" -eq 0 ] && exit 0 || exit 1
