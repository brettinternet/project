import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
LAUNCH_PHASE = ROOT / "cao/scripts/launch-phase.sh"


class LaunchPhaseTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.repo = Path(self.directory.name)
        self.scripts = self.repo / "cao/scripts"
        self.scripts.mkdir(parents=True)
        shutil.copy2(LAUNCH_PHASE, self.scripts / "launch-phase.sh")
        self._write_executable(
            self.scripts / "repo-state.sh",
            """#!/usr/bin/env bash
case "$1" in
  set-terminal) ;;
  digest) printf '%s\\n' test-digest ;;
  *) exit 2 ;;
esac
""",
        )
        self.bin = self.repo / "bin"
        self.bin.mkdir()
        self.arguments = self.repo / "cao-arguments.json"
        self._write_executable(
            self.bin / "cao",
            """#!/usr/bin/env python3
import json
import os
import sys
Path = __import__('pathlib').Path
Path(os.environ['CAO_TEST_ARGUMENTS']).write_text(json.dumps(sys.argv[1:]))
print(json.dumps({'session_name': 'cao-generated'}))
""",
        )
        self._write_executable(
            self.bin / "curl",
            """#!/usr/bin/env bash
url=${!#}
case "$url" in
  */sessions/*/terminals) printf '%s\\n' '[{"id":"terminal-1"}]' ;;
  */terminals/terminal-1) printf '%s\\n' '{"status":"completed"}' ;;
  *) exit 2 ;;
esac
""",
        )

    def tearDown(self):
        self.directory.cleanup()

    def _write_executable(self, path, content):
        path.write_text(content)
        path.chmod(0o755)

    def test_uses_installed_profiles_without_custom_session_names(self):
        attempt = "task-001.20260805T142127Z.ef7eb1"
        for phase, profile, provider in (
            ("implement", "project-implementer", "codex"),
            ("verify", "project-verifier", "opencode_cli"),
        ):
            with self.subTest(phase=phase):
                environment = {
                    **os.environ,
                    "CAO_PHASE_POLL_SECONDS": "1",
                    "CAO_TEST_ARGUMENTS": str(self.arguments),
                    "PATH": f"{self.bin}:{os.environ['PATH']}",
                }
                subprocess.run(
                    [
                        str(self.scripts / "launch-phase.sh"),
                        phase,
                        "TASK-001",
                        attempt,
                        str(self.repo),
                    ],
                    cwd=self.repo,
                    env=environment,
                    text=True,
                    capture_output=True,
                    check=True,
                )
                arguments = json.loads(self.arguments.read_text())

                self.assertEqual(arguments[:2], ["launch", "--agents"])
                self.assertEqual(arguments[2], profile)
                self.assertIn(provider, arguments)
                self.assertNotIn("--session-name", arguments)
                self.assertIn(attempt, arguments[-1])


if __name__ == "__main__":
    unittest.main()
