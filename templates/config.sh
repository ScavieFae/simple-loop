# .loop/config.sh — project configuration
PROJECT_NAME="my-project"
HEARTBEAT_INTERVAL=300        # Idle interval (seconds)
WORKER_COOLDOWN=30            # Between worker iterations
MAX_ITERATIONS=20             # Safety limit per brief
NTFY_TOPIC=""                 # ntfy.sh topic (empty = no push notifications)
VERIFY_CMD=""                 # Command to run after each task (e.g. npm test, cargo build)
GIT_REMOTE="origin"
GIT_MAIN_BRANCH="main"       # "main" or "master"
