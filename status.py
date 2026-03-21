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

# ANSI 256-color constants (Claude Code dark mode inspired)
C_RESET = "\033[0m"
C_ORANGE = "\033[38;5;215m"
C_LAVENDER = "\033[38;5;183m"
C_BLUE = "\033[38;5;111m"
C_GREEN = "\033[38;5;114m"
C_CYAN = "\033[38;5;117m"
C_DIM = "\033[38;5;245m"
C_DIMMER = "\033[38;5;240m"
C_YELLOW = "\033[38;5;222m"


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
                sid = a.get("session_id")
                if sid:
                    (alerts_dir() / f"{sid}.json").unlink(missing_ok=True)
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

        header = f"{C_ORANGE}[{i}]{C_RESET} "
        if host:
            header += f"{C_CYAN}{host}:{C_RESET}  "
        pipe = f"  {C_DIMMER}|{C_RESET}  "
        colored_fields = []
        if event:
            colored_fields.append(f"{C_LAVENDER}{event}{C_RESET}")
        if project:
            colored_fields.append(f"{C_BLUE}{project}{C_RESET}")
        if branch:
            colored_fields.append(f"{C_GREEN}{branch}{C_RESET}")
        if ts:
            colored_fields.append(f"{C_DIM}{ts}{C_RESET}")
        header += pipe.join(colored_fields)

        block = header
        if context:
            indent = "    "
            separator = indent + f"{C_DIMMER}" + "─" * 60 + f"{C_RESET}"
            indented = "\n".join(indent + line for line in context.splitlines())
            block += f"\n{separator}\n{indented}"
        blocks.append(block)

    print("\033[2J\033[H", end="")  # clear screen
    print("\n\n\n".join(blocks) if blocks else f"{C_DIM}(no alerts){C_RESET}")

    return live


def delete_alert(alert):
    session_id = alert.get("session_id")
    if not session_id:
        return False
    host = alert.get("_host", "")
    if host:
        subprocess.run(
            ["ssh", "-o", "ConnectTimeout=3", "-o", "BatchMode=yes", host,
             f'rm -f "${{BOT_ALERTS_DIR:-$HOME/.claude/alerts}}/{session_id}.json"'],
            timeout=5, capture_output=True,
        )
    else:
        path = alerts_dir() / f"{session_id}.json"
        path.unlink(missing_ok=True)
    return True


def capture_pane(alert):
    pane = alert.get("tmux_pane") or ""
    if not pane:
        return None
    host = alert.get("_host", "")
    try:
        if host:
            result = subprocess.run(
                ["ssh", "-o", "ConnectTimeout=3", "-o", "BatchMode=yes", host,
                 f"tmux capture-pane -t {pane} -p -S -100"],
                capture_output=True, text=True, timeout=5,
            )
        else:
            result = subprocess.run(
                ["tmux", "capture-pane", "-t", pane, "-p", "-S", "-100"],
                capture_output=True, text=True, timeout=5,
            )
        if result.returncode != 0:
            return f"(capture failed: {result.stderr.strip() or 'exit ' + str(result.returncode)})"
        return result.stdout
    except Exception as e:
        return f"(capture failed: {e})"


def show_preview(index, content):
    lines = content.rstrip("\n").splitlines()
    term_height = os.get_terminal_size().lines
    # Reserve 3 lines: blank, separator, status
    available = term_height - 3
    visible = lines[-available:] if len(lines) > available else lines

    print("\033[2J\033[H", end="")  # clear screen
    print("\n".join(visible))
    # Pin status at bottom
    print(f"\n{C_DIMMER}{'─' * 60}{C_RESET}")
    print(f"{C_LAVENDER}Preview {C_ORANGE}[{index}]{C_RESET} {C_DIM}— press Esc to return{C_RESET}", end="", flush=True)
    while True:
        ready, _, _ = select.select([sys.stdin], [], [], 0.5)
        if ready:
            key = sys.stdin.read(1)
            if key == "\x1b":
                return


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

    def cleanup():
        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_settings)
        print("\033[?1049l", end="", flush=True)  # exit alternate screen

    def handle_signal(sig, frame):
        cleanup()
        print()
        sys.exit(0)

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    print("\033[?1049h", end="", flush=True)  # enter alternate screen
    tty.setcbreak(sys.stdin.fileno())
    status_msg = ""
    try:
        while True:
            live = render(hosts)
            print(f"\n{C_DIMMER}{'─' * 60}{C_RESET}")
            if status_msg:
                print(f"{C_YELLOW}{status_msg}{C_RESET}")
            print(f"{C_DIM}Press{C_RESET} {C_ORANGE}[1-9]{C_RESET} {C_DIM}approve  |  {C_ORANGE}x[1-9]{C_RESET} {C_DIM}dismiss  |  {C_ORANGE}p[1-9]{C_RESET} {C_DIM}preview  |  {C_ORANGE}q{C_RESET} {C_DIM}quit{C_RESET}")

            ready, _, _ = select.select([sys.stdin], [], [], 2)
            if not ready:
                status_msg = ""
                continue

            key = sys.stdin.read(1)
            if key == "q":
                break
            status_msg = ""
            if key in ("x", "p"):
                action = key
                ready2, _, _ = select.select([sys.stdin], [], [], 2)
                if ready2:
                    key2 = sys.stdin.read(1)
                    if key2.isdigit() and key2 != "0":
                        idx = int(key2) - 1
                        if 0 <= idx < len(live):
                            if action == "x":
                                delete_alert(live[idx])
                                status_msg = f"Dismissed [{idx + 1}]"
                            else:
                                text = capture_pane(live[idx])
                                if text is None:
                                    status_msg = f"[{idx + 1}] has no tmux session"
                                else:
                                    show_preview(idx + 1, text)
                        else:
                            status_msg = f"No alert [{idx + 1}]"
                    else:
                        status_msg = f"{'Dismiss' if action == 'x' else 'Preview'} cancelled"
                else:
                    status_msg = f"{'Dismiss' if action == 'x' else 'Preview'} cancelled"
            elif key.isdigit() and key != "0":
                idx = int(key) - 1
                if 0 <= idx < len(live):
                    if not approve_alert(live[idx]):
                        status_msg = f"[{idx + 1}] has no tmux session"
    finally:
        cleanup()


if __name__ == "__main__":
    main()
