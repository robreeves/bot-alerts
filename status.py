#!/usr/bin/env python3
"""Live-updating Claude Code alert viewer.

Usage: ./status.py [--once|-1] [host1 host2 ...]
"""

import json
import os
import select
import signal
import subprocess
import sys
import termios
import time
import tty
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
        return dt.astimezone().strftime("%Y-%m-%d %I:%M %p")
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
        context = a.get("context") or ""

        header = f"[{i}] "
        if host:
            header += f"{host}:  "
        fields = [f for f in [event, project, branch, ts] if f]
        header += "  |  ".join(fields)

        block = header
        if context:
            indent = "    "
            separator = indent + "─" * 60
            indented = "\n".join(indent + line for line in context.splitlines())
            block += f"\n{separator}\n{indented}"
        blocks.append(block)

    print("\033[2J\033[H", end="")  # clear screen
    print("\n\n\n".join(blocks) if blocks else "(no alerts)")

    return live


def approve_alert(alert):
    host = alert.get("_host", "")
    pane = alert.get("tmux_pane") or ""
    if not pane:
        return False

    if host:
        subprocess.run(
            ["ssh", "-o", "ConnectTimeout=3", "-o", "BatchMode=yes", host,
             f"tmux send-keys -t {pane} 1"],
            timeout=5, capture_output=True,
        )
        time.sleep(0.1)
        subprocess.run(
            ["ssh", "-o", "ConnectTimeout=3", "-o", "BatchMode=yes", host,
             f"tmux send-keys -t {pane} Enter"],
            timeout=5, capture_output=True,
        )
    else:
        subprocess.run(["tmux", "send-keys", "-t", pane, "1"], capture_output=True)
        time.sleep(0.1)
        subprocess.run(["tmux", "send-keys", "-t", pane, "Enter"], capture_output=True)
    return True


def main():
    once, hosts = parse_args()

    if once:
        render(hosts)
        return

    old_settings = termios.tcgetattr(sys.stdin)

    def handle_signal(sig, frame):
        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_settings)
        print()
        sys.exit(0)

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    tty.setcbreak(sys.stdin.fileno())
    status_msg = ""
    try:
        while True:
            live = render(hosts)
            print(f"\n{'─' * 60}")
            if status_msg:
                print(status_msg)
            print("Press [1-9] to approve  |  q to quit")

            ready, _, _ = select.select([sys.stdin], [], [], 2)
            if not ready:
                status_msg = ""
                continue

            key = sys.stdin.read(1)
            if key == "q":
                break
            status_msg = ""
            if key.isdigit() and key != "0":
                idx = int(key) - 1
                if 0 <= idx < len(live):
                    if not approve_alert(live[idx]):
                        status_msg = f"[{idx + 1}] has no tmux session"
    finally:
        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_settings)


if __name__ == "__main__":
    main()
