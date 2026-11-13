"""Tests for release.py, each in a throwaway git repo:  python .github/scripts/test_release.py"""
import os
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "release.py")


class Repo:
    def __init__(self):
        self.dir = tempfile.mkdtemp()
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "t@example.com")
        self.git("config", "user.name", "t")
        self.git("config", "commit.gpgsign", "false")
        self.n = 0

    def git(self, *a):
        return subprocess.run(["git", *a], cwd=self.dir, check=True, capture_output=True, text=True).stdout.strip()

    def commit(self, msg):
        self.n += 1
        with open(os.path.join(self.dir, "f.txt"), "w") as f:
            f.write(str(self.n))
        self.git("add", "-A")
        self.git("commit", "-q", "-m", msg)

    def tag(self, t):
        self.git("tag", t)

    def run(self, *args):
        env = dict(os.environ)
        env.pop("GITHUB_OUTPUT", None)
        p = subprocess.run([sys.executable, SCRIPT, *args], cwd=self.dir, capture_output=True, text=True, env=env)
        out = dict(line.split("=", 1) for line in p.stdout.splitlines() if "=" in line)
        out["_code"] = p.returncode
        out["_err"] = p.stderr
        path = os.path.join(self.dir, "CHANGELOG.md")
        out["_log"] = ""
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                out["_log"] = f.read()
        return out


class AlphaTests(unittest.TestCase):
    def repo(self):
        r = Repo()
        r.commit("feat: first")
        r.tag("v0.9.1")
        return r

    def test_docs_only_makes_no_release(self):
        r = self.repo()
        r.commit("docs: readme")
        r.commit("ci: workflow")
        self.assertEqual(r.run("alpha")["release"], "false")

    def test_fix_bumps_patch(self):
        r = self.repo()
        r.commit("fix(craft): wrong cost")
        out = r.run("alpha")
        self.assertEqual(out["tag"], "v0.9.2-alpha.1")
        self.assertIn("## Bug fixes", out["_log"])
        self.assertIn("**craft:** wrong cost", out["_log"])

    def test_feat_bumps_minor(self):
        r = self.repo()
        r.commit("fix: a")
        r.commit("feat: b")
        self.assertEqual(r.run("alpha")["tag"], "v0.10.0-alpha.1")

    def test_breaking_bumps_major(self):
        r = self.repo()
        r.commit("feat!: new saved data format")
        self.assertEqual(r.run("alpha")["tag"], "v1.0.0-alpha.1")
        r2 = self.repo()
        r2.commit("refactor: x\n\nBREAKING CHANGE: removed /ledger foo")
        self.assertEqual(r2.run("alpha")["tag"], "v1.0.0-alpha.1")

    def test_alpha_number_counts_up(self):
        r = self.repo()
        r.commit("feat: b")
        r.tag("v0.10.0-alpha.1")
        r.commit("fix: c")
        self.assertEqual(r.run("alpha")["tag"], "v0.10.0-alpha.2")

    def test_no_new_alpha_without_releasable_change(self):
        r = self.repo()
        r.commit("feat: b")
        r.tag("v0.10.0-alpha.1")
        r.commit("docs: d")
        self.assertEqual(r.run("alpha")["release"], "false")

    def test_bigger_change_after_alpha_moves_version(self):
        r = self.repo()
        r.commit("fix: a")
        r.tag("v0.9.2-alpha.1")
        r.commit("feat: b")
        self.assertEqual(r.run("alpha")["tag"], "v0.10.0-alpha.1")


class PromoteTests(unittest.TestCase):
    def test_promotes_newest_alpha(self):
        r = Repo()
        r.commit("feat: a")
        r.tag("v0.9.1")
        r.commit("feat: b")
        r.tag("v0.10.0-alpha.1")
        r.commit("fix: c")
        r.tag("v0.10.0-alpha.2")
        r.commit("fix: d (not in the alpha)")
        out = r.run("promote")
        self.assertEqual(out["tag"], "v0.10.0")
        self.assertEqual(out["sha"], r.git("rev-list", "-n", "1", "v0.10.0-alpha.2"))
        self.assertIn("- b", out["_log"])
        self.assertNotIn("not in the alpha", out["_log"])

    def test_tag_already_on_the_alpha_is_fine(self):
        r = Repo()
        r.commit("feat: a")
        r.tag("v0.9.1")
        r.commit("fix: b")
        r.tag("v0.9.2-alpha.1")
        r.tag("v0.9.2")
        out = r.run("promote", "v0.9.2-alpha.1")
        self.assertEqual(out["_code"], 0, out["_err"])
        self.assertEqual(out["tag"], "v0.9.2")
        self.assertIn("- b", out["_log"])
        self.assertNotIn("- a", out["_log"])

    def test_refuses_tag_elsewhere_or_unknown_alpha(self):
        r = Repo()
        r.commit("feat: a")
        r.tag("v0.10.0")
        r.commit("fix: b")
        r.tag("v0.10.0-alpha.1")
        self.assertNotEqual(r.run("promote", "v0.10.0-alpha.1")["_code"], 0)
        self.assertNotEqual(r.run("promote", "v9.9.9-alpha.1")["_code"], 0)


if __name__ == "__main__":
    unittest.main()
