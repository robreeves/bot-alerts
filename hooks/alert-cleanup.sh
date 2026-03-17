#!/usr/bin/env bash
set -euo pipefail

ALERTS_DIR="${BOT_ALERTS_DIR:-$HOME/.claude/alerts}"

hook_json=$(cat)
session_id=$(echo "$hook_json" | jq -r '.session_id // empty')

if [[ -z "$session_id" ]]; then
  exit 0
fi

rm -f "$ALERTS_DIR/${session_id}.json"
