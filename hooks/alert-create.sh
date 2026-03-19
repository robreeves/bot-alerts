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
tmux_pane="${TMUX_PANE:-}"
if [ -n "$tmux_pane" ]; then
    tmux_session=$(tmux display-message -p '#S' 2>/dev/null || echo "")
else
    tmux_session=""
fi

# Build context based on event type
case "$hook_event" in
  Stop)
    raw_context=$(echo "$hook_json" | jq -r '.last_assistant_message // ""')
    context=$(echo "$raw_context" | head -c 5000)
    ;;
  PreToolUse)
    tool_name=$(echo "$hook_json" | jq -r '.tool_name // ""')
    # Format context based on tool type
    case "$tool_name" in
      Bash)
        desc=$(echo "$hook_json" | jq -r '.tool_input.description // ""')
        cmd=$(echo "$hook_json" | jq -r '.tool_input.command // ""')
        context="Bash"
        if [[ -n "$desc" ]]; then
          context="${context}: ${desc}"
        fi
        if [[ -n "$cmd" ]]; then
          context="${context}"$'\n'"${cmd}"
        fi
        ;;
      Edit)
        file=$(echo "$hook_json" | jq -r '.tool_input.file_path // ""')
        old=$(echo "$hook_json" | jq -r '.tool_input.old_string // ""')
        new=$(echo "$hook_json" | jq -r '.tool_input.new_string // ""')
        context="Edit: ${file}"$'\n'"- ${old}"$'\n'"+ ${new}"
        ;;
      Write)
        file=$(echo "$hook_json" | jq -r '.tool_input.file_path // ""')
        content=$(echo "$hook_json" | jq -r '.tool_input.content // ""')
        context="Write: ${file}"$'\n'"${content}"
        ;;
      AskUserQuestion)
        context=$(echo "$hook_json" | jq -r '
          [.tool_input.questions[]? |
            (.question // "") + "\n" +
            ([.options[]? |
              "  " + (.label // "") +
              (if .description then "\n     " + .description else "" end)
            ] | to_entries | map("  \(.key + 1). " + .value) | join("\n"))
          ] | join("\n\n")
        ' 2>/dev/null || echo "")
        ;;
      *)
        # Generic: show tool name + JSON tool_input
        input=$(echo "$hook_json" | jq -c '.tool_input // {}')
        context="${tool_name}: ${input}"
        ;;
    esac
    context=$(echo "$context" | head -c 5000)
    ;;
  Notification)
    # If a PreToolUse alert already exists for this session, don't overwrite it
    # (PreToolUse has richer context like the full command)
    alert_file="$ALERTS_DIR/${session_id}.json"
    if [[ -f "$alert_file" ]]; then
      existing_event=$(jq -r '.event // ""' "$alert_file" 2>/dev/null || echo "")
      if [[ "$existing_event" == "PreToolUse" ]]; then
        # Update event to Notification but keep the existing context
        existing_context=$(jq -r '.context // ""' "$alert_file" 2>/dev/null || echo "")
        context="$existing_context"
        # Fall through to write updated alert with Notification event
      else
        title=$(echo "$hook_json" | jq -r '.title // ""')
        message=$(echo "$hook_json" | jq -r '.message // ""')
        if [[ -n "$title" ]]; then
          context="${title}: ${message}"
        else
          context="$message"
        fi
        context=$(echo "$context" | head -c 5000)
      fi
    else
      title=$(echo "$hook_json" | jq -r '.title // ""')
      message=$(echo "$hook_json" | jq -r '.message // ""')
      if [[ -n "$title" ]]; then
        context="${title}: ${message}"
      else
        context="$message"
      fi
      context=$(echo "$context" | head -c 5000)
    fi
    ;;
  *)
    context=""
    ;;
esac

timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
pid=$PPID

tmp_file=$(mktemp "$ALERTS_DIR/.tmp.XXXXXX")
jq -n \
  --arg session_id "$session_id" \
  --arg timestamp "$timestamp" \
  --arg cwd "$cwd" \
  --arg project "$project" \
  --arg event "$hook_event" \
  --arg git_branch "$git_branch" \
  --arg tmux_session "$tmux_session" \
  --arg tmux_pane "$tmux_pane" \
  --arg context "$context" \
  --argjson pid "$pid" \
  '{
    session_id: $session_id,
    timestamp: $timestamp,
    cwd: $cwd,
    project: $project,
    event: $event,
    git_branch: $git_branch,
    tmux_session: $tmux_session,
    tmux_pane: $tmux_pane,
    context: $context,
    pid: $pid
  }' > "$tmp_file"

mv "$tmp_file" "$ALERTS_DIR/${session_id}.json"
