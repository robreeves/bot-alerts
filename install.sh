#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"

# Check dependencies
if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed." >&2
  echo "Install it with: brew install jq" >&2
  exit 1
fi

# Make hook scripts executable
chmod +x "$SCRIPT_DIR/hooks/alert-create.sh"
chmod +x "$SCRIPT_DIR/hooks/alert-cleanup.sh"

CREATE="$SCRIPT_DIR/hooks/alert-create.sh"
CLEANUP="$SCRIPT_DIR/hooks/alert-cleanup.sh"

# Initialize settings.json if it doesn't exist
if [[ ! -f "$SETTINGS" ]]; then
  mkdir -p "$(dirname "$SETTINGS")"
  echo '{}' > "$SETTINGS"
fi

# Merge hook config into settings.json, preserving existing hooks
updated=$(jq \
  --arg create "$CREATE" \
  --arg cleanup "$CLEANUP" \
  '
  .hooks.Stop = ((.hooks.Stop // []) + [{"hooks": [{"type": "command", "command": $create}]}]) |
  .hooks.PreToolUse = ((.hooks.PreToolUse // []) + [{"matcher": "AskUserQuestion", "hooks": [{"type": "command", "command": $create}]}]) |
  .hooks.Notification = ((.hooks.Notification // []) + [{"hooks": [{"type": "command", "command": $create}]}]) |
  .hooks.PreToolUse = ((.hooks.PreToolUse // []) + [{"hooks": [{"type": "command", "command": $cleanup}]}]) |
  .hooks.PostToolUse = ((.hooks.PostToolUse // []) + [{"hooks": [{"type": "command", "command": $cleanup}]}]) |
  .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) + [{"hooks": [{"type": "command", "command": $cleanup}]}]) |
  .hooks.SessionEnd = ((.hooks.SessionEnd // []) + [{"hooks": [{"type": "command", "command": $cleanup}]}])
  ' "$SETTINGS")

echo "$updated" > "$SETTINGS"

echo "Installed bot-alerts hooks into $SETTINGS"
echo "Alert directory: ${BOT_ALERTS_DIR:-$HOME/.claude/alerts}"
