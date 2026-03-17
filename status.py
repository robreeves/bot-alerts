#!/usr/bin/env python3
"""Live-updating Claude Code alert viewer.

Usage: ./status.py [--once|-1] [host1 host2 ...]
"""

import json
import os
import signal
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path


def parse_args():
    once = False
    hosts = []
    for arg in sys.argv[1:]:
        if arg in ("--once", "-1"):
            once = True
        else:
            hosts.append(arg)
    return once, hosts


def alerts_dir():
    return Path(os.environ.get("BOT_ALERTS_DIR", Path.home() / ".claude" / "alerts"))


def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ProcessLookupError, ValueError):
        return False


def parse_json_stream(text):
    """Parse zero or more JSON objects from a string."""
    decoder = json.JSONDecoder()
    idx = 0
    while idx < len(text):
        while idx < len(text) and text[idx] in " \t\n\r":
            idx += 1
        if idx >= len(text):
            break
        try:
            obj, end = decoder.raw_decode(text, idx)
            yield obj
            idx = end
        except json.JSONDecodeError:
            idx += 1


def load_local_alerts():
    alerts = []
    for f in alerts_dir().glob("*.json"):
        try:
            data = json.loads(f.read_text())
            data["_host"] = ""
            alerts.append(data)
        except Exception:
            continue
    return alerts


def fetch_remote_alerts(host):
    cmd = [
        "ssh", "-o", "ConnectTimeout=3", "-o", "BatchMode=yes", host,
        'DIR="${BOT_ALERTS_DIR:-$HOME/.claude/alerts}"; '
        'for f in "$DIR"/*.json; do cat "$f" 2>/dev/null; printf "\\n"; done',
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        alerts = []
        for obj in parse_json_stream(result.stdout):
            obj["_host"] = host
            alerts.append(obj)
        return alerts
    except Exception:
        return []


def load_all_alerts(hosts):
    alerts = load_local_alerts()
    if hosts:
        with ThreadPoolExecutor(max_workers=len(hosts)) as executor:
            futures = [executor.submit(fetch_remote_alerts, h) for h in hosts]
            for f in as_completed(futures):
                alerts.extend(f.result())
    return alerts


def format_timestamp(ts_str):
    if not ts_str:
        return ""
    try:
        dt = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
        return dt.astimezone().strftime("%Y-%m-%dT%H:%M")
    except Exception:
        return ts_str[:16]


def render(hosts):
    alerts = load_all_alerts(hosts)

    live = []
    for a in alerts:
        if a.get("_host") == "":  # local — check PID liveness
            pid = a.get("pid")
            if pid and not pid_alive(pid):
                continue
        live.append(a)

    live.sort(key=lambda a: a.get("timestamp", ""))

    blocks = []
    for i, a in enumerate(live, 1):
        host = a.get("_host", "")
        project = a.get("project") or a.get("cwd", "")
        branch = a.get("git_branch", "")
        event = a.get("event", "")
        ts = format_timestamp(a.get("timestamp", ""))
        context = (a.get("context") or "")[:500]

        header = f"[{i}] "
        if host:
            header += f"{host}:  "
        fields = [f for f in [project, branch, ts, event] if f]
        header += "  |  ".join(fields)

        block = header
        if context:
            block += f"\n    {context}"
        blocks.append(block)

    print("\033[2J\033[H", end="")  # clear screen
    print("\n\n".join(blocks) if blocks else "(no alerts)")


def main():
    once, hosts = parse_args()

    def handle_signal(sig, frame):
        print()
        sys.exit(0)

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    if once:
        render(hosts)
    else:
        while True:
            render(hosts)
            time.sleep(2)


if __name__ == "__main__":
    main()
