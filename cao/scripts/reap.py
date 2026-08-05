#!/usr/bin/env python3
"""Reap only stale CAO terminals explicitly registered by this repository."""
from __future__ import annotations

import argparse
import json
import os
import subprocess
from dataclasses import dataclass
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import urlopen

ACTIVE = {"running", "working", "busy", "idle", "pending"}
DEAD = {"completed", "complete", "success", "done", "error", "failed", "cancelled", "canceled"}


@dataclass(frozen=True)
class Event:
    task: str
    attempt: str
    phase: str
    session: str
    terminal: str
    worktree: str
    digest: str


def load_events(path: Path) -> list[Event]:
    latest: dict[str, Event] = {}
    if not path.exists():
        return []
    for line in path.read_text().splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if value.get("kind") == "reaped":
            terminal = value.get("terminal")
            if isinstance(terminal, str):
                latest.pop(terminal, None)
            continue
        try:
            event = Event(
                task=value["task"],
                attempt=value["attempt"],
                phase=value["phase"],
                session=value["session"],
                terminal=value["terminal"],
                worktree=value["worktree"],
                digest=value["digest"],
            )
        except (KeyError, TypeError):
            continue
        latest[event.terminal] = event
    return list(latest.values())


def terminal_status(api_url: str, terminal: str) -> tuple[str | None, str | None]:
    try:
        with urlopen(f"{api_url}/terminals/{terminal}", timeout=5) as response:  # nosec B310 -- local CAO URL supplied by operator
            payload = json.load(response)
    except HTTPError as error:
        return (None, "missing") if error.code == 404 else (None, "api_error")
    except (URLError, TimeoutError, json.JSONDecodeError, OSError):
        return None, "api_error"
    status = payload.get("status") if isinstance(payload, dict) else None
    if not isinstance(status, str):
        return None, "api_error"
    return status.lower(), None


def tmux_status(session: str) -> bool | None:
    try:
        result = subprocess.run(["tmux", "has-session", "-t", session], capture_output=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return result.returncode == 0


def current_digest(repo: Path, worktree: str) -> str | None:
    if not Path(worktree).is_dir():
        return None
    try:
        result = subprocess.run(
            [str(repo / "cao/scripts/repo-state.sh"), "digest", worktree],
            capture_output=True,
            text=True,
            timeout=20,
            check=True,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None
    return result.stdout.strip()


def shutdown(repo: Path, session: str) -> bool:
    environment = {
        **os.environ,
        "CAO_HOME_DIR": str(repo / ".cao/home/.aws/cli-agent-orchestrator"),
    }
    try:
        return subprocess.run(
            ["cao", "shutdown", "--session", session], capture_output=True, timeout=20, env=environment
        ).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def append_reaped(path: Path, event: Event) -> None:
    value = {
        "kind": "reaped",
        "task": event.task,
        "attempt": event.attempt,
        "phase": event.phase,
        "session": event.session,
        "terminal": event.terminal,
    }
    with path.open("a") as stream:
        stream.write(json.dumps(value, sort_keys=True) + "\n")


def inspect_event(repo: Path, api_url: str, event: Event, dry_run: bool) -> str:
    status, error = terminal_status(api_url, event.terminal)
    if error == "api_error":
        return f"keep {event.terminal}: CAO API unavailable"
    if status == "waiting_user_answer":
        return f"keep {event.terminal}: waiting_user_answer"
    if status in ACTIVE:
        return f"keep {event.terminal}: {status}"
    if error == "missing":
        tmux = tmux_status(event.session)
        if tmux is True:
            return f"keep {event.terminal}: tmux session still exists"
        if tmux is None:
            return f"keep {event.terminal}: tmux status unknown"
        digest = current_digest(repo, event.worktree)
        if digest is not None and digest != event.digest:
            return f"keep {event.terminal}: worktree digest changed"
    elif status not in DEAD:
        return f"keep {event.terminal}: unrecognized status {status}"

    if dry_run:
        return f"reap {event.terminal}: terminal is no longer live"
    if shutdown(repo, event.session):
        return f"reaped {event.terminal}: terminal is no longer live"
    return f"keep {event.terminal}: shutdown failed"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=".")
    parser.add_argument("--api-url", default="http://127.0.0.1:9889")
    parser.add_argument("--events")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    repo = Path(args.repo).resolve()
    events = Path(args.events) if args.events else repo / ".cao/state/events.jsonl"
    events.parent.mkdir(parents=True, exist_ok=True)
    for event in load_events(events):
        result = inspect_event(repo, args.api_url.rstrip("/"), event, args.dry_run)
        print(result)
        if result.startswith("reaped "):
            append_reaped(events, event)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
