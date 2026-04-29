#!/usr/bin/env bash
# scripts/test-launchd-restart.sh — Verify launchd restarts the daemon after kill.
#
# Tests:
#   1. LaunchAgent is loaded and the daemon is running.
#   2. Killing the daemon process causes launchd to restart it within ThrottleInterval + epsilon.
#   3. The restarted daemon has a new PID (confirms it's a fresh process, not the same one).
#
# Requirements:
#   - loop install-service has been run in the current project directory.
#   - Run from the project root (the directory containing .loop/).
#
# Usage:
#   cd /path/to/your/project
#   ~/claude-projects/simple-loop/scripts/test-launchd-restart.sh
#
# Exits 0 if all checks pass, 1 otherwise.

set -uo pipefail

THROTTLE_INTERVAL=30
EPSILON=10
WAIT_SECS=$((THROTTLE_INTERVAL + EPSILON))

PASSED=0
FAILED=0

pass() { echo "  PASS  $1"; PASSED=$((PASSED + 1)); }
fail() { echo "  FAIL  $1 — $2"; FAILED=$((FAILED + 1)); }

# ── Prereqs ───────────────────────────────────────────────────────────────────

if [ ! -d ".loop" ]; then
    echo "ERROR: No .loop/ directory found. Run from your project root." >&2
    exit 1
fi

PROJECT_NAME="$(basename "$PWD")"
LABEL="com.scaviefae.simpleloop.${PROJECT_NAME}"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"

if [ ! -f "$PLIST" ]; then
    echo "ERROR: LaunchAgent plist not found at $PLIST" >&2
    echo "Run: loop install-service" >&2
    exit 1
fi

echo ""
echo "=== LaunchAgent restart test ==="
echo "Project: $PROJECT_NAME"
echo "Label:   $LABEL"
echo ""

# ── Check 1: agent is loaded ──────────────────────────────────────────────────

echo "--- Check 1: LaunchAgent is loaded ---"

la_status="$(launchctl list "$LABEL" 2>/dev/null)"
if [ -z "$la_status" ]; then
    fail "agent loaded" "launchctl list returned empty — is the LaunchAgent installed and loaded?"
    echo ""
    echo "Try: loop install-service"
    exit 1
fi
pass "agent loaded"

# ── Check 2: daemon is running (has a PID) ────────────────────────────────────

echo ""
echo "--- Check 2: daemon is running ---"

initial_pid="$(launchctl list "$LABEL" 2>/dev/null | awk 'NR==2 {print $1}')"

if [ -z "$initial_pid" ] || [ "$initial_pid" = "-" ] || [ "$initial_pid" = "0" ]; then
    fail "daemon running" "PID column is '$initial_pid' — daemon is not currently running"
    echo ""
    echo "Hint: Check loop logs -f for why the daemon may have exited."
    exit 1
fi
pass "daemon running (PID=$initial_pid)"

# ── Check 3: kill and verify restart ─────────────────────────────────────────

echo ""
echo "--- Check 3: kill PID=$initial_pid, wait up to ${WAIT_SECS}s for launchd restart ---"

kill "$initial_pid" 2>/dev/null
echo "Sent SIGTERM to PID $initial_pid"

new_pid=""
elapsed=0
sleep_interval=2

while [ $elapsed -lt $WAIT_SECS ]; do
    sleep $sleep_interval
    elapsed=$((elapsed + sleep_interval))

    candidate="$(launchctl list "$LABEL" 2>/dev/null | awk 'NR==2 {print $1}')"
    if [ -n "$candidate" ] && [ "$candidate" != "-" ] && [ "$candidate" != "0" ] && [ "$candidate" != "$initial_pid" ]; then
        new_pid="$candidate"
        break
    fi
done

if [ -z "$new_pid" ]; then
    fail "daemon restarted" "No new PID appeared within ${WAIT_SECS}s (original PID was $initial_pid)"
else
    pass "daemon restarted (new PID=$new_pid, ${elapsed}s after kill)"
fi

# ── Check 4: new PID is distinct ─────────────────────────────────────────────

echo ""
echo "--- Check 4: new PID is distinct from killed PID ---"

if [ -n "$new_pid" ] && [ "$new_pid" != "$initial_pid" ]; then
    pass "PID is distinct ($initial_pid → $new_pid)"
else
    fail "PID is distinct" "PID did not change (still $initial_pid or empty)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "==================================="
echo "  PASSED: $PASSED"
echo "  FAILED: $FAILED"
echo "==================================="
echo ""

if [ "$FAILED" -gt 0 ]; then
    echo "Some checks failed. Check: loop logs -f"
    exit 1
fi

echo "All checks passed. launchd owns the daemon."
exit 0
