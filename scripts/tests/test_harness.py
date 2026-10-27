"""Harness control-flow tests. Temporary files and command results are test fixtures."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("stockdeck_harness", Path(__file__).parents[1] / "harness.py")
sys.path.insert(0, str(Path(__file__).parents[1]))
harness = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(harness)


class FixtureHarness(harness.Harness):
    """Replace Git metadata only; use real filesystem state and receipts."""

    branch_name = "feature/harness-test"

    def git(self, *args):
        if args[0] == "branch":
            return self.branch_name.encode()
        if args[0] == "rev-parse":
            return b"a" * 40
        if args[0] == "ls-files":
            return b"\0".join(str(p.relative_to(self.root)).encode()
                               for p in self.root.iterdir() if p.is_file())
        if args[0] == "diff":
            return b""
        raise AssertionError(args)


class HarnessTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.tool = FixtureHarness(self.root)
        (self.root / "source.swift").write_text("// test fixture\n")
        self.task = self.tool.new("test-task", "Verify test fixture", ["source.swift"], ["Tests pass"],
                                  ui_mode="none", ui_reason="Harness control-flow test fixture, no application UI")
        self.silent = patch("builtins.print")
        self.silent.start()
        self.addCleanup(self.silent.stop)

    def passed(self, command, root, log, timeout):
        log.write_text("Test fixture output\n")
        return {"command": command, "status": "passed", "exit_code": 0, "log": str(log)}

    def latest(self):
        task = self.tool.load("test-task")
        return json.loads(self.tool.receipt_path("test-task", task["runs"][-1]).read_text())

    def test_identity_rejects_path_traversal(self):
        for task_id in ("../outside", "/absolute", "a/b", "UPPER", ""):
            with self.assertRaises(ValueError):
                self.tool.task_path(task_id)

    def test_contract_required_and_existing_task_preserved(self):
        with self.assertRaises(ValueError):
            self.tool.new("empty", "goal", [], ["pass"])
        with self.assertRaises(ValueError):
            self.tool.new("test-task", "overwrite", ["all"], ["pass"])
        self.assertEqual(self.tool.load("test-task")["goal"], "Verify test fixture")

    def test_verification_and_creation_rejected_on_main_or_detached_head(self):
        for branch in ("main", "master", ""):
            self.tool.branch_name = branch
            with self.assertRaises(ValueError):
                self.tool.new("another", "goal", ["file"], ["pass"])
            with self.assertRaises(ValueError):
                self.tool.verify(self.task)

    def test_pass_keeps_human_review_pending_and_uses_official_commands(self):
        with patch.object(harness, "run_step", side_effect=self.passed) as runner:
            self.assertTrue(self.tool.verify(self.task))
        self.assertEqual(runner.call_args_list[1].args[0], ["swift", "test"])
        self.assertEqual(runner.call_args_list[2].args[0], ["env", "SD_BUILD_ONLY=1", "./dev.sh"])
        state = self.tool.status(self.tool.load("test-task"))
        self.assertTrue(state["verification_current"])
        self.assertEqual(state["status"], "awaiting_user_review")
        self.assertEqual(self.latest()["human_review"], "pending")

    def test_failed_check_stops_pipeline_and_preserves_log(self):
        def failure(*args):
            result = self.passed(*args)
            result.update(status="failed", exit_code=7)
            return result
        with patch.object(harness, "run_step", side_effect=failure) as runner:
            self.assertFalse(self.tool.verify(self.task))
        self.assertEqual(runner.call_count, 1)
        receipt = self.latest()
        self.assertEqual(receipt["steps"][0]["exit_code"], 7)
        self.assertTrue(Path(receipt["steps"][0]["log"]).is_file())
        self.assertEqual(self.tool.load("test-task")["status"], "needs_attention")

    def test_source_changes_invalidate_previous_pass(self):
        with patch.object(harness, "run_step", side_effect=self.passed):
            self.tool.verify(self.task)
        (self.root / "source.swift").write_text("// changed fixture\n")
        state = self.tool.status(self.tool.load("test-task"))
        self.assertFalse(state["verification_current"])
        self.assertEqual(state["status"], "verification_stale")

    def test_changed_private_csv_input_invalidates_pass_without_recording_contents(self):
        fixtures = self.root / "template" / "transaction"
        fixtures.mkdir(parents=True)
        sample = fixtures / "fixture.csv"
        sample.write_text("test-only input\n")
        with patch.object(harness, "run_step", side_effect=self.passed):
            self.tool.verify(self.task)
        self.assertNotIn("test-only input", json.dumps(self.latest()))
        sample.write_text("changed test-only input\n")
        self.assertFalse(self.tool.status(self.task)["verification_current"])

    def test_new_files_and_contract_changes_invalidate_pass(self):
        with patch.object(harness, "run_step", side_effect=self.passed):
            self.tool.verify(self.task)
        new_file = self.root / "new.swift"
        new_file.write_text("// new fixture\n")
        self.assertFalse(self.tool.status(self.task)["verification_current"])
        new_file.unlink()
        self.task["acceptance"].append("Additional manual review")
        self.tool.write(self.task)
        self.assertFalse(self.tool.status(self.task)["verification_current"])

    def test_edits_during_verification_fail_receipt(self):
        def edit(*args):
            (self.root / "source.swift").write_text("// changed during verification\n")
            return self.passed(*args)
        with patch.object(harness, "run_step", side_effect=edit):
            self.assertFalse(self.tool.verify(self.task))
        self.assertIn("changed during verification", self.latest()["error"])

    def test_contract_edit_during_verification_is_preserved_and_fails_run(self):
        def edit(*args):
            current = self.tool.load("test-task")
            current["acceptance"] = ["New criterion entered in editor"]
            self.tool.write(current)
            return self.passed(*args)
        with patch.object(harness, "run_step", side_effect=edit):
            self.assertFalse(self.tool.verify(self.task))
        current = self.tool.load("test-task")
        self.assertEqual(current["acceptance"], ["New criterion entered in editor"])
        self.assertEqual(current["status"], "needs_attention")

    def test_invalid_history_fails_with_clear_validation_error(self):
        self.task["runs"] = ["../../outside"]
        self.tool.write(self.task)
        with self.assertRaisesRegex(ValueError, "Invalid verification history"):
            self.tool.load("test-task")

    def test_status_is_available_while_verifier_holds_lock(self):
        with harness.workspace_lock(self.root):
            with patch.object(harness, "Harness", return_value=self.tool):
                with patch.object(sys, "argv", ["harness", "status", "test-task"]):
                    self.assertEqual(harness.main(), 0)

    def test_interruption_writes_recoverable_receipt(self):
        with patch.object(harness, "run_step", side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                self.tool.verify(self.task)
        self.assertEqual(self.latest()["status"], "interrupted")
        self.assertEqual(self.tool.load("test-task")["status"], "needs_attention")

    def test_recovery_retains_previous_failure_and_attempt_budget(self):
        with patch.object(harness, "run_step", side_effect=self.passed):
            self.tool.verify(self.task)
        path = self.tool.receipt_path("test-task", self.task["runs"][-1])
        receipt = self.latest()
        receipt["status"] = "running"
        harness.save_json(path, receipt)
        self.tool.recover(self.task)
        self.assertEqual(self.latest()["status"], "interrupted")
        self.assertEqual(len(self.task["runs"]), 1)
        self.assertEqual(self.task["status"], "needs_attention")

    def test_verification_budget_stops_fourth_run(self):
        with patch.object(harness, "run_step", side_effect=self.passed) as runner:
            for _ in range(3):
                self.tool.verify(self.task)
            with self.assertRaisesRegex(ValueError, "Three verification attempts"):
                self.tool.verify(self.task)
        self.assertEqual(runner.call_count, 9)

    def test_checkout_lock_blocks_concurrent_verifiers_and_releases(self):
        with harness.workspace_lock(self.root):
            with self.assertRaisesRegex(ValueError, "Another harness command"):
                with harness.workspace_lock(self.root):
                    self.fail("Concurrent command acquired lock")
        with harness.workspace_lock(self.root):
            pass

    def test_real_command_failure_is_not_reported_as_pass(self):
        log = self.root / "failure.log"
        result = harness.run_step([sys.executable, "-c", "print('test fixture'); raise SystemExit(9)"],
                                  self.root, log, 5)
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["exit_code"], 9)
        self.assertIn("test fixture", log.read_text())

    def test_real_command_timeout(self):
        result = harness.run_step([sys.executable, "-c", "import time; time.sleep(30)"],
                                  self.root, self.root / "timeout.log", 1)
        self.assertEqual(result["status"], "timed_out")
        self.assertLess(result["duration_seconds"], 6)

    def test_missing_executable_records_failure(self):
        result = harness.run_step([str(self.root / "missing-executable")],
                                  self.root, self.root / "missing.log", 1)
        self.assertEqual(result["status"], "failed")
        self.assertIsNone(result["exit_code"])


if __name__ == "__main__":
    unittest.main()
