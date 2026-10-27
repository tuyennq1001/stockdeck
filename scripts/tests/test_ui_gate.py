"""Explicit test fixtures: synthetic app, process identity and generated PNGs.

These tests exercise the evidence gate; they are not StockDeck UI test evidence.
"""

from copy import deepcopy
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import zlib

from test_harness import FixtureHarness, harness
import ui_gate


def plan():
    return {"scenarios": [{"id": "table", "title": "Test-only scenario", "surface": "Fixture window",
                           "preconditions": ["Test fixture running"], "covers": ["loaded"],
                           "steps": [{"id": "open", "action": "Open fixture", "expected": "Fixture visible"},
                                     {"id": "filter", "action": "Filter fixture", "expected": "Expected rows visible"}]}],
            "exclusions": {key: "Not applicable to this control-flow test fixture"
                           for key in ui_gate.COVERAGE - {"loaded"}}}


def png(path, color=120):
    """Generate an explicitly synthetic, valid screenshot-shaped test fixture."""
    def chunk(kind, value):
        return struct.pack(">I", len(value)) + kind + value + struct.pack(">I", zlib.crc32(kind + value))
    header = struct.pack(">IIBBBBB", 320, 200, 8, 2, 0, 0, 0)
    pixels = (b"\0" + bytes([color, 0, 0]) * 320) * 200
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
                     + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))
    return path


class UIGateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.captures = self.root / ".harness/captures"
        self.captures.mkdir(parents=True)
        self.tool = FixtureHarness(self.root)
        (self.root / "source.swift").write_text("// UI gate test fixture\n")
        self.task = self.tool.new("ui-test", "Test evidence gate", ["source.swift"], ["Gate works"])
        self.gate = ui_gate.UIGate(self.tool)
        self.task["ui"]["plan"] = plan()
        self.tool.write(self.task)
        bundle = self.root / ui_gate.APP_PATH
        (bundle / "Contents/MacOS").mkdir(parents=True)
        (bundle / "Contents/MacOS/StockDeck").write_bytes(b"test-only app fixture")
        with (bundle / "Contents/Info.plist").open("wb") as file:
            plistlib.dump({"CFBundleIdentifier": "test.fixture", "CFBundleShortVersionString": "0-test"}, file)
        self.process = {"pid": 424242, "executable": str(bundle / "Contents/MacOS/StockDeck"),
                        "started": "test-only process", "started_unix": time.time() + 60}
        self.mock_process = patch.object(ui_gate, "process_identity", return_value=self.process)
        self.mock_process.start()
        self.addCleanup(self.mock_process.stop)
        quiet = patch("builtins.print")
        quiet.start()
        self.addCleanup(quiet.stop)

    def verify(self):
        def passed(command, root, log, timeout):
            log.write_text("Explicit mock verification output\n")
            return {"command": command, "status": "passed", "exit_code": 0, "log": str(log)}
        with patch.object(harness, "run_step", side_effect=passed):
            self.assertTrue(self.tool.verify(self.task))

    def begin(self):
        self.verify()
        return self.gate.begin(self.task, self.process["pid"])

    def record(self, session, step="open", result="passed", images=True):
        before = png(self.captures / "before.png") if images else None
        after = png(self.captures / "after.png", 150) if images else None
        return self.gate.record(self.task, session["id"], "table", step, result,
                                "Observed test-only fixture result", before, after)

    def test_ui_is_required_by_default_and_missing_plan_stops_verify(self):
        self.task["ui"]["plan"] = None
        self.tool.write(self.task)
        with self.assertRaisesRegex(ValueError, "at least one scenario"):
            self.tool.verify(self.task)
        self.assertEqual(self.task["runs"], [])

    def test_non_ui_exemption_requires_reason(self):
        with self.assertRaisesRegex(ValueError, "explicit --ui-reason"):
            self.tool.new("exempt", "goal", ["docs"], ["pass"], ui_mode="none")

    def test_changed_ui_files_cannot_use_non_ui_exemption(self):
        self.task["ui"] = ui_gate.config("none", "Declared documentation-only fixture")
        original = self.tool.git
        def git(*args):
            return b"StockDeck/Views/WatchlistView.swift\0" if args[0] == "diff" else original(*args)
        with patch.object(self.tool, "git", side_effect=git):
            with self.assertRaisesRegex(ValueError, "--ui none is not allowed"):
                self.tool.verify(self.task)

    def test_missing_coverage_rejected(self):
        value = plan()
        del value["exclusions"]["keyboard"]
        with self.assertRaisesRegex(ValueError, "Missing coverage"):
            ui_gate.validate_plan(value)

    def test_loaded_state_cannot_be_excluded(self):
        value = plan()
        value["scenarios"][0]["covers"] = ["keyboard"]
        del value["exclusions"]["keyboard"]
        value["exclusions"]["loaded"] = "Attempt to skip loaded state"
        with self.assertRaisesRegex(ValueError, "loaded UI state must be tested"):
            ui_gate.validate_plan(value)

    def test_duplicate_steps_rejected(self):
        value = plan()
        value["scenarios"][0]["steps"].append(deepcopy(value["scenarios"][0]["steps"][0]))
        with self.assertRaisesRegex(ValueError, "Duplicate step"):
            ui_gate.validate_plan(value)

    def test_automated_pass_does_not_mean_ui_pass(self):
        self.verify()
        state = self.tool.status(self.task)
        self.assertTrue(state["verification_current"])
        self.assertFalse(state["ready_for_user_review"])
        self.assertEqual(state["status"], "awaiting_ui_verification")
        self.assertEqual(state["gates"]["ui"]["status"], "blocked")

    def test_wrong_app_path_rejected(self):
        self.verify()
        self.process["executable"] = "/test/other/app"
        with self.assertRaisesRegex(ValueError, "different app/build"):
            self.gate.begin(self.task, 424242)

    def test_old_running_process_rejected(self):
        self.verify()
        self.process["started_unix"] = 0
        with self.assertRaisesRegex(ValueError, "predates the verified build"):
            self.gate.begin(self.task, 424242)

    def test_step_order_enforced(self):
        session = self.begin()
        with self.assertRaisesRegex(ValueError, "previous steps in order"):
            self.record(session, "filter")

    def test_pass_requires_before_and_after_screenshots(self):
        session = self.begin()
        with self.assertRaisesRegex(ValueError, "requires before and after"):
            self.record(session, images=False)

    def test_old_screenshot_rejected(self):
        session = self.begin()
        before, after = png(self.captures / "old.png"), png(self.captures / "after.png")
        os.utime(before, (session["started_unix"] - 10, session["started_unix"] - 10))
        with self.assertRaisesRegex(ValueError, "predates this UI session"):
            self.gate.record(self.task, session["id"], "table", "open", "passed", "Fixture observed", before, after)

    def test_truncated_png_rejected(self):
        session = self.begin()
        before = png(self.captures / "broken.png")
        before.write_bytes(before.read_bytes()[:30])
        after = png(self.captures / "after.png")
        with self.assertRaisesRegex(ValueError, "PNG"):
            self.gate.record(self.task, session["id"], "table", "open", "passed", "Fixture observed", before, after)

    def test_tampered_evidence_blocks_handoff(self):
        session = self.begin()
        first = self.record(session)
        self.record(session, "filter")
        self.assertTrue(self.tool.status(self.task)["ready_for_user_review"])
        file = self.root / first["evidence"]["after"]["path"]
        file.write_bytes(b"modified evidence")
        self.assertFalse(self.tool.status(self.task)["ready_for_user_review"])

    def test_complete_ui_evidence_keeps_human_acceptance_pending(self):
        session = self.begin()
        self.record(session)
        self.record(session, "filter")
        state = self.tool.status(self.task)
        self.assertTrue(state["ready_for_user_review"])
        self.assertEqual(state["status"], "awaiting_user_review")
        self.assertEqual(state["gates"]["ui"]["status"], "passed")
        self.assertEqual(state["gates"]["human_acceptance"], "pending")

    def test_failed_step_keeps_gate_blocked(self):
        session = self.begin()
        self.record(session, result="failed", images=False)
        self.assertFalse(self.tool.status(self.task)["ready_for_user_review"])

    def test_source_edit_invalidates_ui_evidence(self):
        session = self.begin()
        self.record(session)
        (self.root / "source.swift").write_text("// changed test fixture")
        with self.assertRaisesRegex(ValueError, "stale"):
            self.record(session, "filter")
        self.assertFalse(self.tool.status(self.task)["ready_for_user_review"])

    def test_different_app_bundle_invalidates_ui_session(self):
        session = self.begin()
        app = self.root / ui_gate.APP_PATH / "Contents/MacOS/StockDeck"
        app.write_bytes(b"different test-only app fixture")
        with self.assertRaisesRegex(ValueError, "differs from the verified build"):
            self.record(session)

    def test_new_verify_run_invalidates_old_session(self):
        session = self.begin()
        self.verify()
        with self.assertRaisesRegex(ValueError, "older verification run"):
            self.record(session)

    def test_omitted_scenario_blocks_handoff(self):
        second = deepcopy(self.task["ui"]["plan"]["scenarios"][0])
        second["id"] = "second-surface"
        self.task["ui"]["plan"]["scenarios"].append(second)
        self.tool.write(self.task)
        session = self.begin()
        self.record(session)
        self.record(session, "filter")
        self.assertFalse(self.tool.status(self.task)["ready_for_user_review"])

    def test_reusing_previous_step_screenshots_rejected(self):
        session = self.begin()
        self.record(session)
        with self.assertRaisesRegex(ValueError, "predates this UI session"):
            self.gate.record(self.task, session["id"], "table", "filter", "passed", "Fixture result",
                             self.captures / "before.png", self.captures / "after.png")

    def test_retesting_earlier_step_requires_retesting_later_steps(self):
        session = self.begin()
        self.record(session)
        self.record(session, "filter")
        self.record(session)
        self.assertFalse(self.tool.status(self.task)["ready_for_user_review"])
        self.record(session, "filter")
        self.assertTrue(self.tool.status(self.task)["ready_for_user_review"])

    def test_three_failed_step_attempts_stop_retry_loop(self):
        session = self.begin()
        for _ in range(3):
            self.record(session, result="blocked", images=False)
        with self.assertRaisesRegex(ValueError, "Three attempts"):
            self.record(session, result="blocked", images=False)

    def test_check_command_returns_blocked_exit_code(self):
        self.verify()
        with patch.object(harness, "Harness", return_value=self.tool):
            with patch.object(sys, "argv", ["harness", "check", "ui-test"]):
                self.assertEqual(harness.main(), 3)

    def test_cli_workflow_blocks_until_all_evidence_is_recorded(self):
        plan_file = self.captures / "plan.json"
        plan_file.write_text(json.dumps(plan()))
        def passed(command, root, log, timeout):
            log.write_text("Explicit mock CLI verification output\n")
            return {"command": command, "status": "passed", "exit_code": 0, "log": str(log)}
        def invoke(*args):
            with patch.object(sys, "argv", ["harness", *args]):
                return harness.main()
        with patch.object(harness, "Harness", return_value=self.tool):
            self.assertEqual(invoke("ui-plan", "ui-test", str(plan_file)), 0)
            with patch.object(harness, "run_step", side_effect=passed):
                self.assertEqual(invoke("verify", "ui-test"), 3)
            self.assertEqual(invoke("ui-begin", "ui-test", "--pid", "424242"), 0)
            session_id = self.tool.load("ui-test")["ui_sessions"][-1]
            for step in ("open", "filter"):
                before, after = png(self.captures / "before.png"), png(self.captures / "after.png")
                self.assertEqual(invoke("ui-record", "ui-test", session_id, "table", step,
                                        "--result", "passed", "--actual", "CLI test fixture observed",
                                        "--before", str(before), "--after", str(after)), 0)
            self.assertEqual(invoke("check", "ui-test"), 0)

    def test_ui_plan_edit_invalidates_automated_pass(self):
        self.verify()
        self.task["ui"]["plan"]["scenarios"][0]["steps"][0]["expected"] = "Changed test-only expectation"
        self.tool.write(self.task)
        state = self.tool.status(self.task)
        self.assertFalse(state["verification_current"])
        self.assertEqual(state["gates"]["ui"]["status"], "stale")

    def test_after_image_must_not_predate_before_image(self):
        session = self.begin()
        before, after = png(self.captures / "before.png"), png(self.captures / "after.png")
        earlier = session["started_unix"] + 0.001
        os.utime(after, (earlier, earlier))
        os.utime(before, (earlier + 0.001, earlier + 0.001))
        with self.assertRaisesRegex(ValueError, "after screenshot was captured before"):
            self.gate.record(self.task, session["id"], "table", "open", "passed", "Fixture result", before, after)

    def test_evidence_path_cannot_escape_session(self):
        session = self.begin()
        self.record(session)
        self.record(session, "filter")
        path = self.gate.path(self.task, session["id"])
        data = json.loads(path.read_text())
        data["records"][0]["evidence"]["after"]["path"] = "../../outside.png"
        harness.save_json(path, data)
        self.assertFalse(self.tool.status(self.task)["ready_for_user_review"])


if __name__ == "__main__":
    unittest.main()
