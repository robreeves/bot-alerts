#!/usr/bin/env bash
# Simulates Claude Code alerts for testing status.sh
# Usage: ./simulate-alerts.sh [--count N] [--interval SECS]
set -euo pipefail

ALERTS_DIR="${BOT_ALERTS_DIR:-$HOME/.claude/alerts}"
COUNT=3
INTERVAL=5

while [[ $# -gt 0 ]]; do
  case "$1" in
    --count)    COUNT="$2";    shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    *) echo "Usage: $0 [--count N] [--interval SECS]" >&2; exit 1 ;;
  esac
done

mkdir -p "$ALERTS_DIR"

PROJECTS=(
  "/Users/robreeves/dev/bot-alerts"
  "/Users/robreeves/dev/myapp"
  "/Users/robreeves/dev/infra"
)
BRANCHES=(main feature-x fix/auth-bug chore/cleanup)
EVENTS=(Stop Stop Stop Notification PreToolUse)
CONTEXTS=(
  "I've updated the file. Shall I also run the tests?"
  "The migration looks good. Want me to apply it to staging?"
  "Found 3 issues in the diff. Should I fix them all or just the critical ones?"
  "Claude needs your permission to use Bash"
  "Build complete. Should I open a PR?"
)

cleanup() {
  echo
  echo "Cleaning up simulated alerts..."
  for sid in "${SESSION_IDS[@]:-}"; do
    rm -f "$ALERTS_DIR/${sid}.json"
  done
  exit 0
}
trap cleanup INT TERM

SESSION_IDS=()

echo "Creating $COUNT simulated alert(s) in $ALERTS_DIR"
echo "Refreshing every ${INTERVAL}s. Ctrl+C to clean up and exit."
echo

for ((i = 0; i < COUNT; i++)); do
  SESSION_IDS+=("sim-session-$i")
done

while true; do
  for ((i = 0; i < COUNT; i++)); do
    sid="sim-session-$i"
    project="${PROJECTS[$((i % ${#PROJECTS[@]}))]}"
    branch="${BRANCHES[$((i % ${#BRANCHES[@]}))]}"
    event="${EVENTS[$((RANDOM % ${#EVENTS[@]}))]}"
    context="${CONTEXTS[$((RANDOM % ${#CONTEXTS[@]}))]}"
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    tmux_session="main"
    tmux_pane="%$((i + 1))"

    tmp=$(mktemp "$ALERTS_DIR/.tmp.XXXXXX")
    cat > "$tmp" <<JSON
{
  "session_id": "$sid",
  "timestamp": "$timestamp",
  "cwd": "$project",
  "project": "$project",
  "event": "$event",
  "git_branch": "$branch",
  "tmux_session": "$tmux_session",
  "tmux_pane": "$tmux_pane",
  "context": "$context",
  "pid": $$
}
JSON
    mv "$tmp" "$ALERTS_DIR/${sid}.json"
  done

  echo "$(date +%H:%M:%S)  wrote $COUNT alert(s) (pid=$$)"
  sleep "$INTERVAL"
done
