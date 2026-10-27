"""UI plans, build-bound sessions and screenshot evidence for the local harness."""

from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import struct
import subprocess
import time
import uuid
import zlib


COVERAGE = {"loading", "empty", "error", "loaded", "appearance", "window_size", "keyboard", "parity"}
APP_PATH = Path(".build/StockDeck-Dev.app")
UI_PREFIXES = ("StockDeck/Views/", "StockDeck/Resources/", "StockDeck/Assets.xcassets/")
UI_FILES = {"StockDeck/AppDelegate.swift", "StockDeck/ColorHex.swift", "StockDeck/FontRegistration.swift",
            "StockDeck/Services/LightweightChartTrial.swift"}


def stamp():
    return datetime.now(timezone.utc).isoformat()


def identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", value):
        raise ValueError("Use a lowercase ID with 1–64 letters, digits or hyphens.")
    return value


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def config(mode="required", reason=""):
    if mode not in ("required", "none") or not isinstance(reason, str):
        raise ValueError("Invalid UI mode/reason.")
    if mode == "none" and not reason.strip():
        raise ValueError("Non-UI work requires an explicit --ui-reason.")
    return {"mode": mode, "reason": reason, "plan": None}


def text(value, label):
    if not isinstance(value, str) or not value.strip():
        raise ValueError(label + " must not be empty.")


def validate_plan(plan):
    if not isinstance(plan, dict) or not isinstance(plan.get("scenarios"), list) or not plan["scenarios"]:
        raise ValueError("UI plan needs at least one scenario.")
    covered, scenario_ids = set(), set()
    for scenario in plan["scenarios"]:
        if not isinstance(scenario, dict):
            raise ValueError("Each UI scenario must be an object.")
        scenario_id = identifier(scenario.get("id"))
        if scenario_id in scenario_ids:
            raise ValueError("Duplicate scenario ID.")
        scenario_ids.add(scenario_id)
        for key in ("title", "surface"):
            text(scenario.get(key), "Scenario " + key)
        conditions = scenario.get("preconditions")
        if not isinstance(conditions, list) or not conditions:
            raise ValueError("Scenario needs explicit preconditions.")
        for value in conditions:
            text(value, "Precondition")
        covers = scenario.get("covers")
        if not isinstance(covers, list) or not covers or any(not isinstance(item, str) or item not in COVERAGE for item in covers):
            raise ValueError("Scenario needs valid coverage categories.")
        covered.update(covers)
        steps = scenario.get("steps")
        if not isinstance(steps, list) or not steps:
            raise ValueError("Scenario needs ordered actions and expected results.")
        step_ids = set()
        for step in steps:
            if not isinstance(step, dict):
                raise ValueError("Each UI step must be an object.")
            step_id = identifier(step.get("id"))
            if step_id in step_ids:
                raise ValueError("Duplicate step ID in scenario.")
            step_ids.add(step_id)
            text(step.get("action"), "Step action")
            text(step.get("expected"), "Step expected result")
    exclusions = plan.get("exclusions", {})
    if not isinstance(exclusions, dict) or any(key not in COVERAGE for key in exclusions):
        raise ValueError("Invalid coverage exclusions.")
    for reason in exclusions.values():
        text(reason, "Reason for not applicable")
    if covered & set(exclusions):
        raise ValueError("A coverage category cannot be both tested and excluded.")
    if COVERAGE - covered - set(exclusions):
        raise ValueError("Missing coverage or justified exclusions: " + ", ".join(sorted(COVERAGE - covered - set(exclusions))))
    if "loaded" not in covered:
        raise ValueError("The loaded UI state must be tested.")
    return plan


def validate_config(value):
    if not isinstance(value, dict):
        raise ValueError("Invalid UI contract.")
    config(value.get("mode"), value.get("reason", ""))
    if value.get("mode") == "none" and value.get("plan") is not None:
        raise ValueError("A non-UI task cannot contain a UI plan.")
    if value.get("plan") is not None:
        validate_plan(value["plan"])


