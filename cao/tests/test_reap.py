import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("reap", ROOT / "cao/scripts/reap.py")
reap = importlib.util.module_from_spec(SPEC)
sys.modules["reap"] = reap
assert SPEC.loader is not None
SPEC.loader.exec_module(reap)


class ReaperTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.repo = Path(self.directory.name)
        self.events = self.repo / ".cao/state/events.jsonl"
        self.events.parent.mkdir(parents=True)
        self.event = {
            "task": "TASK-001",
            "attempt": "task-001.1",
            "phase": "implement",
            "session": "cao-implement-task-001.1",
            "terminal": "terminal-1",
            "worktree": str(self.repo / ".worktrees/task-001.1"),
            "digest": "a" * 64,
        }
        self.events.write_text(json.dumps(self.event) + "\n")

    def tearDown(self):
        self.directory.cleanup()

    def only_event(self):
        return reap.load_events(self.events)[0]

    def test_waiting_user_answer_is_never_reaped(self):
        with patch.object(reap, "terminal_status", return_value=("waiting_user_answer", None)), patch.object(reap, "shutdown") as shutdown:
            result = reap.inspect_event(self.repo, "http://unused", self.only_event(), False)

        self.assertEqual(result, "keep terminal-1: waiting_user_answer")
        shutdown.assert_not_called()

    def test_missing_terminal_with_live_tmux_is_protected(self):
        with patch.object(reap, "terminal_status", return_value=(None, "missing")), patch.object(reap, "tmux_status", return_value=True), patch.object(reap, "shutdown") as shutdown:
            result = reap.inspect_event(self.repo, "http://unused", self.only_event(), False)

        self.assertEqual(result, "keep terminal-1: tmux session still exists")
        shutdown.assert_not_called()

    def test_missing_terminal_with_changed_digest_is_protected(self):
        with patch.object(reap, "terminal_status", return_value=(None, "missing")), patch.object(reap, "tmux_status", return_value=False), patch.object(reap, "current_digest", return_value="b" * 64), patch.object(reap, "shutdown") as shutdown:
            result = reap.inspect_event(self.repo, "http://unused", self.only_event(), False)

        self.assertEqual(result, "keep terminal-1: worktree digest changed")
        shutdown.assert_not_called()

    def test_dead_owned_terminal_is_reaped_and_recorded(self):
        with patch.object(reap, "terminal_status", return_value=("completed", None)), patch.object(reap, "shutdown", return_value=True):
            result = reap.inspect_event(self.repo, "http://unused", self.only_event(), False)

        self.assertEqual(result, "reaped terminal-1: terminal is no longer live")
        reap.append_reaped(self.events, self.only_event())
        history = [json.loads(line) for line in self.events.read_text().splitlines()]
        self.assertEqual(history[-1]["kind"], "reaped")
        self.assertEqual(history[-1]["terminal"], "terminal-1")
        self.assertEqual(reap.load_events(self.events), [])

    def test_api_failure_fails_closed(self):
        with patch.object(reap, "terminal_status", return_value=(None, "api_error")), patch.object(reap, "shutdown") as shutdown:
            result = reap.inspect_event(self.repo, "http://unused", self.only_event(), False)

        self.assertEqual(result, "keep terminal-1: CAO API unavailable")
        shutdown.assert_not_called()


if __name__ == "__main__":
    unittest.main()
