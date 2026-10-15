#!/usr/bin/env python3
"""Run the existing 7200-second iPad soak with host-power evidence.

Requires a separately prepared .xctestrun and Simulator. Issues no direct
device-provisioning, installation, or reset commands. xcodebuild may install
the prepared products; the selected XCTest retains its existing isolated
fixture reset/setup and 8100-second allowance.
Uses only Python's standard library and existing macOS/Xcode utilities.
"""

import argparse
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import sys
import time
import uuid


TEST = "BandalUITests/IPadMixedSoakTests/testOptInMixedWorkspaceSoak"
RUNNER_DEADLINE_SECONDS = 9000
SECONDS_KEYS = {"BANDAL_IPAD_SOAK_SECONDS", "TEST_RUNNER_BANDAL_IPAD_SOAK_SECONDS"}
POWER_EVENT = re.compile(
    r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4})\s+"
    r"(Sleep|DarkWake|Wake)[ \t]{2,}(.*)$"
)
COMPLETED = re.compile(
    r"^\[IPAD_MIXED_SOAK\] completed elapsed=([\d.]+)s requested=([\d.]+)s "
    r"cycles=(\d+) canonicalDrawings=(\d+) pending=(\d+) restarts=(\d+);", re.M
)
PASSED = re.compile(
    r"^Test Case '-\[BandalUITests\.IPadMixedSoakTests "
    r"testOptInMixedWorkspaceSoak\]' passed \(([\d.]+) seconds\)\.", re.M
)


def now():
    return dt.datetime.now().astimezone()


def write_json(path, value):
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2, allow_nan=False)
        stream.write("\n")


def capture(command, timeout=15):
    try:
        result = subprocess.run(command, capture_output=True, text=True,
                                errors="replace", timeout=timeout, check=False)
        return {"command": command, "exit_code": result.returncode,
                "stdout": result.stdout, "stderr": result.stderr}
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"command": command, "exit_code": None, "error": str(error)}


def caffeinate_assertions(text, target_pid):
    """Match owned assertions and their beneficiary, not system-wide totals."""
    owned = {}
    current = None
    for line in text.splitlines():
        owner = re.match(r"\s*pid (\d+)\(([^)]+)\):.*?\b(Prevent\w+)\b", line)
        if owner:
            current = (int(owner[1]), owner[2], owner[3])
        elif re.match(r"\s*pid \d+\(", line):
            current = None
        beneficiary = re.search(r"caffeinate asserting on behalf of .*\(pid (\d+)\)", line)
        if (current and current[1] == "caffeinate" and beneficiary and
                int(beneficiary[1]) == target_pid):
            owned[current[2]] = current[0]
    required = {"PreventSystemSleep", "PreventUserIdleDisplaySleep"}
    return {"confirmed": required <= owned.keys(), "owned_assertions": owned,
            "caffeinate_pids": sorted(set(owned.values()))}


def observe_caffeinate(child, interrupted):
    started = time.monotonic()
    deadline = started + 2.0
    observations = []
    matched = {"confirmed": False, "owned_assertions": {}, "caffeinate_pids": []}
    while child.poll() is None and not interrupted():
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        result = capture(["/usr/bin/pmset", "-g", "assertions"], remaining)
        observations.append({"at": now().isoformat(), "assertions": result})
        if result["exit_code"] == 0:
            matched = caffeinate_assertions(result.get("stdout", ""), child.pid)
            if matched["confirmed"]:
                break
        delay = min(0.1, deadline - time.monotonic())
        if delay > 0 and not interrupted():
            time.sleep(delay)
    return {"launcher_pid": child.pid, "elapsed_seconds": time.monotonic() - started,
            **matched, "observations": observations}


def host_power():
    battery = capture(["/usr/bin/pmset", "-g", "batt"], 5)
    lid = capture(["/usr/sbin/ioreg", "-r", "-k", "AppleClamshellState", "-d", "4"], 5)
    # Keep only power-state properties, not unrelated IORegistry identifiers.
    lid["stdout"] = "\n".join(line.strip() for line in lid.get("stdout", "").splitlines()
                              if re.search(r'"AppleClamshell(State|CausesSleep)"', line))
    match = re.search(r'"AppleClamshellState"\s*=\s*(Yes|No)', lid["stdout"])
    return {"at": now().isoformat(),
            "ac_power": battery["exit_code"] == 0 and "'AC Power'" in battery.get("stdout", ""),
            "lid_open": match.group(1) == "No" if match and lid["exit_code"] == 0 else None,
            "battery": battery, "clamshell": lid}


