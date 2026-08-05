import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
FINALIZER = ROOT / "cao/scripts/finalize.sh"


class FinalizerFailurePathTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.repo = Path(self.directory.name)
        self.bin = self.repo / "bin"
        self.bin.mkdir()
        self.calls = self.repo / "tracker.calls"
        self.state = self.bin / "state.sh"
        self.tracker = self.bin / "tracker.sh"
        self.checkpoint = self.bin / "checkpoint.py"
        self.state.write_text(
            "#!/usr/bin/env bash\n"
            "case $1 in check-lock|release-lock) exit 0;; *) exit 2;; esac\n"
        )
        self.tracker.write_text(
            "#!/usr/bin/env bash\n"
            "printf '%s\\n' \"$*\" >> \"$CAO_TEST_TRACKER_CALLS\"\n"
        )
        self.checkpoint.write_text(
            "#!/usr/bin/env python3\n"
            "import json\n"
            "print(json.dumps({'retry': {'task_attempts': 0, 'identical_failures': 0}}))\n"
        )
        for script in (self.state, self.tracker, self.checkpoint):
            script.chmod(0o755)

    def tearDown(self):
        self.directory.cleanup()

    def test_missing_implementation_preserves_failure_evidence_and_releases(self):
        environment = {
            **os.environ,
            "CAO_STATE_SCRIPT": str(self.state),
            "CAO_TRACKER_SCRIPT": str(self.tracker),
            "CAO_CHECKPOINT_SCRIPT": str(self.checkpoint),
            "CAO_TEST_TRACKER_CALLS": str(self.calls),
        }
        result = subprocess.run(
            [str(FINALIZER), str(self.repo), "task-001.attempt-1", "TASK-001"],
            text=True,
            capture_output=True,
            env=environment,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        final = json.loads((self.repo / ".cao/work/task-001.attempt-1/final.json").read_text())
        self.assertEqual(final["outcome"], "fail")
        self.assertEqual(final["failure_class"], "implementer_vanished")
        calls = self.calls.read_text()
        self.assertIn("note TASK-001", calls)
        self.assertIn("release TASK-001", calls)
    def test_lost_lock_does_not_release_provider_task(self):
        self.state.write_text("#!/usr/bin/env bash\ncase $1 in check-lock) exit 1;; release-lock) exit 0;; *) exit 2;; esac\n")
        environment = {
            **os.environ,
            "CAO_STATE_SCRIPT": str(self.state),
            "CAO_TRACKER_SCRIPT": str(self.tracker),
            "CAO_CHECKPOINT_SCRIPT": str(self.checkpoint),
            "CAO_TEST_TRACKER_CALLS": str(self.calls),
        }

        result = subprocess.run(
            [str(FINALIZER), str(self.repo), "task-001.attempt-2", "TASK-001"],
            text=True,
            capture_output=True,
            env=environment,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        final = json.loads((self.repo / ".cao/work/task-001.attempt-2/final.json").read_text())
        self.assertEqual(final["failure_class"], "ownership_violation")
        self.assertFalse(self.calls.exists())


class FinalizerIntegrationTest(unittest.TestCase):
    """The provider rewrites `updated_date` on release, which dirties the task file
    in the primary checkout. Finalization must restore it, or the fast-forward is
    refused on the exact path it is about to change."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.repo = Path(self.directory.name) / "repo"
        self.repo.mkdir(parents=True)
        self.task_path = "backlog/tasks/task-001 - probe.md"
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "CAO test")
        self.git("config", "user.email", "cao-test@example.invalid")
        (self.repo / "backlog/tasks").mkdir(parents=True)
        (self.repo / self.task_path).write_text("updated_date: baseline\nstatus: To Do\n")
        (self.repo / "code.txt").write_text("baseline\n")
        self.git("add", "-A")
        self.git("commit", "-qm", "baseline")
        self.baseline = self.git("rev-parse", "HEAD").stdout.strip()

        # finalize.sh derives the worktree path from the attempt root.
        self.worktree = self.repo / ".worktrees/attempt-1"
        self.git("worktree", "add", "--quiet", "-b", "cao/attempt-1", str(self.worktree), self.baseline)
        (self.worktree / "code.txt").write_text("implemented\n")
        (self.worktree / self.task_path).write_text("updated_date: attempt\nstatus: Done\n")

        self.bin = Path(self.directory.name) / "bin"
        self.bin.mkdir()
        self.scripts = Path(self.directory.name) / "scripts"
        self.scripts.mkdir()
        self.write_executable(
            self.bin / "task",
            "#!/usr/bin/env bash\nexit 0\n",
        )
        self.write_executable(
            self.scripts / "state.sh",
            "#!/usr/bin/env bash\n"
            "case $1 in\n"
            "  check-lock|release-lock|release-workspace) ;;\n"
            "  digest) printf '%s\\n' " + "e" * 64 + " ;;\n"
            f"  changed-files) printf '%s\\n' code.txt '{self.task_path}' ;;\n"
            "  *) exit 2 ;;\n"
            "esac\n",
        )
        # Mutating the primary task file is what the real provider does on both
        # prepare-complete and release.
        self.write_executable(
            self.scripts / "tracker.sh",
            "#!/usr/bin/env bash\n"
            'printf "updated_date: provider-touched\\n" >"$CAO_TEST_PRIMARY_TASK"\n'
            'while [[ $# -gt 0 ]]; do case $1 in show) printf \'{"task":{"path":"%s"}}\\n\' '
            '"$CAO_TEST_TASK_PATH"; exit 0;; esac; shift; done\n',
        )
        self.write_executable(
            self.scripts / "checkpoint.py",
            "#!/usr/bin/env python3\nimport json\nprint(json.dumps({'retry': {'task_attempts': 0, 'identical_failures': 0}}))\n",
        )

        work = self.repo / ".cao/work/attempt-1"
        work.mkdir(parents=True)
        for phase, name in (("implement", "implementation.json"), ("verify", "verify.json")):
            artifact = {
                "phase": phase,
                "status": "complete",
                "outcome": "pass",
                "item": "TASK-001",
                "workflow_root": "attempt-1",
                "baseline_sha": self.baseline,
                "digest": "e" * 64,
                "changed_files": ["code.txt"],
                "summary": "Probe.",
                "commit_subject": "chore(TASK-001): probe",
                "commit_body": "Probe.\n\nTask: TASK-001",
            }
            (work / name).write_text(json.dumps(artifact))

    def tearDown(self):
        self.directory.cleanup()

    def git(self, *arguments):
        environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        return subprocess.run(
            ["git", "-C", str(self.repo), *arguments], text=True, capture_output=True, check=True, env=environment
        )

    def write_executable(self, path, content):
        path.write_text(content)
        path.chmod(0o755)

    def test_provider_touched_task_file_does_not_block_the_fast_forward(self):
        environment = {
            **{key: value for key, value in os.environ.items() if not key.startswith("GIT_")},
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "CAO_STATE_SCRIPT": str(self.scripts / "state.sh"),
            "CAO_TRACKER_SCRIPT": str(self.scripts / "tracker.sh"),
            "CAO_CHECKPOINT_SCRIPT": str(self.scripts / "checkpoint.py"),
            "CAO_TEST_TASK_PATH": self.task_path,
            "CAO_TEST_PRIMARY_TASK": str(self.repo / self.task_path),
        }

        result = subprocess.run(
            [str(FINALIZER), str(self.repo), "attempt-1", "TASK-001"],
            text=True,
            capture_output=True,
            env=environment,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        final = json.loads((self.repo / ".cao/work/attempt-1/final.json").read_text())
        self.assertEqual(final["outcome"], "pass", final)
        self.assertEqual(
            self.git("rev-parse", "refs/heads/main").stdout.strip(),
            self.git("rev-parse", "refs/heads/cao/attempt-1").stdout.strip(),
        )
        self.assertEqual((self.repo / "code.txt").read_text(), "implemented\n")

    def test_failed_attempt_commits_provider_bookkeeping_and_leaves_a_clean_tree(self):
        # A failed attempt still writes a note and releases the claim, both of which
        # mutate the task file in the primary checkout. Left uncommitted, that file
        # makes the next attempt's fast-forward fail on a path nobody owns.
        self.git("worktree", "remove", "--force", str(self.worktree))
        self.write_executable(
            self.scripts / "tracker.sh",
            "#!/usr/bin/env bash\n"
            'printf "updated_date: provider-touched\\n" >"$CAO_TEST_PRIMARY_TASK"\n',
        )
        environment = {
            **{key: value for key, value in os.environ.items() if not key.startswith("GIT_")},
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "CAO_STATE_SCRIPT": str(self.scripts / "state.sh"),
            "CAO_TRACKER_SCRIPT": str(self.scripts / "tracker.sh"),
            "CAO_CHECKPOINT_SCRIPT": str(self.scripts / "checkpoint.py"),
            "CAO_TEST_TASK_PATH": self.task_path,
            "CAO_TEST_PRIMARY_TASK": str(self.repo / self.task_path),
        }

        result = subprocess.run(
            [str(FINALIZER), str(self.repo), "attempt-1", "TASK-001"],
            text=True,
            capture_output=True,
            env=environment,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        final = json.loads((self.repo / ".cao/work/attempt-1/final.json").read_text())
        self.assertEqual(final["outcome"], "fail")
        # `.cao/` is gitignored in a real repository; the fixture has no ignore file.
        self.assertEqual(self.git("status", "--porcelain", "--untracked-files=no").stdout, "")
        self.assertIn("provider-touched", (self.repo / self.task_path).read_text())


if __name__ == "__main__":
    unittest.main()
