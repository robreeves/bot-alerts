#!/usr/bin/env bash
set -euo pipefail

ONCE=0
REMOTE_HOSTS=()
for arg in "$@"; do
  if [[ "$arg" == "--once" || "$arg" == "-1" ]]; then
    ONCE=1
  else
    REMOTE_HOSTS+=("$arg")
  fi
done
ALERTS_DIR="${BOT_ALERTS_DIR:-$HOME/.claude/alerts}"

# Dependency checks
if ! command -v jq &>/dev/null; then
  echo "status.sh: jq is required but not found" >&2
  exit 1
fi
if [[ ${#REMOTE_HOSTS[@]} -gt 0 ]] && ! command -v ssh &>/dev/null; then
  echo "status.sh: ssh is required for remote hosts but not found" >&2
  exit 1
fi

# Render a single alert block.
# Args: host pid tmux_session tmux_pane git_branch event timestamp project context
render_alert() {
  local host="$1" pid="$2" tmux_session="$3" tmux_pane="$4" \
        git_branch="$5" event="$6" timestamp="$7" project="$8" context="$9"

  # PID liveness check — local alerts only
  if [[ -z "$host" && -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
    return 1
  fi

  local tmux_info
  if [[ -n "$tmux_session" ]]; then
    tmux_info="$tmux_session / $tmux_pane"
  else
    tmux_info="(no tmux)"
  fi

  INDEX=$((INDEX + 1))

  local header="[$INDEX] "
  if [[ -n "$host" ]]; then
    header+="${host}:  $tmux_info"
  else
    header+="$tmux_info"
  fi
  [[ -n "$git_branch" ]] && header+="  |  $git_branch"
  [[ -n "$event" ]] && header+="  |  $event"
  [[ -n "$timestamp" ]] && header+="  |  ${timestamp:0:16}"

  if [[ ${#context} -gt 100 ]]; then
    context="${context:0:100}..."
  fi

  [[ $INDEX -gt 1 ]] && OUTPUT+=$'\n'
  OUTPUT+="$header"$'\n'
  [[ -n "$project" ]] && OUTPUT+="    $project"$'\n'
  [[ -n "$context" ]] && OUTPUT+="    $context"$'\n'
}

# Render all alerts from combined JSON (newline-separated objects with _host field),
# sorted oldest-first by timestamp.
process_alerts() {
  local json_content="$1"
  [[ -z "$json_content" ]] && return 0

  local count sorted
  count=$(echo "$json_content" | jq -s 'length' 2>/dev/null) || return 0
  [[ "$count" -eq 0 ]] && return 0
  sorted=$(echo "$json_content" | jq -s 'sort_by(.timestamp)' 2>/dev/null) || return 0

  for ((i = 0; i < count; i++)); do
    local host pid tmux_session tmux_pane git_branch event timestamp project context
    read -r host pid tmux_session tmux_pane git_branch event timestamp project < <(
      echo "$sorted" | jq -r ".[$i] |
        [(._host//\"\"), ((.pid//\"\")|tostring), (.tmux_session//\"\"), (.tmux_pane//\"\"),
         (.git_branch//\"\"), (.event//\"\"), (.timestamp//\"\"),
         (.project//.cwd//\"\")] | @tsv" 2>/dev/null
    ) || continue
    context=$(echo "$sorted" | jq -r ".[$i] | .context // \"\"" 2>/dev/null) || continue

    render_alert "$host" "$pid" "$tmux_session" "$tmux_pane" \
                 "$git_branch" "$event" "$timestamp" "$project" "$context" || continue
  done
}

render() {
  INDEX=0
  OUTPUT=""
  local all_json=""

  # --- Collect local alerts (tagged with empty _host) ---
  shopt -s nullglob
  local files=("$ALERTS_DIR"/*.json)
  shopt -u nullglob

  for file in "${files[@]}"; do
    local content tagged
    content=$(cat "$file" 2>/dev/null) || continue
    tagged=$(echo "$content" | jq -c '. + {_host: ""}' 2>/dev/null) || continue
    [[ -n "$all_json" ]] && all_json+=$'\n'
    all_json+="$tagged"
  done

  # --- Collect remote alerts (tagged with hostname) ---
  if [[ ${#REMOTE_HOSTS[@]} -gt 0 ]]; then
    local tmpdir
    tmpdir=$(mktemp -d)

    for host in "${REMOTE_HOSTS[@]}"; do
      ssh -o ConnectTimeout=3 -o BatchMode=yes "$host" \
        'DIR="${BOT_ALERTS_DIR:-$HOME/.claude/alerts}"; for f in "$DIR"/*.json; do cat "$f" 2>/dev/null; printf "\n"; done' \
        > "$tmpdir/$host.json" 2>/dev/null &
    done
    wait || true

    for host in "${REMOTE_HOSTS[@]}"; do
      local remote_content tagged_remote
      remote_content=$(cat "$tmpdir/$host.json" 2>/dev/null) || continue
      [[ -z "$remote_content" ]] && continue
      tagged_remote=$(echo "$remote_content" | jq -sc --arg h "$host" '.[] | . + {_host: $h}' 2>/dev/null) || continue
      [[ -n "$all_json" && -n "$tagged_remote" ]] && all_json+=$'\n'
      all_json+="$tagged_remote"
    done

    rm -rf "$tmpdir"
  fi

  process_alerts "$all_json"

  # --- Display ---
  clear
  if [[ $INDEX -gt 0 ]]; then
    printf '%s' "$OUTPUT"
  else
    echo "(no alerts)"
  fi
}

trap 'echo; exit 0' INT TERM

if [[ $ONCE -eq 1 ]]; then
  render
else
  while true; do
    render
    sleep 2
  done
fi
