#!/usr/bin/env bash
# UI 验证必须使用与正式 app 相同的 linked-SDK，以及真实的 1×/2× backing。
# 用法：bash Scripts/test-mainwindow-render.sh [输出目录] [1|2]
# 单次诊断可能因缺少真实屏幕而跳过；完整验收用 make check-ui 汇总 skip/SDK/backing。
# 通用 macOS 检查，不依赖 Pi 或其他编码 agent。
# 仅在临时目录复制/重签 XCTest 宿主；不修改 Xcode、产品 SDK、应用签名或系统设置。
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="${WINDUCTOR_APP_BUNDLE_PATH:-$ROOT/build/Winductor.app}"
BIN="$APP/Contents/MacOS/Winductor"
OUT="${1:-/tmp/winductor-mainwindow-render}"
SCALE="${2:-1}"
[[ "$SCALE" == 1 || "$SCALE" == 2 ]] || { echo "scale 必须是 1 或 2" >&2; exit 2; }
[[ -x "$BIN" ]] || { echo "请先 make app" >&2; exit 2; }
DEV="$(xcode-select -p)"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
SDK="$(otool -l "$BIN" | awk '$1 == "sdk" { print $2; exit }')"
[[ -n "$SDK" ]] || { echo "无法读取产品 linked-SDK" >&2; exit 2; }

# 构建测试 bundle；只运行非渲染的样式单测，不拿默认 XCTest 的外观作验收。
swift test --filter MainWindowStyleTests
BUNDLE="$ROOT/.build/debug/MenubarKitTests.xctest"
if [[ ! -d "$BUNDLE" ]]; then BUNDLE="$ROOT/.build/debug/WinductorPackageTests.xctest"; fi
[[ -d "$BUNDLE" ]] || { echo "找不到 XCTest bundle" >&2; exit 2; }
HOST_DIR="$(mktemp -d /tmp/winductor-ui-xctest.XXXXXX)"
trap 'rm -rf "$HOST_DIR"' EXIT
HOST="$(xcrun -f xctest)"
HOST_MIN="$(otool -l "$HOST" | awk '$1 == "minos" { print $2; exit }')"
xcrun vtool -set-build-version macos "$HOST_MIN" "$SDK" -replace -output "$HOST_DIR/xctest" "$HOST"
chmod +x "$HOST_DIR/xctest"
codesign --force --sign - --identifier local.winductor.ui-test-host "$HOST_DIR/xctest"
mkdir -p "$OUT"
export DYLD_FRAMEWORK_PATH="$DEV/Platforms/MacOSX.platform/Developer/Library/Frameworks:$DEV/Platforms/MacOSX.platform/Developer/Library/PrivateFrameworks"
export DYLD_LIBRARY_PATH="$DEV/Platforms/MacOSX.platform/Developer/usr/lib:$DEV/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx"
export WINDUCTOR_APP_BUNDLE_PATH="$APP"
export WINDUCTOR_MAINWINDOW_RENDER_DIR="$OUT"
export WINDUCTOR_MAINWINDOW_RENDER_SCALE="$SCALE"
echo "==> UI host linked-SDK=$SDK, requested backing=${SCALE}×"
"$HOST_DIR/xctest" -XCTest 'MenubarKitTests.MainWindowRenderHarness/testContentButtonLabelsAreVerticallyCentered,MenubarKitTests.MainWindowRenderHarness/testContentButtonStyleKeepsActionsAndDisabledState' "$BUNDLE"
