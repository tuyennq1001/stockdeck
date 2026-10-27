#!/usr/bin/env python3
"""Local task state and verification receipts. No model calls or Git writes."""

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
import uuid

from ui_gate import UIGate, build_artifact, config as ui_config, validate_config, validate_plan


MAX_ATTEMPTS = 3
CONTRACT_FIELDS = ("goal", "scope", "acceptance", "constraints", "ui")


def now():
    return datetime.now(timezone.utc).isoformat()


def save_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as file:
        temporary = Path(file.name)
        json.dump(data, file, ensure_ascii=False, indent=2)
        file.write("\n")
    try:
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


@contextmanager
def workspace_lock(root):
    directory = root / ".harness"
    directory.mkdir(exist_ok=True)
    with (directory / "lock").open("a") as file:
        try:
            fcntl.flock(file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("Another harness command is running in this checkout.") from None
        try:
            yield
        finally:
            fcntl.flock(file, fcntl.LOCK_UN)


def stop_process(process):
    # Kill the whole command group so a timed-out build cannot keep running.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        process.wait()
        return
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def run_step(command, root, log, timeout):
    started = time.monotonic()
    result = {"command": command, "started_at": now(), "log": str(log.relative_to(root))}
    with log.open("wb") as output:
        try:
            process = subprocess.Popen(command, cwd=root, stdout=output,
                                       stderr=subprocess.STDOUT, start_new_session=True)
        except OSError as error:
            result.update(status="failed", exit_code=None, error=str(error))
        else:
            try:
                code = process.wait(timeout=timeout)
                result.update(status="passed" if code == 0 else "failed", exit_code=code)
            except subprocess.TimeoutExpired:
                stop_process(process)
                result.update(status="timed_out", exit_code=process.returncode)
            except BaseException:
                stop_process(process)
                raise
    result["duration_seconds"] = round(time.monotonic() - started, 3)
    return result


class Harness:
    def __init__(self, root):
        self.root = Path(root).resolve()
        self.directory = self.root / ".harness"

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root)

    def branch(self):
        return self.git("branch", "--show-current").decode().strip()

    def require_branch(self):
        if self.branch() in ("", "main", "master"):
            raise ValueError("Use a dedicated feature/fix branch before creating or verifying a task.")

    def task_path(self, task_id):
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", task_id):
            raise ValueError("Task ID must be 1–64 lowercase letters, digits or hyphens.")
        return self.directory / "tasks" / (task_id + ".json")

    def load(self, task_id):
        path = self.task_path(task_id)
        if not path.is_file():
            raise ValueError("Task does not exist. Create it with 'new' first.")
        task = json.loads(path.read_text())
        if task.get("id") != task_id or task.get("version") != 1:
            raise ValueError("Invalid task identity or version.")
        if not isinstance(task.get("goal"), str) or not task["goal"].strip():
            raise ValueError("Task goal must not be empty.")
        for field in ("scope", "acceptance", "constraints"):
            values = task.get(field)
            if not isinstance(values, list) or any(not isinstance(v, str) or not v.strip() for v in values):
                raise ValueError("Invalid task field: " + field)
            if field != "constraints" and not values:
                raise ValueError("Task needs explicit scope and acceptance criteria.")
        if not isinstance(task.get("runs"), list) or any(
                not isinstance(run, str) or not re.fullmatch(r"[0-9a-f]{32}", run) for run in task["runs"]):
            raise ValueError("Invalid verification history.")
        if not isinstance(task.get("notes"), list):
            raise ValueError("Invalid task notes.")
        # Old tasks become UI-required until explicitly classified; no silent exemption.
        task.setdefault("ui", ui_config())
        task.setdefault("ui_sessions", [])
        validate_config(task["ui"])
        if not isinstance(task["ui_sessions"], list) or any(
                not isinstance(session, str) or not re.fullmatch(r"[0-9a-f]{32}", session)
                for session in task["ui_sessions"]):
            raise ValueError("Invalid UI session history.")
        return task

    def write(self, task):
        task["updated_at"] = now()
        save_json(self.task_path(task["id"]), task)

    def write_ui(self, path, value):
        save_json(path, value)

    def new(self, task_id, goal, scope, acceptance, ui_mode="required", ui_reason=""):
        self.require_branch()
        path = self.task_path(task_id)
        if path.exists():
            raise ValueError("Task already exists; its history will not be overwritten.")
        if not goal.strip() or not scope or not acceptance or any(not v.strip() for v in scope + acceptance):
            raise ValueError("Provide a goal, scope and acceptance criteria.")
        task = {"version": 1, "id": task_id, "goal": goal, "scope": scope,
                "acceptance": acceptance, "constraints": [], "status": "planned",
                "created_at": now(), "notes": [], "runs": [], "ui_sessions": [],
                "ui": ui_config(ui_mode, ui_reason)}
        self.write(task)
        return task

    def snapshot(self, task):
        digest = hashlib.sha256()
        # Include tracked files and non-ignored new files, not only the HEAD commit.
        names = self.git("ls-files", "--cached", "--others", "--exclude-standard", "-z")
        for name in sorted(set(names.split(b"\0")) - {b""}):
            path = self.root / os.fsdecode(name)
            digest.update(name + b"\0")
            if path.is_symlink():
                digest.update(b"symlink\0" + os.fsencode(os.readlink(path)))
            elif path.is_file():
                digest.update(str(path.stat().st_mode).encode() + b"\0")
                with path.open("rb") as file:
                    for chunk in iter(lambda: file.read(1024 * 1024), b""):
                        digest.update(chunk)
            else:
                digest.update(b"missing")
            digest.update(b"\0")
        contract = {key: task[key] for key in CONTRACT_FIELDS}
        fixtures = hashlib.sha256()
        for path in sorted((self.root / "template" / "transaction").glob("*.csv")):
            fixtures.update(str(path.relative_to(self.root)).encode() + b"\0")
            with path.open("rb") as file:
                for chunk in iter(lambda: file.read(1024 * 1024), b""):
                    fixtures.update(chunk)
            fixtures.update(b"\0")
        return {"head": self.git("rev-parse", "HEAD").decode().strip(),
                "branch": self.branch(), "files_sha256": digest.hexdigest(),
                "test_inputs_sha256": fixtures.hexdigest(),
                "contract_sha256": hashlib.sha256(json.dumps(contract, sort_keys=True).encode()).hexdigest()}

    def receipt_path(self, task_id, run_id):
        if not re.fullmatch(r"[0-9a-f]{32}", run_id):
            raise ValueError("Invalid run identity.")
        return self.directory / "runs" / task_id / run_id / "receipt.json"

    def recover(self, task):
        # Called only while holding the checkout lock. A retained lock file is harmless.
        for run_id in task["runs"]:
            path = self.receipt_path(task["id"], run_id)
            if not path.exists():
                task["status"] = "needs_attention"
                continue
            receipt = json.loads(path.read_text())
            if receipt["status"] == "running":
                receipt.update(status="interrupted", finished_at=now(),
                               error="Previous verifier stopped before writing its final receipt.")
                save_json(path, receipt)
                task["status"] = "needs_attention"
        self.write(task)

    def status(self, task):
        result = dict(task)
        result["verification_current"] = False
        receipt = None
        if task["runs"]:
            path = self.receipt_path(task["id"], task["runs"][-1])
            if path.exists():
                receipt = json.loads(path.read_text())
                result["last_receipt"] = str(path.relative_to(self.root))
                result["last_run_status"] = receipt["status"]
                result["verification_current"] = (receipt["status"] == "passed"
                                                    and receipt["source"] == self.snapshot(task))
                if receipt["status"] == "passed" and not result["verification_current"]:
                    result["status"] = "verification_stale"
        gate = UIGate(self).assess(task, receipt)
        if receipt and receipt["status"] == "passed" and not result["verification_current"]:
            gate = {"status": "stale", "problems": ["Code or task contract changed; run verify again."]}
        result["gates"] = {"automated_checks": "passed" if result["verification_current"] else "not_current",
                           "ui": gate, "human_acceptance": "pending"}
        result["ready_for_user_review"] = (result["verification_current"]
                                           and gate["status"] in ("passed", "not_applicable"))
        if result["verification_current"]:
            result["status"] = "awaiting_user_review" if result["ready_for_user_review"] else "awaiting_ui_verification"
        return result

    def verify(self, task, timeout=900):
        self.require_branch()
        UIGate(self).preflight(task)
        self.recover(task)
        if len(task["runs"]) >= MAX_ATTEMPTS:
            raise ValueError("Three verification attempts used. Stop and review the evidence with the user.")
        run_id = uuid.uuid4().hex
        path = self.receipt_path(task["id"], run_id)
        source = self.snapshot(task)
        receipt = {"version": 1, "task_id": task["id"], "run_id": run_id,
                   "status": "running", "started_at": now(), "source": source,
                   "timeout_seconds_per_step": timeout, "steps": [], "human_review": "pending"}
        save_json(path, receipt)
        task["runs"].append(run_id)
        task["status"] = "verifying"
        self.write(task)
        commands = [
            ("harness-tests", [sys.executable, "-m", "unittest", "discover", "-s", "scripts/tests"]),
            ("swift-tests", ["swift", "test"]),
            ("macos-build", ["env", "SD_BUILD_ONLY=1", "./dev.sh"]),
        ]
        try:
            for name, command in commands:
                print("Running " + name + " — log: " + str(path.parent / (name + ".log")), flush=True)
                step = run_step(command, self.root, path.parent / (name + ".log"), timeout)
                step["name"] = name
                receipt["steps"].append(step)
                save_json(path, receipt)
                if step["status"] != "passed":
                    receipt["status"] = "failed"
                    break
            else:
                receipt["status"] = "passed"
            if receipt["status"] == "passed" and task["ui"]["mode"] == "required":
                try:
                    receipt["artifact"] = build_artifact(self.root)
                except (ValueError, OSError, KeyError) as error:
                    receipt.update(status="failed", error=str(error))
            receipt["source_after"] = self.snapshot(self.load(task["id"]))
            if receipt["source_after"] != source:
                receipt.update(status="failed", error="Source or task contract changed during verification.")
        except BaseException as error:
            receipt.update(status="interrupted", error=str(error) or type(error).__name__)
            raise
        finally:
            receipt["finished_at"] = now()
            save_json(path, receipt)
            # Keep contract/notes edited in an external editor during a long build.
            current = self.load(task["id"])
            current["status"] = ("awaiting_ui_verification" if current["ui"]["mode"] == "required"
                                 else "awaiting_user_review") if receipt["status"] == "passed" else "needs_attention"
            self.write(current)
            task.update(current)
        print(str(path))
        return receipt["status"] == "passed"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    new = commands.add_parser("new", help="Create a scoped task; does not grant approval to edit code")
    new.add_argument("task_id")
    new.add_argument("--goal", required=True)
    new.add_argument("--scope", action="append", required=True)
    new.add_argument("--accept", action="append", required=True)
    new.add_argument("--ui", choices=("required", "none"), default="required")
    new.add_argument("--ui-reason", default="")
    for name in ("status", "check", "recover", "note", "verify", "ui-plan", "ui-begin", "ui-record"):
        command = commands.add_parser(name)
        command.add_argument("task_id")
        if name == "note":
            command.add_argument("text")
        if name == "verify":
            command.add_argument("--timeout", type=int, default=900, choices=range(1, 3601), metavar="1..3600")
        if name == "ui-plan":
            command.add_argument("file", type=Path)
        if name == "ui-begin":
            command.add_argument("--pid", type=int, required=True)
        if name == "ui-record":
            command.add_argument("session")
            command.add_argument("scenario")
            command.add_argument("step")
            command.add_argument("--result", choices=("passed", "failed", "blocked"), required=True)
            command.add_argument("--actual", required=True)
            command.add_argument("--before", type=Path)
            command.add_argument("--after", type=Path)
    args = parser.parse_args()
    harness = Harness(Path(__file__).resolve().parent.parent)
    try:
        # Atomic JSON writes make read-only status safe while verification owns the lock.
        if args.command in ("status", "check"):
            result = harness.status(harness.load(args.task_id))
            if args.command == "check":
                result = {key: result[key] for key in ("id", "status", "gates", "ready_for_user_review")}
            print(json.dumps(result, ensure_ascii=False, indent=2))
            return 0 if args.command == "status" or result["ready_for_user_review"] else 3
        with workspace_lock(harness.root):
            if args.command == "new":
                result = harness.new(args.task_id, args.goal, args.scope, args.accept, args.ui, args.ui_reason)
            else:
                task = harness.load(args.task_id)
                if args.command == "verify":
                    if not harness.verify(task, args.timeout):
                        return 1
                    result = harness.status(harness.load(args.task_id))
                    print(json.dumps(result["gates"], ensure_ascii=False, indent=2))
                    return 0 if result["ready_for_user_review"] else 3
                if args.command == "ui-plan":
                    plan = validate_plan(json.loads(args.file.read_text()))
                    task["ui"] = dict(task["ui"], mode="required", plan=plan)
                    task["status"] = "verification_stale" if task["runs"] else "planned"
                    harness.write(task)
                if args.command == "ui-begin":
                    print(json.dumps(UIGate(harness).begin(task, args.pid), ensure_ascii=False, indent=2))
                    return 0
                if args.command == "ui-record":
                    result = UIGate(harness).record(task, args.session, args.scenario, args.step,
                                                   args.result, args.actual, args.before, args.after)
                    print(json.dumps(result, ensure_ascii=False, indent=2))
                    return 0
                if args.command == "recover":
                    harness.recover(task)
                if args.command == "note":
                    if not args.text.strip():
                        raise ValueError("Note must not be empty.")
                    task["notes"].append({"at": now(), "text": args.text})
                    harness.write(task)
                result = harness.status(task)
            print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print("Harness: " + str(error), file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("Verification interrupted; evidence retained. Use status/recover to continue.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    def interrupted(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    sys.exit(main())