def process_sample(simulator):
    result = capture(["/bin/ps", "-A", "-o", "pid=,ppid=,rss=,comm="], 5)
    xcodes, apps = [], []
    for line in result.get("stdout", "").splitlines():
        fields = line.strip().split(None, 3)
        if len(fields) != 4:
            continue
        pid, parent, rss, executable = fields
        if not all(value.isdigit() for value in (pid, parent, rss)):
            continue
        item = {"pid": int(pid), "parent_pid": int(parent), "rss_kib": int(rss),
                "executable": executable}
        if Path(executable).name == "xcodebuild":
            xcodes.append(item)
        if f"/devices/{simulator.lower()}/" in executable.lower() and ".app/" in executable:
            apps.append(item)
    # Absence means unavailable/unobserved, not zero application memory usage.
    return {"ps_exit_code": result["exit_code"], "xcodebuild": xcodes,
            "target_simulator_app_processes": apps,
            "target_app_rss_observed": bool(apps),
            "error": result.get("error") or result.get("stderr") or None}


def parse_power_events(text, start, end):
    events = []
    # pmset has whole-second precision. Include the boundary second conservatively.
    for line in text.splitlines():
        match = POWER_EVENT.match(line)
        if not match:
            continue
        timestamp = dt.datetime.strptime(match[1], "%Y-%m-%d %H:%M:%S %z")
        if start.replace(microsecond=0) <= timestamp <= end:
            events.append({"at": timestamp.isoformat(), "kind": match[2],
                           "actual_sleep": match[2] == "Sleep" and
                           match[3].lstrip().startswith("Entering Sleep state"), "raw": line})
    return events


def power_evidence(start, end):
    result = capture(["/usr/bin/pmset", "-g", "log"], 30)
    return {"start": start.isoformat(), "end": end.isoformat(),
            "exit_code": result["exit_code"],
            "events": parse_power_events(result.get("stdout", ""), start, end),
            "error": result.get("error") or result.get("stderr") or None}


def test_cases(node):
    if isinstance(node, dict):
        if node.get("nodeType") == "Test Case":
            yield node
        for value in node.values():
            yield from test_cases(value)
    elif isinstance(node, list):
        for value in node:
            yield from test_cases(value)


