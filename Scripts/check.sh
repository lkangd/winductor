#!/bin/bash
# Repo guardrail: build + test (+ format check when tools are installed).
# Run by .githooks/{pre-commit,post-merge,pre-push}; safe to run by hand.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || { cd "$(dirname "$0")/.." && pwd; })"
cd "$ROOT"

# Pin the SDK to the selected developer dir's macOS SDK so the swift toolchain and SDK match.
# /usr/bin/git is an xcrun shim that exports SDKROOT=<xcrun's default SDK> into hooks, and that
# default can be the CommandLineTools SDK even when xcode-select points at Xcode (SDK built by a
# newer Swift than Xcode's compiler -> "this SDK is not supported by the compiler").
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export SDKROOT

fail=0

echo "==> swift build"
if ! swift build 2>&1 | tail -5; then
  echo "CHECK FAILED: swift build" >&2
  fail=1
fi

echo "==> swift test"
if ! swift test 2>&1 | grep -E "Test Suite 'All tests'|error:|failed" | tail -8; then
  echo "CHECK FAILED: swift test" >&2
  fail=1
fi

if command -v swiftformat >/dev/null 2>&1; then
  echo "==> swiftformat --lint"
  swiftformat --lint . || { echo "CHECK FAILED: swiftformat --lint" >&2; fail=1; }
fi

if command -v swiftlint >/dev/null 2>&1; then
  echo "==> swiftlint"
  swiftlint || { echo "CHECK FAILED: swiftlint" >&2; fail=1; }
fi

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "check.sh: FAILED — commit/merge blocked (bypass once with --no-verify if truly needed)" >&2
  exit 1
fi
echo "check.sh: OK"
