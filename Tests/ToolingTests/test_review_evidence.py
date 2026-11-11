"""Agent-neutral tests; isolated Git fixtures never touch the user's index."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("prepare_review", ROOT / "Scripts/prepare-review.py")
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)


class ReviewEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name) / "repo"
        self.repo.mkdir()
        self.out = Path(self.tmp.name) / "evidence"
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        (self.repo / "source.swift").write_text("old\n")
        self.git("add", ".")
        self.git("commit", "-qm", "base")
        self.base = self.git("rev-parse", "HEAD").strip()
        (self.repo / "source.swift").write_text("new\n")
        self.git("commit", "-qam", "head")
        self.head = self.git("rev-parse", "HEAD").strip()
        (self.repo / "spec.md").write_text("Local spec\n")

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), *args], stderr=subprocess.PIPE).decode()

    def test_fixed_range_and_local_context_are_distinct(self):
        (self.repo / "source.swift").write_text("uncommitted\n")
        manifest = review.prepare(self.repo, self.base, "HEAD", self.out, "spec.md")
        self.assertEqual(manifest["head"], self.head)
        self.assertEqual((self.out / "snapshot/source.swift").read_text(), "new\n")
        self.assertEqual((self.out / "context/spec.md").read_text(), "Local spec\n")
        self.assertNotIn("uncommitted", (self.out / "range.diff").read_text())
        self.assertEqual(review.check(self.out)["head"], self.head)

    def test_absolute_spec_inside_repo_is_normalized(self):
        manifest = review.prepare(self.repo, self.base, self.head, self.out, str(self.repo / "spec.md"))
        self.assertEqual(manifest["spec"], "context/spec.md")

    def test_empty_range_and_invalid_refs_leave_no_artifact(self):
        with self.assertRaisesRegex(ValueError, "empty"):
            review.prepare(self.repo, self.head, self.head, self.out)
        with self.assertRaises(subprocess.CalledProcessError):
            review.prepare(self.repo, "missing-ref", self.head, self.out)
        self.assertFalse(self.out.exists())

    def test_missing_or_escaping_context_is_rejected(self):
        for path in ["missing.md", "../outside.md"]:
            with self.subTest(path=path), self.assertRaises(ValueError):
                review.prepare(self.repo, self.base, self.head, self.out, path)
        self.assertFalse(self.out.exists())

    def test_changed_and_missing_material_block_review(self):
        review.prepare(self.repo, self.base, self.head, self.out)
        (self.out / "snapshot/source.swift").write_text("tampered")
        with self.assertRaisesRegex(ValueError, "changed evidence"):
            review.check(self.out)
        (self.out / "range.diff").unlink()
        with self.assertRaises(ValueError):
            review.check(self.out)

    def test_existing_output_is_not_overwritten(self):
        review.prepare(self.repo, self.base, self.head, self.out)
        with self.assertRaisesRegex(ValueError, "already exists"):
            review.prepare(self.repo, self.base, self.head, self.out)

    def test_manifest_must_cover_all_required_review_material(self):
        review.prepare(self.repo, self.base, self.head, self.out)
        path = self.out / "manifest.json"
        manifest = json.loads(path.read_text())
        del manifest["files"]["commits.txt"]
        path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, "lacks required"):
            review.check(self.out)

    def test_manifest_cannot_reference_outside_evidence(self):
        review.prepare(self.repo, self.base, self.head, self.out)
        path = self.out / "manifest.json"
        manifest = json.loads(path.read_text())
        manifest["files"]["../outside"] = "irrelevant"
        path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, "escapes"):
            review.check(self.out)


if __name__ == "__main__":
    unittest.main()
