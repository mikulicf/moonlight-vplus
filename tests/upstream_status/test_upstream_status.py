import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("upstream_status", Path(__file__).parents[2] / "scripts/upstream-status.py")
status = importlib.util.module_from_spec(spec)
spec.loader.exec_module(status)


class UpstreamStatusTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.invalid")
        self.base = self.commit("base")

    def git(self, *args):
        return status.git(self.repo, *args)

    def commit(self, message):
        self.git("commit", "--allow-empty", "-qm", message)
        return self.git("rev-parse", "HEAD")

    def test_both_upstreams_and_unique_count(self):
        common = self.commit("shared incoming change")
        vplus = self.commit("V+ incoming change")
        self.git("update-ref", "refs/remotes/upstream/master", vplus)
        self.git("checkout", "-q", "--detach", common)
        moonlight = self.commit("Moonlight incoming change")
        self.git("update-ref", "refs/remotes/moonlight/master", moonlight)
        self.git("checkout", "-q", "--detach", self.base)
        reports = status.collect(self.repo, "HEAD", {})
        self.assertEqual([r["behind"] for r in reports], [2, 2])
        self.assertIn("Unique pending commits across both upstreams: 3", status.render(reports))
        self.assertEqual(self.git("rev-parse", "HEAD"), self.base)

    def test_cherry_pick_provenance_and_reviewed_decisions(self):
        applied = self.commit("upstream change")
        reviewed = self.commit("reviewed change")
        for remote in status.UPSTREAMS:
            self.git("update-ref", f"refs/remotes/{remote}/master", reviewed)
        self.git("checkout", "-q", "--detach", self.base)
        self.commit(f"local implementation\n\n(cherry picked from commit {applied})")
        reports = status.collect(self.repo, "HEAD", {reviewed[:8]: "Already covered"})
        self.assertEqual([c["status"] for c in reports[0]["commits"]], ["reviewed", "applied"])
        self.assertIn("Unique pending commits across both upstreams: 0", status.render(reports))

    def test_missing_upstream_fails_instead_of_reporting_current(self):
        self.git("update-ref", "refs/remotes/upstream/master", self.base)
        with self.assertRaises(subprocess.CalledProcessError):
            status.collect(self.repo, "HEAD", {})

    def test_existing_remote_is_not_silently_repointed(self):
        self.git("remote", "add", "upstream", "https://example.invalid/another/repo.git")
        with self.assertRaises(ValueError):
            status.configure_remotes(self.repo)
        self.assertEqual(self.git("remote", "get-url", "upstream"), "https://example.invalid/another/repo.git")

    def test_ssh_remote_is_preserved_and_push_is_disabled(self):
        self.git("remote", "add", "upstream", "git@github.com:qiin2333/moonlight-qt.git")
        status.configure_remotes(self.repo)
        for name in status.UPSTREAMS:
            self.assertEqual(self.git("remote", "get-url", "--push", name), "DISABLED")


if __name__ == "__main__":
    unittest.main()
