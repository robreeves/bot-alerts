#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"

if [[ ! -f "$SETTINGS" ]]; then
  echo "No settings.json found at $SETTINGS, nothing to do."
  exit 0
fi

CREATE="$SCRIPT_DIR/hooks/alert-create.sh"
CLEANUP="$SCRIPT_DIR/hooks/alert-cleanup.sh"

# Remove bot-alerts hook entries from each hook event
updated=$(jq \
  --arg create "$CREATE" \
  --arg cleanup "$CLEANUP" \
  '
  def remove_bot_alerts($cmd):
    map(select(
      (.hooks[0].command? // "") != $cmd
    ));

  .hooks.Stop = ((.hooks.Stop // []) | remove_bot_alerts($create)) |
  .hooks.PreToolUse = ((.hooks.PreToolUse // []) | remove_bot_alerts($create)) |
  .hooks.Notification = ((.hooks.Notification // []) | remove_bot_alerts($create)) |
  .hooks.PreToolUse = ((.hooks.PreToolUse // []) | remove_bot_alerts($cleanup)) |
  .hooks.PostToolUse = ((.hooks.PostToolUse // []) | remove_bot_alerts($cleanup)) |
  .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) | remove_bot_alerts($cleanup)) |
  .hooks.SessionEnd = ((.hooks.SessionEnd // []) | remove_bot_alerts($cleanup))
  ' "$SETTINGS")

echo "$updated" > "$SETTINGS"

echo "Removed bot-alerts hooks from $SETTINGS"
