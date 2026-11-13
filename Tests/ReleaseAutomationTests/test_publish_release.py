import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "publish-release.sh"


class PublisherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.repo = base / "repo"
        self.repo.mkdir()
        self.remote = base / "remote.git"
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Release Test")
        self.git("config", "user.email", "release-test@example.invalid")
        subprocess.run(["git", "init", "--bare", "-q", str(self.remote)], check=True)
        self.git("remote", "add", "origin", str(self.remote))
        self.git("commit", "--allow-empty", "-m", "initial")
        self.commit = self.git("rev-parse", "HEAD")
        self.git("push", "-q", "-u", "origin", "main")
        bindir = base / "bin"
        bindir.mkdir()
        gh = bindir / "gh"
        gh.write_text("""#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
if args[:2] == ['release', 'list']:
    if os.environ.get('MOCK_GH_FAIL') == '1':
        sys.exit(1)
    print(os.environ.get('MOCK_GH_RELEASES', '[]'))
else:
    with open(os.environ['MOCK_GH_LOG'], 'a') as log:
        log.write(json.dumps(args) + '\\n')
""")
        gh.chmod(0o755)
        self.log = base / "gh-calls"
        self.env = os.environ.copy()
        self.env.update({"PATH": f"{bindir}:{self.env['PATH']}", "GITHUB_REPOSITORY": "owner/repo",
                         "GITHUB_SHA": self.commit, "MOCK_GH_LOG": str(self.log)})
        self.files = [base / "app.dmg", base / "app.dmg.sha256", base / "notes.md"]
        for file in self.files:
            file.write_text("fixture")

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], check=True, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.strip()

    def run_publisher(self, releases=None):
        env = dict(self.env)
        if releases is not None:
            env["MOCK_GH_RELEASES"] = json.dumps(releases)
        return subprocess.run([str(SCRIPT), "v1.0.0", *map(str, self.files)], cwd=self.repo, env=env,
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def tag_current(self):
        self.git("tag", "v1.0.0")
        self.git("push", "-q", "origin", "v1.0.0")

    def test_creates_release_at_the_exact_commit(self):
        result = self.run_publisher([])
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][:3], ["release", "create", "v1.0.0"])
        self.assertIn(self.commit, calls[0])
        self.assertIn(str(self.files[0]), calls[0])
        self.assertIn(str(self.files[1]), calls[0])

    def test_resumes_a_draft_at_the_same_commit(self):
        self.tag_current()
        result = self.run_publisher([{"tagName": "v1.0.0", "isDraft": True}])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[1] for call in self.calls()], ["upload", "edit"])
        self.assertIn("--draft=false", self.calls()[1])

    def test_never_overwrites_a_published_release(self):
        self.tag_current()
        result = self.run_publisher([{"tagName": "v1.0.0", "isDraft": False}])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already published", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_never_reuses_a_tag_for_another_commit(self):
        self.tag_current()
        self.git("commit", "--allow-empty", "-m", "new commit")
        self.env["GITHUB_SHA"] = self.git("rev-parse", "HEAD")
        result = self.run_publisher([])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to overwrite", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_does_not_publish_when_release_list_fails(self):
        self.env["MOCK_GH_FAIL"] = "1"
        result = self.run_publisher()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