def build_artifact(root):
    bundle = root / APP_PATH
    executable = bundle / "Contents/MacOS/StockDeck"
    if not executable.is_file():
        raise ValueError("The verified StockDeck DEV app is missing.")
    result = hashlib.sha256()
    for path in sorted(bundle.rglob("*")):
        if path.is_symlink():
            if not path.resolve().is_relative_to(bundle.resolve()):
                raise ValueError("App bundle contains an external symlink.")
            value = "link:" + os.readlink(path)
        elif path.is_file():
            value = str(path.stat().st_mode) + ":" + digest(path)
        else:
            continue
        result.update(str(path.relative_to(bundle)).encode() + b"\0" + value.encode() + b"\0")
    with (bundle / "Contents/Info.plist").open("rb") as file:
        info = plistlib.load(file)
    return {"path": str(APP_PATH), "sha256": result.hexdigest(),
            "bundle_id": info["CFBundleIdentifier"], "version": info["CFBundleShortVersionString"],
            "executable": str(executable.relative_to(root))}


def process_identity(pid):
    if pid <= 1:
        raise ValueError("Provide the PID of the running verified DEV app.")
    environment = dict(os.environ, LC_ALL="C")
    try:
        executable = subprocess.check_output(["ps", "-p", str(pid), "-o", "comm="], text=True, env=environment).strip()
        started = subprocess.check_output(["ps", "-p", str(pid), "-o", "lstart="], text=True, env=environment).strip()
    except subprocess.CalledProcessError:
        raise ValueError("The target app process is not running.") from None
    return {"pid": pid, "executable": str(Path(executable).resolve()), "started": started,
            "started_unix": time.mktime(time.strptime(started, "%a %b %d %H:%M:%S %Y"))}


def screenshot(path, earliest):
    """Validate a complete, non-interlaced 8-bit PNG without extra dependencies."""
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 64 * 1024 * 1024:
        raise ValueError("Evidence must be a regular PNG file smaller than 64 MB.")
    captured = path.stat().st_mtime
    if captured < earliest or captured > time.time() + 2:
        raise ValueError("Screenshot predates this UI session or has an invalid timestamp.")
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("UI evidence must be a PNG screenshot.")
    position, compressed, header, ended = 8, bytearray(), None, False
    while position + 12 <= len(data):
        length = struct.unpack(">I", data[position:position + 4])[0]
        kind = data[position + 4:position + 8]
        payload = data[position + 8:position + 8 + length]
        end = position + length + 12
        if end > len(data) or zlib.crc32(kind + payload) != struct.unpack(">I", data[end - 4:end])[0]:
            raise ValueError("Corrupt PNG evidence.")
        if kind == b"IHDR" and position == 8 and length == 13:
            header = struct.unpack(">IIBBBBB", payload)
        elif kind == b"IDAT":
            compressed.extend(payload)
        elif kind == b"IEND" and length == 0:
            ended = end == len(data)
            break
        position = end
    if header is None or not ended or not compressed:
        raise ValueError("Incomplete PNG screenshot.")
    width, height, depth, color, compression, filtering, interlace = header
    channels = {0: 1, 2: 3, 4: 2, 6: 4}.get(color)
    if (width < 320 or height < 200 or width * height > 40_000_000 or depth != 8
            or channels is None or compression or filtering or interlace):
        raise ValueError("Use a full UI screenshot (at least 320×200), non-interlaced 8-bit PNG.")
    expected = height * (1 + width * channels)
    inflater = zlib.decompressobj()
    try:
        pixels = inflater.decompress(bytes(compressed), expected + 1)
    except zlib.error:
        raise ValueError("Invalid screenshot pixel data.") from None
    if len(pixels) != expected or not inflater.eof or inflater.unused_data:
        raise ValueError("Incomplete or oversized screenshot pixel data.")
    return {"sha256": hashlib.sha256(data).hexdigest(), "width": width, "height": height,
            "captured_unix": captured}


