"""Agent-neutral verification runner tests, including false-green/skip regressions."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("check_ui", ROOT / "Scripts/check-ui.py")
ui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ui)


def render_log(scale=1, actual=None, host="15.0", dark=True):
    log = "\n".join(f"Test Case '-[MenubarKitTests.MainWindowRenderHarness {name}]' passed (0.1 seconds)." for name in ui.RENDER_TESTS)
    log += f"\n[render-sdk] product=15.0 host={host}\n"
    for appearance in [False, True] if dark else [False]:
        log += f"[render-environment] backingScale={actual or scale}.0 requestedScale={scale} dark={str(appearance).lower()} width=860.0 height=600.0\n"
    return log


class UIEvaluationTests(unittest.TestCase):
    def test_unit_pass_retains_skip_counts(self):
        result = ui.evaluate("Test Case 'unit' passed (0.1 seconds).\nTest Case 'optionalUI' skipped (0.0 seconds).", 0)
        self.assertEqual(result["status"], "passed")
        self.assertEqual(result["tests"], {"passed": 1, "failed": 0, "skipped": 1})

    def test_complete_render_matrix_member_passes(self):
        for scale in [1, 2]:
            self.assertEqual(ui.evaluate(render_log(scale), 0, scale)["status"], "passed")

    def test_exit_zero_without_tests_is_not_green(self):
        self.assertEqual(ui.evaluate("Build complete", 0)["status"], "not_verified")

    def test_required_skip_or_missing_test_is_not_green(self):
        self.assertEqual(ui.evaluate(render_log().replace("passed", "skipped"), 0, 1)["status"], "not_verified")
        self.assertEqual(ui.evaluate("Test Case 'unrelated' passed (0.1 seconds).", 0, 1)["status"], "not_verified")

    def test_wrong_sdk_backing_or_missing_dark_evidence_is_not_green(self):
        for log in [render_log(host="27.2"), render_log(actual=2), render_log(dark=False), render_log().replace("[render-sdk]", "absent")]:
            with self.subTest(log=log):
                self.assertEqual(ui.evaluate(log, 0, 1)["status"], "not_verified")

    def test_later_pass_does_not_hide_an_earlier_failure(self):
        log = "Test Case 'same' failed (0.1 seconds).\nTest Case 'same' passed (0.1 seconds)."
        self.assertEqual(ui.evaluate(log, 0)["status"], "failed")

    def test_failure_is_preserved(self):
        result = ui.evaluate(render_log(), 1, 1)
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["environment"][0]["actual_scale"], 1)
        self.assertEqual(result["sdk"][0]["host"], "15.0")
        self.assertEqual(ui.evaluate(render_log().replace("passed", "failed"), 0, 1)["status"], "failed")


class UIRunnerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.app = Path(self.tmp.name) / "Winductor.app"
        binary = self.app / "Contents/MacOS/Winductor"
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"fixture executable")
        self.out = Path(self.tmp.name) / "report"

    def run_fixture(self, stages):
        with patch.object(ui.subprocess, "run", return_value=SimpleNamespace(stdout="metadata", stderr="", returncode=0)), \
             patch.object(ui.subprocess, "check_output", return_value="/fixture/sdk\n"), \
             patch.object(ui, "run_stage", side_effect=stages) as run:
            report = ui.verify(self.app, self.out)
        return report, run

    def test_automated_pass_never_claims_manual_acceptance(self):
        with patch.dict(os.environ, {"WINDUCTOR_MAINWINDOW_RENDER_DIR": "inherited"}):
            report, run = self.run_fixture([{"status": "passed"}] * 3)
        self.assertEqual(report["automated_status"], "passed")
        self.assertEqual(report["acceptance_status"], "pending_manual")
        self.assertEqual(report["manual_acceptance"]["status"], "not_verified")
        self.assertNotIn("WINDUCTOR_MAINWINDOW_RENDER_DIR", run.call_args_list[0].args[2])
        self.assertEqual(json.loads((self.out / "report.json").read_text())["product"]["unchanged"], True)

    def test_product_change_invalidates_all_stage_results(self):
        with patch.object(ui, "fingerprint", side_effect=["before", "after"]):
            report, _ = self.run_fixture([{"status": "passed"}] * 3)
        self.assertEqual(report["automated_status"], "incomplete_or_failed")
        self.assertFalse(report["product"]["unchanged"])
        self.assertIn("product changed", report["preflight_error"])

    def test_one_scale_failure_does_not_suppress_other_scale(self):
        report, run = self.run_fixture([{"status": "passed"}, {"status": "failed"}, {"status": "passed"}])
        self.assertEqual(run.call_count, 3)
        self.assertEqual(report["automated_status"], "incomplete_or_failed")

    def test_unit_failure_prevents_using_stale_bundle(self):
        report, run = self.run_fixture([{"status": "failed"}])
        self.assertEqual(run.call_count, 1)
        self.assertEqual(report["stages"]["render_1x"]["status"], "not_run")

    def test_missing_product_metadata_blocks_before_tests(self):
        with patch.object(ui.subprocess, "run", return_value=SimpleNamespace(stdout="", stderr="otool failed", returncode=1)):
            report = ui.verify(self.app, self.out)
        self.assertIn("metadata unavailable", report["preflight_error"])
        self.assertEqual(report["automated_status"], "incomplete_or_failed")

    def test_missing_app_writes_explicit_incomplete_report(self):
        report = ui.verify(Path(self.tmp.name) / "missing.app", self.out)
        self.assertIn("missing", report["preflight_error"])
        self.assertEqual(report["automated_status"], "incomplete_or_failed")

    def test_report_cannot_mutate_the_product_bundle(self):
        with self.assertRaisesRegex(ValueError, "outside the product"):
            ui.verify(self.app, self.app / "report")
        self.assertFalse((self.app / "report").exists())

    def test_existing_report_is_not_overwritten(self):
        self.out.mkdir()
        with self.assertRaises(FileExistsError):
            ui.verify(self.app, self.out)


if __name__ == "__main__":
    unittest.main()
