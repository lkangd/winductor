#!/usr/bin/env python3
"""Agent-neutral UI verification. Never launches/replaces the product or changes permissions."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
RENDER_TESTS = {"testContentButtonLabelsAreVerticallyCentered", "testContentButtonStyleKeepsActionsAndDisabledState"}
CASE = re.compile(r"^Test Case ['‘](.+?)['’] (passed|failed|skipped)", re.MULTILINE)
ENVIRONMENT = re.compile(r"\[render-environment\] backingScale=([\d.]+) requestedScale=(\d+) dark=(true|false) width=([\d.]+) height=([\d.]+)")
SDK = re.compile(r"\[render-sdk\] product=([\d.]+) host=([\d.]+)")


def evaluate(log, code, scale=None):
    outcomes = CASE.findall(log)
    cases = dict(outcomes)
    counts = {state: sum(value == state for _name, value in outcomes) for state in ["passed", "failed", "skipped"]}
    result = {"exit_code": code, "tests": counts, "status": "failed" if code or counts["failed"] else "passed"}
    if scale is not None:
        environments = [{"actual_scale": float(actual), "requested_scale": int(requested), "dark": dark == "true",
                         "width": float(width), "height": float(height)}
                        for actual, requested, dark, width, height in ENVIRONMENT.findall(log)]
        sdks = [{"product": product, "host": host} for product, host in SDK.findall(log)]
        result.update({"environment": environments, "sdk": sdks})
    if code or counts["failed"]:
        return result
    if not cases:
        return {**result, "status": "not_verified", "reason": "no XCTest case results found"}
    if scale is not None:
        relevant = {name: state for name, state in cases.items() if any(test in name for test in RENDER_TESTS)}
        missing = [test for test in RENDER_TESTS if not any(test in name and state == "passed" for name, state in relevant.items())]
        if missing or any(state == "skipped" for state in relevant.values()):
            result.update(status="not_verified", reason="required render tests missing/skipped: " + ", ".join(sorted(missing)))
        elif not sdks or any(pair["product"] != pair["host"] for pair in sdks):
            result.update(status="not_verified", reason="product/host SDK equality was not verified")
        elif not environments or any(item["actual_scale"] != scale or item["requested_scale"] != scale for item in environments):
            result.update(status="not_verified", reason="requested and actual backing scale were not verified")
        elif {item["dark"] for item in environments} != {True, False}:
            result.update(status="not_verified", reason="light/dark render evidence incomplete")
    return result


def run_stage(command, log, env, scale=None):
    try:
        with log.open("w") as output:
            code = subprocess.run(command, cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT).returncode
        result = evaluate(log.read_text(errors="replace"), code, scale)
    except OSError as error:
        log.write_text(str(error) + "\n")
        result = {"status": "failed", "reason": str(error), "exit_code": None}
    return {**result, "command": command, "log": str(log)}


def fingerprint(binary):
    return hashlib.sha256(binary.read_bytes()).hexdigest()


def verify(app, out):
    app, out = app.resolve(), out.resolve()
    binary = app / "Contents/MacOS/Winductor"
    report = {
        "schema": 1, "created_at": datetime.now(timezone.utc).isoformat(),
        "scope": "Current-source XCTest and supplied product SDK/resources; not live-product visual acceptance",
        "app": str(app), "stages": {},
        "manual_acceptance": {"status": "not_verified", "reason": "Requires user's confirmation on the actual app/device; automation cannot infer it"},
    }
    if out.is_relative_to(app):
        raise ValueError("report output must be outside the product bundle")
    out.mkdir(parents=True, exist_ok=False)
    stages = report["stages"]
    try:
        if not binary.is_file():
            raise ValueError("product executable missing; prepare an app first (make app), then pass --app if needed")
        initial_hash = fingerprint(binary)
        report["product"] = {"sha256": initial_hash, "binary_modified_at": datetime.fromtimestamp(binary.stat().st_mtime, timezone.utc).isoformat()}
        report["metadata"] = {}
        for key, command in {
            "build_metadata": ["/usr/bin/otool", "-l", str(binary)],
            "bundle_identity": ["/usr/bin/plutil", "-p", str(app / "Contents/Info.plist")],
            "running_processes": ["/bin/ps", "-axo", "pid=,lstart=,command="],
            "git_state": ["git", "status", "--short"],
            "git_head": ["git", "rev-parse", "HEAD"],
        }.items():
            result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
            text = result.stdout
            if key == "running_processes":
                text = "\n".join(line for line in text.splitlines() if "/Contents/MacOS/Winductor" in line)
            metadata_log = out / f"{key}.txt"
            metadata_log.write_text(text + result.stderr)
            report["metadata"][key] = {"exit_code": result.returncode, "log": str(metadata_log)}
            if key in {"build_metadata", "bundle_identity"} and result.returncode:
                raise ValueError(f"required product metadata unavailable: {key}")
        env = os.environ.copy()
        # An inherited render directory must not turn the unit stage into accidental UI acceptance.
        for key in ["WINDUCTOR_MAINWINDOW_RENDER_DIR", "WINDUCTOR_MAINWINDOW_RENDER_SCALE"]:
            env.pop(key, None)
        env["WINDUCTOR_APP_BUNDLE_PATH"] = str(app)
        sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
        env["SDKROOT"] = sdk
        stages["unit"] = run_stage(["swift", "test"], out / "unit.log", env)
        for scale in [1, 2]:
            if stages["unit"]["status"] != "passed":
                stages[f"render_{scale}x"] = {"status": "not_run", "reason": "unit/build stage did not pass; refuse stale test bundle"}
            else:
                stages[f"render_{scale}x"] = run_stage(
                    ["bash", "Scripts/test-mainwindow-render.sh", str(out / f"render-{scale}x"), str(scale)],
                    out / f"render-{scale}x.log", env, scale)
        report["product"]["unchanged"] = fingerprint(binary) == initial_hash
        if not report["product"]["unchanged"]:
            raise ValueError("product changed during verification; evidence is not for one immutable executable")
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        report["preflight_error"] = str(error)
    expected = ["unit", "render_1x", "render_2x"]
    passed = not report.get("preflight_error") and all(stages.get(name, {}).get("status") == "passed" for name in expected)
    report["automated_status"] = "passed" if passed else "incomplete_or_failed"
    report["acceptance_status"] = "pending_manual" if passed else "not_accepted"
    (out / "report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / "build/Winductor.app")
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    if args.out:
        out = args.out
    else:
        parent = ROOT / "build/verification"
        parent.mkdir(parents=True, exist_ok=True)
        # Reserve a unique name, but let verify create it so reused output is rejected.
        out = Path(tempfile.mkdtemp(prefix="ui-", dir=parent))
        out.rmdir()
    try:
        report = verify(args.app, out)
    except (OSError, ValueError) as error:
        print(f"UI verification could not start: {error}")
        return 1
    for name in ["unit", "render_1x", "render_2x"]:
        stage = report["stages"].get(name, {"status": "not_run"})
        print(f"{name}: {stage['status']} {stage.get('reason', '')}")
    if report.get("preflight_error"):
        print(f"preflight: {report['preflight_error']}")
    print(f"manual_acceptance: not_verified\nautomated_status: {report['automated_status']}\nReport: {out.resolve() / 'report.json'}")
    return 0 if report["automated_status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