class UIGate:
    def __init__(self, harness):
        self.harness = harness
        self.root = harness.root

    def scope_errors(self, task):
        if task["ui"]["mode"] != "none":
            return []
        names = self.harness.git("diff", "--name-only", "HEAD", "-z")
        names += b"\0" + self.harness.git("ls-files", "--others", "--exclude-standard", "-z")
        ui_files = [os.fsdecode(name) for name in set(names.split(b"\0")) - {b""}
                    if os.fsdecode(name).startswith(UI_PREFIXES) or os.fsdecode(name) in UI_FILES]
        return ["UI files changed; --ui none is not allowed: " + ", ".join(sorted(ui_files))] if ui_files else []

    def preflight(self, task):
        errors = self.scope_errors(task)
        if errors:
            raise ValueError(errors[0])
        if task["ui"]["mode"] == "required":
            validate_plan(task["ui"]["plan"])

    def receipt(self, task):
        if not task["runs"]:
            raise ValueError("Run verify first.")
        path = self.harness.receipt_path(task["id"], task["runs"][-1])
        receipt = json.loads(path.read_text())
        if receipt["status"] != "passed" or receipt["source"] != self.harness.snapshot(task):
            raise ValueError("Test/build evidence is missing, failed or stale; run verify again.")
        if not receipt.get("artifact") or receipt["artifact"] != build_artifact(self.root):
            raise ValueError("The app bundle differs from the verified build; run verify again.")
        return receipt

    def path(self, task, session_id):
        if not re.fullmatch(r"[0-9a-f]{32}", session_id):
            raise ValueError("Invalid UI session ID.")
        return self.harness.directory / "ui" / task["id"] / session_id / "session.json"

    def begin(self, task, pid):
        self.preflight(task)
        if task["ui"]["mode"] != "required":
            raise ValueError("This task does not require a UI session.")
        receipt = self.receipt(task)
        process = process_identity(pid)
        if process["executable"] != str((self.root / receipt["artifact"]["executable"]).resolve()):
            raise ValueError("The PID belongs to a different app/build path.")
        if process["started_unix"] < datetime.fromisoformat(receipt["finished_at"]).timestamp():
            raise ValueError("Restart this DEV app after verify; its process predates the verified build.")
        same_build = 0
        for session_id in task["ui_sessions"]:
            path = self.path(task, session_id)
            if path.exists() and json.loads(path.read_text())["run_id"] == receipt["run_id"]:
                same_build += 1
        if same_build >= 3:
            raise ValueError("Three UI sessions used for this build; review the evidence with the user.")
        session_id = uuid.uuid4().hex
        session = {"id": session_id, "task_id": task["id"], "run_id": receipt["run_id"],
                   "source": receipt["source"], "artifact": receipt["artifact"], "process": process,
                   "started_at": stamp(), "started_unix": time.time(), "records": []}
        self.harness.write_ui(self.path(task, session_id), session)
        task["ui_sessions"].append(session_id)
        task["status"] = "awaiting_ui_verification"
        self.harness.write(task)
        return session

    def record(self, task, session_id, scenario_id, step_id, result, actual, before=None, after=None):
        text(actual, "Observed result")
        if result not in ("passed", "failed", "blocked"):
            raise ValueError("Invalid UI step result.")
        receipt = self.receipt(task)
        if not task["ui_sessions"] or task["ui_sessions"][-1] != session_id:
            raise ValueError("Record evidence in the latest UI session.")
        path = self.path(task, session_id)
        session = json.loads(path.read_text())
        if session["run_id"] != receipt["run_id"] or session["source"] != receipt["source"]:
            raise ValueError("This UI session belongs to an older verification run.")
        if process_identity(session["process"]["pid"]) != session["process"]:
            raise ValueError("Target app process changed; start a fresh UI session.")
        scenarios = {scenario["id"]: scenario for scenario in task["ui"]["plan"]["scenarios"]}
        scenario = scenarios.get(scenario_id)
        if scenario is None:
            raise ValueError("Unknown UI scenario.")
        steps = [step["id"] for step in scenario["steps"]]
        if step_id not in steps:
            raise ValueError("Unknown UI step.")
        records = [record for record in session["records"] if record["scenario"] == scenario_id]
        latest = {record["step"]: record for record in records}
        if any(latest.get(previous, {}).get("result") != "passed" for previous in steps[:steps.index(step_id)]):
            raise ValueError("Execute and record previous steps in order first.")
        if sum(record["step"] == step_id for record in records) >= 3:
            raise ValueError("Three attempts used for this UI step; stop and review with the user.")
        record_id = uuid.uuid4().hex
        record = {"id": record_id, "scenario": scenario_id, "step": step_id, "result": result,
                  "actual": actual, "recorded_at": stamp(), "evidence": {}}
        earliest = session["started_unix"]
        if session["records"]:
            earliest = max(earliest, datetime.fromisoformat(session["records"][-1]["recorded_at"]).timestamp())
        if result == "passed" and (not before or not after):
            raise ValueError("A passed UI step requires before and after PNG screenshots.")
        before_path = (self.root / before).resolve() if before else None
        after_path = (self.root / after).resolve() if after else None
        if before_path and before_path == after_path:
            raise ValueError("Capture separate before and after files.")
        for label, source in (("before", before), ("after", after)):
            if source:
                source = Path(source)
                if not source.is_absolute():
                    source = self.root / source
                metadata = screenshot(source, earliest)
                destination = path.parent / record_id / (label + ".png")
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, destination)
                if digest(destination) != metadata["sha256"]:
                    raise ValueError("Screenshot changed while collecting evidence.")
                record["evidence"][label] = dict(metadata, path=str(destination.relative_to(self.root)))
        if (before and after and record["evidence"]["after"]["captured_unix"]
                < record["evidence"]["before"]["captured_unix"]):
            raise ValueError("The after screenshot was captured before the before screenshot.")
        session["records"].append(record)
        self.harness.write_ui(path, session)
        task["status"] = "awaiting_ui_verification"
        self.harness.write(task)
        return record

    def assess(self, task, receipt):
        errors = self.scope_errors(task)
        if task["ui"]["mode"] == "none":
            return {"status": "blocked" if errors else "not_applicable", "problems": errors,
                    "reason": task["ui"]["reason"]}
        try:
            validate_plan(task["ui"]["plan"])
            if not receipt or receipt["status"] != "passed":
                raise ValueError("Test/build must pass before UI verification.")
            if not receipt.get("artifact") or receipt["artifact"] != build_artifact(self.root):
                raise ValueError("UI evidence must match the verified app bundle.")
            if not task["ui_sessions"]:
                raise ValueError("No UI session or interaction evidence recorded.")
            session_path = self.path(task, task["ui_sessions"][-1])
            session = json.loads(session_path.read_text())
            if session["run_id"] != receipt["run_id"] or session["source"] != receipt["source"]:
                raise ValueError("UI session is stale after a new test/build run.")
            latest = {(record["scenario"], record["step"]): record for record in session["records"]}
            for scenario in task["ui"]["plan"]["scenarios"]:
                previous_time = ""
                for step in scenario["steps"]:
                    record = latest.get((scenario["id"], step["id"]))
                    label = scenario["id"] + "/" + step["id"]
                    if record is None or record["result"] != "passed":
                        errors.append(label + ": not passed")
                        continue
                    if record["recorded_at"] < previous_time:
                        errors.append(label + ": repeat after the preceding step was re-tested")
                    previous_time = record["recorded_at"]
                    for kind in ("before", "after"):
                        evidence = record["evidence"].get(kind)
                        if not evidence:
                            errors.append(label + ": missing " + kind + " screenshot")
                            continue
                        file = (self.root / evidence["path"]).resolve()
                        if not file.is_relative_to(session_path.parent.resolve()) or digest(file) != evidence["sha256"]:
                            errors.append(label + ": missing, modified or invalid evidence")
            return {"status": "blocked" if errors else "passed", "problems": errors,
                    "session": str(session_path.relative_to(self.root)),
                    "assessment": "Evidence completeness; observed assertions still require review."}
        except (ValueError, OSError, KeyError) as error:
            return {"status": "blocked", "problems": [str(error)]}
