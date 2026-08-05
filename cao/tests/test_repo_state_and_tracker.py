import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
STATE = ROOT / "cao/scripts/repo-state.sh"
TRACKER = ROOT / "cao/scripts/tracker.sh"


def git_environment(environment=None):
    source = os.environ if environment is None else environment
    return {key: value for key, value in source.items() if not key.startswith("GIT_")}


def command(arguments, *, cwd, environment=None):
    return subprocess.run(arguments, cwd=cwd, env=git_environment(environment), text=True, capture_output=True, check=True)


class RepositoryStateTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.repo = Path(self.directory.name)
        command(["git", "init", "-q"], cwd=self.repo)
        command(["git", "config", "user.name", "CAO test"], cwd=self.repo)
        command(["git", "config", "user.email", "cao-test@example.invalid"], cwd=self.repo)
        (self.repo / "tracked.txt").write_text("baseline\n")
        command(["git", "add", "tracked.txt"], cwd=self.repo)
        command(["git", "commit", "-qm", "baseline"], cwd=self.repo)
        self.environment = {**git_environment(), "CAO_ITEM": "TASK-001"}

    def tearDown(self):
        self.directory.cleanup()

    def state(self, *arguments, check=True):
        return subprocess.run([str(STATE), *arguments], text=True, capture_output=True, env=self.environment, check=check)

    def test_lock_records_task_and_attempt_then_releases(self):
        self.state("acquire-lock", str(self.repo), "task-001.attempt-1")
        owner = json.loads((self.repo / ".cao/repository.lock/owner.json").read_text())

        self.assertEqual(owner["item"], "TASK-001")
        self.assertEqual(owner["root"], "task-001.attempt-1")
        self.state("check-lock", str(self.repo), "task-001.attempt-1")
        reconciliation = self.state("reconcile-lock", str(self.repo), check=False)
        self.assertNotEqual(reconciliation.returncode, 0)
        self.assertIn("owner_unprovable", reconciliation.stdout)

        self.state("release-lock", str(self.repo), "task-001.attempt-1")
        self.assertEqual(self.state("reconcile-lock", str(self.repo)).stdout.strip(), "clear")

    def test_attempt_workspace_uses_cao_branch(self):
        attempt = "task-001.attempt-2"
        self.state("acquire-lock", str(self.repo), attempt)
        workspace = Path(self.state("acquire-workspace", str(self.repo), attempt).stdout.strip())

        self.assertTrue(workspace.is_dir())
        self.assertEqual(command(["git", "branch", "--show-current"], cwd=workspace).stdout.strip(), f"cao/{attempt}")

        self.state("release-workspace", str(self.repo), attempt)
        self.state("release-lock", str(self.repo), attempt)
        self.assertFalse(workspace.exists())


class TrackerSmokeTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.worktree = Path(self.directory.name)
        (self.worktree / "mise.toml").write_text((ROOT / "mise.toml").read_text())
        # mise only auto-trusts config paths that existed at `mise trust --all`
        # time (see Taskfile.dist.yaml); this fixture's mise.toml lives in a
        # fresh tempdir each run, so mise exec needs MISE_YES to skip the
        # interactive trust prompt instead of failing with "couldn't exec".
        environment = {**git_environment(), "MISE_YES": "1"}
        command(
            [
                "mise",
                "exec",
                "--",
                "backlog",
                "init",
                "Tracker fixture",
                "--defaults",
                "--no-git",
                "--backlog-dir",
                "backlog",
                "--config-location",
                "folder",
                "--agent-instructions",
                "none",
            ],
            cwd=self.worktree,
            environment=environment,
        )

    def tearDown(self):
        self.directory.cleanup()

    def tracker(self, *arguments):
        return command([str(TRACKER), "--worktree", str(self.worktree), *arguments], cwd=ROOT)

    def test_next_selects_a_ready_provider_task(self):
        command(
            ["mise", "exec", "--", "backlog", "task", "create", "Ready task", "--priority", "high"],
            cwd=self.worktree,
            environment={**git_environment(), "MISE_YES": "1"},
        )
        listed = self.tracker("list", "--json")
        task_id = json.loads(listed.stdout)["tasks"][0]["id"]

        selected = json.loads(self.tracker("next").stdout)
        shown = json.loads(self.tracker("show", task_id).stdout)

        self.assertEqual(selected["id"], task_id)
        self.assertEqual(shown["task"]["title"], "Ready task")

    def test_next_skips_unfinished_dependencies(self):
        environment = {**git_environment(), "MISE_YES": "1"}
        command(
            ["mise", "exec", "--", "backlog", "task", "create", "Blocked task", "--priority", "high"],
            cwd=self.worktree,
            environment=environment,
        )
        command(
            ["mise", "exec", "--", "backlog", "task", "create", "Prerequisite task", "--priority", "low"],
            cwd=self.worktree,
            environment=environment,
        )
        command(
            ["mise", "exec", "--", "backlog", "task", "create", "Ready task", "--priority", "medium"],
            cwd=self.worktree,
            environment=environment,
        )
        identifiers = {
            task["title"]: task["id"]
            for task in json.loads(self.tracker("list", "--json").stdout)["tasks"]
        }
        command(
            [
                "mise",
                "exec",
                "--",
                "backlog",
                "task",
                "edit",
                identifiers["Blocked task"],
                "--depends-on",
                identifiers["Prerequisite task"],
            ],
            cwd=self.worktree,
            environment=environment,
        )

        selected = json.loads(self.tracker("next").stdout)

        self.assertEqual(selected["id"], identifiers["Ready task"])


if __name__ == "__main__":
    unittest.main()
