"""Exercise immutable tag recovery with real, isolated Git repositories."""

import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = Path(os.environ.get("SWIFT_RELEASE_WORKFLOW_PATH", ROOT / ".github/workflows/publish-cocoapods.yml"))


def identity_script():
    source = WORKFLOW.read_text()
    section = source.split("      - name: Resolve immutable Git release\n", 1)[1]
    block = section.split("        run: |\n", 1)[1].split("\n      - name:", 1)[0]
    return textwrap.dedent(block)


class ImmutableReleaseTagTests(unittest.TestCase):
    def exercise(self, mismatch=False):
        with tempfile.TemporaryDirectory(prefix="debugbundle-swift-tag-") as directory:
            root = Path(directory)
            origin = root / "origin"
            origin.mkdir()

            def git(cwd, *args):
                return subprocess.check_output(["git", "-C", str(cwd), *args], text=True, stderr=subprocess.DEVNULL).strip()

            git(origin, "init", "--initial-branch=main")
            git(origin, "config", "user.name", "Synthetic Release Test")
            git(origin, "config", "user.email", "release-test@example.invalid")
            (origin / "source.txt").write_text("qualified SDK source\n")
            git(origin, "add", "source.txt")
            git(origin, "commit", "-m", "Qualified source")
            qualified = git(origin, "rev-parse", "HEAD")
            if mismatch:
                (origin / "source.txt").write_text("different SDK source\n")
                git(origin, "commit", "-am", "Different source")
            git(origin, "tag", "-a", "v3.1.5", "-m", "Immutable release")
            remote_tag = git(origin, "rev-parse", "v3.1.5")

            checkout = root / "checkout"
            checkout.mkdir()
            git(checkout, "init", "--initial-branch=main")
            git(checkout, "remote", "add", "origin", str(origin))
            git(checkout, "fetch", "--no-tags", "origin", "main")
            git(checkout, "checkout", "--detach", qualified)
            git(checkout, "tag", "v3.1.5")
            local_tag = git(checkout, "rev-parse", "v3.1.5")
            commands = root / "bin"
            commands.mkdir()
            ruby = commands / "ruby"
            ruby.write_text("#!/bin/sh\nprintf '3.1.5\\n'\n")
            ruby.chmod(0o755)
            env = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ["PATH"],
                       GITHUB_OUTPUT=str(root / "outputs"), GITHUB_SHA="0" * 40,
                       GITHUB_REPOSITORY="debugbundle/debugbundle-swift")
            result = subprocess.run(["bash", "-c", identity_script()], cwd=checkout, env=env,
                                    text=True, capture_output=True)
            self.assertEqual(git(origin, "rev-parse", "v3.1.5"), remote_tag)
            self.assertEqual(git(checkout, "rev-parse", "v3.1.5"), local_tag)
            return result

    def test_annotated_remote_and_lightweight_checkout_preserve_the_qualified_source(self):
        result = self.exercise()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_different_remote_source_fails_without_rewriting_tags(self):
        result = self.exercise(mismatch=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match the checked-out SDK source", result.stderr)


if __name__ == "__main__":
    unittest.main()
