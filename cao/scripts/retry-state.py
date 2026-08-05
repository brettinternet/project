#!/usr/bin/env python3
"""Atomic, task-keyed CAO retry, finalization, and delivery state."""
from __future__ import annotations

import argparse
import json
import os
import re
import tempfile
from pathlib import Path
from typing import Any

ROOT = Path(os.environ.get("CAO_STATE_ROOT", Path(__file__).resolve().parents[2]))
SHA = re.compile(r"^[0-9a-f]{40}$")
DIGEST = re.compile(r"^[0-9a-f]{64}$")
STAGES = ("verified", "prepared", "committed", "ci_passed", "integrated")


def checkpoint_path(item: str) -> Path:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", item):
        raise ValueError("invalid task ID")
    return ROOT / ".cao" / "state" / "tasks" / item / "checkpoint.json"


def default(item: str) -> dict[str, Any]:
    return {
        "version": 1,
        "item": item,
        "retry": {
            "task_attempts": 0,
            "identical_failures": 0,
            "last_fingerprint": None,
            "last_recorded_attempt": None,
            "last_failure_class": None,
            "last_failure_kind": None,
        },
        "finalize": {
            "attempt": None,
            "baseline_sha": None,
            "digest": None,
            "stage": None,
            "task_path": None,
            "task_blob": None,
            "commit_sha": None,
        },
        "delivery": None,
    }


def strings_or_none(value: dict[str, Any], keys: tuple[str, ...]) -> bool:
    return all(value[key] is None or isinstance(value[key], str) for key in keys)


def valid(value: object, item: str) -> bool:
    expected = default(item)
    if not isinstance(value, dict) or set(value) != set(expected):
        return False
    if value["version"] != 1 or value["item"] != item:
        return False

    retry = value["retry"]
    finalize = value["finalize"]
    delivery = value["delivery"]
    if not isinstance(retry, dict) or set(retry) != set(expected["retry"]):
        return False
    if not isinstance(finalize, dict) or set(finalize) != set(expected["finalize"]):
        return False
    if not isinstance(retry["task_attempts"], int) or retry["task_attempts"] < 0:
        return False
    if not isinstance(retry["identical_failures"], int) or retry["identical_failures"] < 0:
        return False
    if not strings_or_none(
        retry,
        ("last_fingerprint", "last_recorded_attempt", "last_failure_class", "last_failure_kind"),
    ):
        return False
    if retry["last_failure_kind"] not in (None, "task", "infrastructure"):
        return False

    if not strings_or_none(
        finalize,
        ("attempt", "baseline_sha", "digest", "stage", "task_path", "task_blob", "commit_sha"),
    ):
        return False
    stage = finalize["stage"]
    if stage not in (None, "failed", *STAGES):
        return False
    if stage is None:
        if any(value is not None for value in finalize.values()):
            return False
    else:
        if not isinstance(finalize["attempt"], str) or not finalize["attempt"]:
            return False
        if not isinstance(finalize["baseline_sha"], str) or not SHA.fullmatch(finalize["baseline_sha"]):
            return False
        if not isinstance(finalize["digest"], str) or not DIGEST.fullmatch(finalize["digest"]):
            return False
        if not isinstance(finalize["task_path"], str) or not finalize["task_path"]:
            return False
        if stage in ("prepared", "committed", "ci_passed", "integrated"):
            if not isinstance(finalize["task_blob"], str) or not SHA.fullmatch(finalize["task_blob"]):
                return False
        elif finalize["task_blob"] is not None:
            return False
        if stage in ("committed", "ci_passed", "integrated"):
            if not isinstance(finalize["commit_sha"], str) or not SHA.fullmatch(finalize["commit_sha"]):
                return False
        elif finalize["commit_sha"] is not None:
            return False

    if delivery is None:
        return True
    if not isinstance(delivery, dict) or set(delivery) != {"attempt", "commit_sha", "task_path", "delivered_at"}:
        return False
    if not all(isinstance(delivery[key], str) and delivery[key] for key in delivery):
        return False
    if not SHA.fullmatch(delivery["commit_sha"]):
        return False
    if stage != "integrated":
        return False
    return delivery["attempt"] == finalize["attempt"] and delivery["commit_sha"] == finalize["commit_sha"] and delivery["task_path"] == finalize["task_path"]


