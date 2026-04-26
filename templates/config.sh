# .loop/config.sh — project configuration
PROJECT_NAME="my-project"
HEARTBEAT_INTERVAL=300        # Idle interval (seconds)
WORKER_COOLDOWN=30            # Between worker iterations
MAX_ITERATIONS=20             # Safety limit per brief
MAX_CYCLE_WALL_TIME_SECS=5400 # Per-cycle wall-time budget (seconds). Default 90 min.
                              # Override per-brief with **Cycle-wall-time-secs:** frontmatter.
WORKER_KILL_GRACE_SECS=10     # Grace period between SIGTERM and SIGKILL on timeout
CONDUCTOR_DEDUP_TTL_SECS=1800 # Conductor dedup cache TTL (seconds). After this, a repeated
                              # trigger is re-evaluated fresh — prevents indefinite idle when
                              # a stuck condition persists but the dedup cache holds the action.
NTFY_TOPIC=""                 # ntfy.sh topic (empty = no push notifications)
VERIFY_CMD=""                 # Command to run after each task (e.g. npm test, cargo build)
GIT_REMOTE="origin"
GIT_MAIN_BRANCH="main"       # "main" or "master"
