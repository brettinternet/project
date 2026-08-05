import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "cao/scripts/retry-state.py"
SHA_A = "a" * 40
SHA_B = "b" * 40
SHA_C = "c" * 40
SHA_D = "d" * 40
DIGEST = "e" * 64


class RetryStateTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.state_root = Path(self.directory.name)
        self.environment = {**os.environ, "CAO_STATE_ROOT": str(self.state_root)}

    def tearDown(self):
        self.directory.cleanup()

    def invoke(self, *arguments, check=True):
        return subprocess.run(
            ["python3", str(SCRIPT), "TASK-001", *arguments],
            text=True,
            capture_output=True,
            env=self.environment,
            check=check,
        )

    def value(self, *arguments):
        return json.loads(self.invoke(*arguments).stdout)

    def test_duplicate_task_failure_and_infrastructure_interruption(self):
        first = self.value("--record-failure", "attempt-1", "task", "gate_failed", "fingerprint")
        duplicate = self.value("--record-failure", "attempt-1", "task", "gate_failed", "fingerprint")
        interrupted = self.value("--record-failure", "attempt-2", "infrastructure", "terminal_lost", "ignored")

        self.assertEqual(first["retry"]["task_attempts"], 1)
        self.assertEqual(duplicate["retry"]["task_attempts"], 1)
        self.assertEqual(interrupted["retry"]["task_attempts"], 1)
        self.assertEqual(interrupted["retry"]["identical_failures"], 1)
        self.assertEqual(interrupted["retry"]["last_fingerprint"], "fingerprint")

    def test_rejects_malformed_checkpoint(self):
        target = self.state_root / ".cao/state/tasks/TASK-001/checkpoint.json"
        target.parent.mkdir(parents=True)
        target.write_text('{"item":"TASK-001"}\n')

        result = self.invoke(check=False)
        self.assertEqual(result.returncode, 4)
        self.assertEqual(result.stderr.strip(), "state_invalid")

    def test_requires_monotonic_finalization_and_idempotent_delivery(self):
        self.value("--begin", "--attempt", "attempt-1", "--baseline", SHA_A, "--digest", DIGEST, "--task-path", "backlog/tasks/task-001.md")
        skipped = self.invoke("--advance", "--attempt", "attempt-1", "--stage", "committed", "--commit", SHA_D, check=False)
        self.assertEqual(skipped.returncode, 4)
        self.assertIn("invalid stage transition", skipped.stderr)

        self.value("--advance", "--attempt", "attempt-1", "--stage", "prepared", "--task-blob", SHA_C)
        self.value("--advance", "--attempt", "attempt-1", "--stage", "committed", "--commit", SHA_D)
        self.value("--advance", "--attempt", "attempt-1", "--stage", "ci_passed", "--commit", SHA_D)
        integrated = self.value("--advance", "--attempt", "attempt-1", "--stage", "integrated", "--commit", SHA_D)
        delivered = self.value("--record-delivery", "--attempt", "attempt-1", "--commit", SHA_D, "--delivered-at", "2026-08-04T00:00:00Z")
        replayed = self.value("--record-delivery", "--attempt", "attempt-1", "--commit", SHA_D, "--delivered-at", "2026-08-05T00:00:00Z")

        self.assertEqual(integrated["finalize"]["stage"], "integrated")
        self.assertEqual(delivered["delivery"]["delivered_at"], "2026-08-04T00:00:00Z")
        self.assertEqual(replayed["delivery"], delivered["delivery"])

    def test_failure_resets_active_attempt_for_retry(self):
        self.value("--begin", "--attempt", "attempt-1", "--baseline", SHA_A, "--digest", DIGEST, "--task-path", "backlog/tasks/task-001.md")
        failed = self.value("--record-failure", "attempt-1", "task", "verification_failed", "fingerprint")
        retried = self.value("--begin", "--attempt", "attempt-2", "--baseline", SHA_B, "--digest", DIGEST, "--task-path", "backlog/tasks/task-001.md")

        self.assertEqual(failed["finalize"]["stage"], "failed")
        self.assertEqual(retried["finalize"]["attempt"], "attempt-2")
        self.assertEqual(retried["finalize"]["stage"], "verified")


if __name__ == "__main__":
    unittest.main()
