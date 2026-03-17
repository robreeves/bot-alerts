#!/usr/bin/env bash
set -euo pipefail

ALERTS_DIR="${BOT_ALERTS_DIR:-$HOME/.claude/alerts}"
mkdir -p "$ALERTS_DIR"

# Read hook JSON from stdin
hook_json=$(cat)

session_id=$(echo "$hook_json" | jq -r '.session_id // empty')
cwd=$(echo "$hook_json" | jq -r '.cwd // empty')
hook_event=$(echo "$hook_json" | jq -r '.hook_event_name // empty')

if [[ -z "$session_id" ]]; then
  exit 0
fi

project=$cwd
git_branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

# Build context based on event type
case "$hook_event" in
  Stop)
    raw_context=$(echo "$hook_json" | jq -r '.last_assistant_message // ""')
    context=$(echo "$raw_context" | head -c 500)
    ;;
  PreToolUse)
    # AskUserQuestion: format questions from tool_input
    questions=$(echo "$hook_json" | jq -r '
      .tool_input.questions //
      (if .tool_input.question then [.tool_input.question] else [] end) |
      if type == "array" then
        map(
          if type == "object" then .question // tostring
          else tostring
          end
        ) | join(" | ")
      else tostring
      end
    ' 2>/dev/null || echo "")
    context=$(echo "$questions" | head -c 500)
    ;;
  Notification)
    title=$(echo "$hook_json" | jq -r '.title // ""')
    message=$(echo "$hook_json" | jq -r '.message // ""')
    if [[ -n "$title" ]]; then
      context="${title}: ${message}"
    else
      context="$message"
    fi
    context=$(echo "$context" | head -c 500)
    ;;
  *)
    context=""
    ;;
esac

timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
pid=$PPID

tmp_file=$(mktemp "$ALERTS_DIR/.tmp.XXXXXX")
cat > "$tmp_file" <<EOF
{
  "session_id": $(echo "$session_id" | jq -R .),
  "timestamp": $(echo "$timestamp" | jq -R .),
  "cwd": $(echo "$cwd" | jq -R .),
  "project": $(echo "$project" | jq -R .),
  "event": $(echo "$hook_event" | jq -R .),
  "git_branch": $(echo "$git_branch" | jq -R .),
  "context": $(echo "$context" | jq -R .),
  "pid": $pid
}
EOF

mv "$tmp_file" "$ALERTS_DIR/${session_id}.json"
