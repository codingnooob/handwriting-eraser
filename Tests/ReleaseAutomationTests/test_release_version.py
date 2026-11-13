import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Scripts"))
from release_version import classify_commit, plan_release  # noqa: E402


class ReleasePolicyTests(unittest.TestCase):
    def test_initial_release_has_a_stable_version(self):
        plan = plan_release(None, ["docs: initial readme"])
        self.assertEqual((plan.tag, plan.change, plan.should_release), ("v1.0.0", "initial", True))

    def test_non_releasing_commits_leave_the_version_alone(self):
        messages = ["docs: improve usage", "ci: update runner", "chore(deps): refresh", "refactor: clean up"]
        plan = plan_release("v2.4.3", messages)
        self.assertEqual((plan.tag, plan.change, plan.should_release), ("v2.4.3", "none", False))

    def test_features_fixes_performance_and_explicit_release_are_minor(self):
        for message in ["feat: add a mode", "fix(import): handle scans", "perf: speed up inference", "release: refresh the package"]:
            with self.subTest(message=message):
                plan = plan_release("v2.4.3", [message])
                self.assertEqual((plan.tag, plan.change, plan.should_release), ("v2.5.0", "minor", True))

    def test_breaking_changes_take_priority(self):
        for message in ["feat(api)!: change behavior", "chore!: drop a platform", "docs: migration\n\nBREAKING CHANGE: new format", "fix: migration\n\nBREAKING-CHANGE: new behavior"]:
            with self.subTest(message=message):
                plan = plan_release("v1.7.0", ["feat: another thing", message])
                self.assertEqual((plan.tag, plan.change, plan.should_release), ("v2.0.0", "major", True))

    def test_unconventional_commits_and_non_footer_mentions_do_not_release(self):
        self.assertEqual(classify_commit("Update docs"), "none")
        self.assertEqual(classify_commit("docs: mention BREAKING CHANGE: as an example"), "none")
        self.assertEqual(classify_commit("Revert feat: something"), "none")

    def test_invalid_published_tag_is_rejected(self):
        for tag in ["1.2.0", "v1.02.0", "v1.0.0-beta", "v1.2"]:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                plan_release(tag, ["feat: new"])

    def test_cli_checks_every_commit_since_the_published_release(self):
        with tempfile.TemporaryDirectory() as directory:
            def git(*args):
                return subprocess.run(["git", "-C", directory, *args], check=True, text=True,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.strip()
            git("init", "-q")
            git("config", "user.name", "Release Test")
            git("config", "user.email", "release-test@example.invalid")
            git("commit", "--allow-empty", "-m", "initial")
            git("tag", "v1.2.0")
            git("commit", "--allow-empty", "-m", "feat: new feature")
            git("commit", "--allow-empty", "-m", "docs: latest commit")
            output_file = Path(directory) / "outputs"
            result = subprocess.run([sys.executable, str(ROOT / "Scripts/release_version.py"),
                                     "--last-tag", "v1.2.0", "--github-output", str(output_file)],
                                    cwd=directory, check=True, text=True, stdout=subprocess.PIPE)
            self.assertEqual(json.loads(result.stdout), {"tag": "v1.3.0", "version": "1.3.0", "change": "minor", "should_release": True})
            self.assertIn("should_release=true\n", output_file.read_text())
            git("tag", "v1.3.0")
            git("commit", "--allow-empty", "-m", "docs: no new package")
            result = subprocess.run([sys.executable, str(ROOT / "Scripts/release_version.py"), "--last-tag", "v1.3.0"],
                                    cwd=directory, check=True, text=True, stdout=subprocess.PIPE)
            self.assertEqual(json.loads(result.stdout)["tag"], "v1.3.0")
            self.assertFalse(json.loads(result.stdout)["should_release"])

    def test_cli_refuses_a_release_from_a_stale_commit(self):
        with tempfile.TemporaryDirectory() as directory:
            def git(*args):
                return subprocess.run(["git", "-C", directory, *args], check=True, text=True,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.strip()
            git("init", "-q")
            git("config", "user.name", "Release Test")
            git("config", "user.email", "release-test@example.invalid")
            git("commit", "--allow-empty", "-m", "initial")
            stale = git("rev-parse", "HEAD")
            git("commit", "--allow-empty", "-m", "feat: newer")
            git("tag", "v1.0.0")
            result = subprocess.run([sys.executable, str(ROOT / "Scripts/release_version.py"),
                                     "--last-tag", "v1.0.0", "--head", stale], cwd=directory,
                                    text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("not an ancestor", result.stderr)


if __name__ == "__main__":
    unittest.main()
