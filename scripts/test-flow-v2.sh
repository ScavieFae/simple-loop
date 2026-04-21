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

DEP=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from assess import read_depends_on
print(read_depends_on('$SCRATCH/.loop/briefs/brief-004-depends.md') or 'None')
")
assert_eq "read_depends_on extracts dep id from frontmatter"  "$DEP"  "brief-999-prereq"

DEP_NONE=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from assess import read_depends_on
print(read_depends_on('$SCRATCH/.loop/briefs/brief-001-auto.md') or 'None')
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

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "========================================="
echo "Results: $PASSED passed, $FAILED failed"
echo "========================================="

[ "$FAILED" -eq 0 ] && exit 0 || exit 1
