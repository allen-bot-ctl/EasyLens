"""Check the exact workflow's Git ref gate against sibling and ancestor tags."""
import os
import pathlib
import subprocess
import tempfile
import unittest


def cmd(directory, *args, **extra):
    return subprocess.run(args, cwd=directory, text=True, capture_output=True, **extra)


def git(directory, *args):
    return cmd(directory, "git", *args, check=True).stdout.strip()


class ReleaseWorkflowRef(unittest.TestCase):
    def test_git_provenance_for_ancestor_and_non_master_tag(self):
        path = pathlib.Path(__file__).resolve().parents[2] / ".github/workflows/release.yml"
        lines = path.read_text().splitlines()
        start = next(i for i, line in enumerate(lines) if "git fetch --no-tags origin" in line)
        fragment = "set -euo pipefail\n" + "\n".join(line.strip() for line in lines[start:start+3])
        self.assertIn("git merge-base --is-ancestor", fragment)
        with tempfile.TemporaryDirectory() as tmp:
            origin = pathlib.Path(tmp) / "origin"
            origin.mkdir()
            git(origin, "init", "-q", "-b", "master")
            git(origin, "config", "user.email", "test@example.invalid")
            git(origin, "config", "user.name", "Fixture")
            git(origin, "commit", "-q", "--allow-empty", "-m", "historical ancestor")
            ancestor = git(origin, "rev-parse", "HEAD")
            git(origin, "tag", "v0.1.1")
            git(origin, "checkout", "-qb", "sibling")
            git(origin, "commit", "-q", "--allow-empty", "-m", "untrusted sibling")
            sibling = git(origin, "rev-parse", "HEAD")
            git(origin, "tag", "v0.1.2")
            git(origin, "checkout", "-q", "master")
            git(origin, "commit", "-q", "--allow-empty", "-m", "trusted master")
            for name, sha, expected in (("v0.1.1", ancestor, 0), ("v0.1.2", sibling, 1),
                                        ("v0.1.1", sibling, 1)):
                with self.subTest(tag=name, sha=sha):
                    with tempfile.TemporaryDirectory(dir=tmp) as runner:
                        git(runner, "init", "-q")
                        git(runner, "remote", "add", "origin", str(origin))
                        result = cmd(runner, "bash", "-c", f"sha={sha}\n" + fragment,
                                     env={**os.environ, "TAG": name})
                        self.assertEqual(result.returncode, expected, result.stderr)


if __name__ == "__main__":
    unittest.main()