def load(item: str) -> dict[str, Any]:
    target = checkpoint_path(item)
    if not target.exists():
        return default(item)
    try:
        value = json.loads(target.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError("state_invalid") from error
    if not valid(value, item):
        raise ValueError("state_invalid")
    return value


def store(item: str, value: dict[str, Any]) -> None:
    if not valid(value, item):
        raise ValueError("state_invalid")
    target = checkpoint_path(item)
    target.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(dir=target.parent, prefix=".checkpoint.", text=True)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(value, stream, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def begin(value: dict[str, Any], args: argparse.Namespace) -> None:
    finalize = value["finalize"]
    supplied = (args.attempt, args.baseline, args.digest, args.task_path)
    if not all(supplied):
        raise ValueError("begin requires attempt, baseline, digest, and task path")
    if not SHA.fullmatch(args.baseline) or not DIGEST.fullmatch(args.digest):
        raise ValueError("invalid baseline or digest")
    if finalize["stage"] == "integrated":
        if finalize["attempt"] == args.attempt:
            return
        raise ValueError("delivery already integrated")
    if finalize["stage"] not in (None, "failed") and finalize["attempt"] != args.attempt:
        raise ValueError("another attempt is active")
    value["finalize"] = {
        "attempt": args.attempt,
        "baseline_sha": args.baseline,
        "digest": args.digest,
        "stage": "verified",
        "task_path": args.task_path,
        "task_blob": None,
        "commit_sha": None,
    }


def advance(value: dict[str, Any], args: argparse.Namespace) -> None:
    finalize = value["finalize"]
    if finalize["attempt"] != args.attempt or finalize["stage"] in (None, "failed"):
        raise ValueError("attempt is not ready to advance")
    target = args.stage
    if target not in STAGES:
        raise ValueError("invalid stage")
    current = STAGES.index(finalize["stage"])
    wanted = STAGES.index(target)
    if wanted == current:
        return
    if wanted != current + 1:
        raise ValueError("invalid stage transition")
    if target == "prepared":
        if not args.task_blob or not SHA.fullmatch(args.task_blob):
            raise ValueError("prepared requires task blob")
        finalize["task_blob"] = args.task_blob
    elif target in ("committed", "ci_passed", "integrated"):
        if not args.commit or not SHA.fullmatch(args.commit):
            raise ValueError(f"{target} requires commit SHA")
        if finalize["commit_sha"] not in (None, args.commit):
            raise ValueError("commit SHA cannot change")
        finalize["commit_sha"] = args.commit
    finalize["stage"] = target


def record_failure(value: dict[str, Any], args: argparse.Namespace) -> None:
    attempt, kind, failure_class, fingerprint = args.record_failure
    if kind not in ("task", "infrastructure") or not failure_class or not fingerprint:
        raise ValueError("invalid failure")
    retry = value["retry"]
    if retry["last_recorded_attempt"] != attempt:
        if kind == "task":
            retry["task_attempts"] += 1
            retry["identical_failures"] = retry["identical_failures"] + 1 if retry["last_fingerprint"] == fingerprint else 1
            retry["last_fingerprint"] = fingerprint
            retry["last_failure_class"] = failure_class
            retry["last_failure_kind"] = kind
        retry["last_recorded_attempt"] = attempt
    finalize = value["finalize"]
    if finalize["attempt"] == attempt and finalize["stage"] != "integrated":
        finalize["stage"] = "failed"
        finalize["task_blob"] = None
        finalize["commit_sha"] = None


def record_delivery(value: dict[str, Any], args: argparse.Namespace) -> None:
    finalize = value["finalize"]
    if finalize["stage"] != "integrated":
        raise ValueError("delivery requires integrated stage")
    if args.attempt != finalize["attempt"] or args.commit != finalize["commit_sha"]:
        raise ValueError("delivery does not match integrated commit")
    if value["delivery"] is not None:
        return
    value["delivery"] = {
        "attempt": args.attempt,
        "commit_sha": args.commit,
        "task_path": finalize["task_path"],
        "delivered_at": args.delivered_at,
    }


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("item")
    result.add_argument("--begin", action="store_true")
    result.add_argument("--attempt")
    result.add_argument("--baseline")
    result.add_argument("--digest")
    result.add_argument("--task-path")
    result.add_argument("--advance", action="store_true")
    result.add_argument("--stage")
    result.add_argument("--task-blob")
    result.add_argument("--commit")
    result.add_argument("--record-failure", nargs=4, metavar=("ATTEMPT", "KIND", "CLASS", "FINGERPRINT"))
    result.add_argument("--record-delivery", action="store_true")
    result.add_argument("--delivered-at")
    return result


def main() -> int:
    args = parser().parse_args()
    operations = sum((args.begin, args.advance, args.record_failure is not None, args.record_delivery))
    if operations > 1:
        raise ValueError("choose one mutation")
    value = load(args.item)
    if args.begin:
        begin(value, args)
    elif args.advance:
        advance(value, args)
    elif args.record_failure:
        record_failure(value, args)
    elif args.record_delivery:
        if not args.attempt or not args.commit or not args.delivered_at:
            raise ValueError("delivery requires attempt, commit, and delivered-at")
        record_delivery(value, args)
    store(args.item, value)
    print(json.dumps(value, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValueError as error:
        print(str(error), file=os.sys.stderr)
        raise SystemExit(4)