def validate_result(log, exit_code, tests, evidence, interrupted=False, assertions_confirmed=False,
                    runner_deadline_exceeded=False):
    reasons = []
    if runner_deadline_exceeded:
        reasons.append("runner_deadline_exceeded")
    if not assertions_confirmed:
        reasons.append("caffeinate_assertions_unconfirmed")
    if exit_code != 0:
        reasons.append(f"execution_exit_code={exit_code}")
    if interrupted:
        reasons.append("interrupted")
    if "** TEST EXECUTE SUCCEEDED **" not in log:
        reasons.append("missing_xcodebuild_success_banner")
    passes = PASSED.findall(log)
    if len(passes) != 1 or not math.isfinite(float(passes[0])) or float(passes[0]) < 7200:
        reasons.append("missing_single_full_duration_XCTest_pass")
    cases = list(test_cases(tests))
    if (len(cases) != 1 or cases[0].get("result") != "Passed" or
            cases[0].get("nodeIdentifier") != "IPadMixedSoakTests/testOptInMixedWorkspaceSoak()"):
        reasons.append("xcresult_does_not_confirm_exactly_one_expected_pass")
    matches = COMPLETED.findall(log)
    marker = None
    if len(matches) == 1:
        elapsed, requested, cycles, drawings, pending, restarts = matches[0]
        marker = {"elapsed_seconds": float(elapsed), "requested_seconds": float(requested),
                  "cycles": int(cycles), "canonical_drawings": int(drawings),
                  "pending": int(pending), "restarts": int(restarts)}
    if (not marker or not math.isfinite(marker["elapsed_seconds"]) or
            marker["elapsed_seconds"] < 7200 or marker["requested_seconds"] != 7200 or
            marker["cycles"] < 1 or marker["pending"] != 0 or
            marker["canonical_drawings"] != marker["cycles"] + 1 or
            marker["restarts"] != marker["cycles"] // 3 + 1):
        reasons.append("missing_valid_7200_second_completion_marker")
    if evidence.get("exit_code") != 0:
        reasons.append("host_sleep_evidence_unavailable")
    if any(event.get("actual_sleep") for event in evidence.get("events", [])):
        reasons.append("actual_host_sleep_during_run")
    return {"valid_pass": not reasons, "invalid_reasons": reasons, "completion": marker}


def forbidden_plist_settings(value, path="root"):
    errors = []
    if isinstance(value, dict):
        for key, item in value.items():
            keypath = f"{path}.{key}"
            if key in SECONDS_KEYS:
                errors.append(f"Remove {keypath} from the prepared xctestrun; duration overrides are forbidden")
            if key in {"BANDAL_IPAD_SOAK", "TEST_RUNNER_BANDAL_IPAD_SOAK"} and str(item) != "1":
                errors.append(f"Conflicting soak opt-in in {keypath}")
            errors.extend(forbidden_plist_settings(item, keypath))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            errors.extend(forbidden_plist_settings(item, f"{path}[{index}]"))
    return errors


def stop_group(child):
    if child is None:
        return
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        child.wait(timeout=15)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait(timeout=5)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--xctestrun", type=Path, required=True, help="Separately prepared .xctestrun; never modified")
    parser.add_argument("--simulator", required=True, help="UUID of the separately prepared Simulator")
    parser.add_argument("--output-dir", type=Path, required=True, help="New directory; existing paths are refused")
    args = parser.parse_args(argv)
    try:
        simulator = str(uuid.UUID(args.simulator)).upper()
    except ValueError:
        parser.error("--simulator must be a UUID")
    xctestrun = args.xctestrun.expanduser().resolve()
    if not xctestrun.is_file() or xctestrun.suffix != ".xctestrun":
        parser.error("--xctestrun must be an existing .xctestrun file")
    output = args.output_dir.expanduser().absolute()
    try:
        output.mkdir(parents=True, exist_ok=False)
    except OSError as error:
        parser.error(f"Cannot create fresh output directory (nothing overwritten): {error}")

    child, received_signal, execution_exit = None, None, None
    runner_deadline_exceeded = False
    start, start_mono = now(), time.monotonic()
    state = {"status": "preflight_failed", "simulator": simulator,
             "xctestrun": str(xctestrun), "output_dir": str(output),
             "required_soak_seconds": 7200, "XCTest_allowance_seconds": 8100,
             "runner_deadline_seconds": RUNNER_DEADLINE_SECONDS}

    def on_signal(signum, _frame):
        nonlocal received_signal
        received_signal = received_signal or signum

    previous_handlers = {sig: signal.signal(sig, on_signal) for sig in
                         (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    try:
        plist_bytes = xctestrun.read_bytes()
        errors = forbidden_plist_settings(plistlib.loads(plist_bytes))
        if sys.platform != "darwin":
            errors.append("macOS is required")
        initial_power = host_power()
        initial_processes = process_sample(simulator)
        initial_evidence = power_evidence(start - dt.timedelta(minutes=5), now())
        if not initial_power["ac_power"]:
            errors.append("AC power must be confirmed before launch")
        if initial_power["lid_open"] is not True:
            errors.append("An open clamshell must be confirmed before launch")
        if initial_processes["ps_exit_code"] != 0:
            errors.append("Cannot inspect other xcodebuild processes")
        elif initial_processes["xcodebuild"]:
            errors.append("Other xcodebuild processes are running; use an isolated execution window")
        if initial_evidence["exit_code"] != 0:
            errors.append("Cannot collect host sleep evidence")
        preflight = {"at": now().isoformat(), "errors": errors,
                     "xctestrun_sha256": hashlib.sha256(plist_bytes).hexdigest(),
                     "host_power": initial_power, "processes": initial_processes,
                     "recent_power_evidence": initial_evidence}
        write_json(output / "preflight.json", preflight)
        if errors or received_signal:
            state["errors"] = errors
            return 2

        command = ["/usr/bin/caffeinate", "-dims", "/usr/bin/xcodebuild", "test-without-building",
                   "-xctestrun", str(xctestrun), "-destination", f"platform=iOS Simulator,id={simulator},arch=arm64",
                   "-resultBundlePath", str(output / "soak.xcresult"),
                   "-parallel-testing-enabled", "NO", "-maximum-concurrent-test-simulator-destinations", "1",
                   "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "8100",
                   "-maximum-test-execution-time-allowance", "8100", f"-only-testing:{TEST}"]
        environment = os.environ.copy()
        for key in SECONDS_KEYS:
            environment.pop(key, None)
        environment.pop("BANDAL_IPAD_SOAK", None)
        environment["TEST_RUNNER_BANDAL_IPAD_SOAK"] = "1"
        state.update({"command": command, "environment_overrides": {
            "TEST_RUNNER_BANDAL_IPAD_SOAK": "1", "removed": sorted(SECONDS_KEYS | {"BANDAL_IPAD_SOAK"})}})
        start, start_mono = now(), time.monotonic()
        state.update({"status": "running", "started_at": start.isoformat()})
        write_json(output / "invocation.json", state)
        with (output / "xcodebuild.log").open("x", encoding="utf-8") as log, \
                (output / "heartbeat.jsonl").open("x", encoding="utf-8", buffering=1) as heartbeats:
            child = subprocess.Popen(command, env=environment, stdout=log, stderr=subprocess.STDOUT,
                                     start_new_session=True)
            assertions = observe_caffeinate(child, lambda: bool(received_signal))
            state["caffeinate_assertions_confirmed"] = assertions["confirmed"]
            if not assertions["confirmed"]:
                stop_group(child)
            write_json(output / "assertions-after-launch.json", assertions)
            next_sample = time.monotonic()
            while not received_signal:
                # Wall time includes host sleep; monotonic time also bounds a
                # run whose wall clock is adjusted backwards while awake.
                if max((now() - start).total_seconds(), time.monotonic() - start_mono) >= RUNNER_DEADLINE_SECONDS:
                    runner_deadline_exceeded = True
                    stop_group(child)
                    break
                if child.poll() is not None:
                    break
                if time.monotonic() >= next_sample:
                    stamp, mono = now(), time.monotonic()
                    sample = {"at": stamp.isoformat(), "wall_seconds": (stamp - start).total_seconds(),
                              "monotonic_seconds": mono - start_mono, "launcher_pid": child.pid,
                              "processes": process_sample(simulator), "power": host_power()}
                    heartbeats.write(json.dumps(sample, ensure_ascii=False) + "\n")
                    print(f"[soak] {stamp.isoformat()} wall={sample['wall_seconds']:.1f}s "
                          f"monotonic={sample['monotonic_seconds']:.1f}s log={output / 'xcodebuild.log'}", flush=True)
                    next_sample = mono + 30
                time.sleep(0.25)
            if received_signal:
                stop_group(child)
            execution_exit = child.wait()
        end = now()
        # Always release any surviving caffeinate helper in this dedicated group.
        stop_group(child)
        evidence = power_evidence(start, end)
        write_json(output / "power-evidence.json", evidence)
        write_json(output / "host-end.json", host_power())
        # Sequential, only after xcodebuild closes its result bundle. Never invoke
        # two xcresulttool readers concurrently on the same mutable cache.
        result = capture(["/usr/bin/xcrun", "xcresulttool", "get", "test-results", "tests",
                          "--path", str(output / "soak.xcresult")], 60)
        write_json(output / "xcresult-query.json", result)
        try:
            tests = json.loads(result.get("stdout", "")) if result["exit_code"] == 0 else {}
        except json.JSONDecodeError:
            tests = {}
        verdict = validate_result((output / "xcodebuild.log").read_text(errors="replace"),
                                  execution_exit, tests, evidence, bool(received_signal),
                                  assertions_confirmed=assertions["confirmed"],
                                  runner_deadline_exceeded=runner_deadline_exceeded)
        if end < start:
            verdict["invalid_reasons"].append("wall_clock_moved_backwards")
            verdict["valid_pass"] = False
        state.update(verdict)
        state.update({"status": "passed" if verdict["valid_pass"] else "invalid_or_failed",
                      "finished_at": end.isoformat(), "wall_seconds": (end - start).total_seconds(),
                      "monotonic_seconds": time.monotonic() - start_mono,
                      "execution_exit_code": execution_exit})
        return 0 if verdict["valid_pass"] else (128 + received_signal
                                               if received_signal and not runner_deadline_exceeded else 1)
    except Exception as error:
        state.update({"status": "runner_error", "error": f"{type(error).__name__}: {error}"})
        return 1
    finally:
        stop_group(child)
        state["signal"] = received_signal
        state["runner_deadline_exceeded"] = runner_deadline_exceeded
        state.setdefault("execution_exit_code", execution_exit)
        state.setdefault("finished_at", now().isoformat())
        write_json(output / "summary.json", state)
        for sig, handler in previous_handlers.items():
            signal.signal(sig, handler)
        print(f"[soak] {state['status']}: {output / 'summary.json'}", flush=True)


if __name__ == "__main__":
    sys.exit(main())
