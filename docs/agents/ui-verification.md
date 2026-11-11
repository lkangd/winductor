# UI verification (all agents / human CLI)

This workflow is agent-neutral and macOS-only. It does not depend on Pi. Requirements: selected Xcode, Python 3.12+, and real 1×/2× displays for the full render matrix.

## Entry point

Prepare the product with the normal app build workflow, then run:

```bash
make check-ui
# Custom, already-prepared product and a fresh output directory:
make check-ui APP=/path/to/Winductor.app OUT=/tmp/winductor-ui-RUN
```

The runner does not build, install, register, launch, restart or re-sign the product and does not change permissions. It briefly shows test-owned windows to obtain real backing scales. The existing render script adjusts only a temporary copy of the XCTest host, then deletes it.

`build/verification/ui-*/report.json` is the default report location. Existing output directories are rejected so old logs cannot make a new run look complete. Full logs, binary SHA-256/mtime, bundle metadata, SDK load commands, Git state and Winductor process paths/PIDs/start times sit beside the report. The executable must remain unchanged during verification.

## Evidence levels

- **unit**: current-source `swift test`; retains passed/failed/skipped counts. Inherited render-directory variables are cleared. If this stage fails or has no case results, the runner refuses to use a stale test bundle.
- **render_1x / render_2x**: the existing `Scripts/test-mainwindow-render.sh`, against the supplied product's linked SDK. Both required tests must actually pass; product/host SDK, requested/actual backing and light/dark evidence must be present and agree. A skip, missing display, missing case or SDK mismatch is **not_verified**, never a pass.
- **manual_acceptance**: always **not_verified** in the generated report. Only an explicit user confirmation on the actual app/device provides this evidence. Record that confirmation and the tested build/device in the task/handoff; do not infer it from screenshots or test counts.

The render stage checks button labels and action/disabled behavior, not every page or menu. Its source is compiled from the current checkout; the supplied app contributes SDK identity/resources. The runner does not claim that current source matches an already-running product, nor that a process with the right path proves visual correctness. Use the recorded build/process metadata when preparing actual-device acceptance.

Exit 0 means all three **automated** stages passed; the overall acceptance remains `pending_manual`. Missing prerequisites or any failed/incomplete automated stage returns nonzero and preserves the report. Both scale stages are attempted after a passing unit stage, even if the first scale fails.

## Known 1× instability

`.scratch/ui-refactor/issues/12-render-1x-stability.md` records a real 1× check failure after an earlier successful run. This workflow preserves that failure; it neither loosens thresholds nor changes product UI. Keep `check-ui` explicit rather than adding a screen-dependent/flaky check to pre-commit. Stabilize its signal in a separate, authorized task before making it a required merge gate.

## Regression checks

`make test-tooling` covers false-green cases (zero tests, skipped required tests, wrong SDK/scale, incomplete appearance evidence), both-stage execution and report retention. These are deterministic CLI tests and run from `make check`; they do not require a GUI.
