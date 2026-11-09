#!/usr/bin/env bash
# make-app.sh — 组装并签名 build/Winductor.app（签名说明见 docs/signing.md）。
# 用法：Scripts/make-app.sh [swift build 参数透传]
#   CODESIGN_IDENTITY=证书名 Scripts/make-app.sh   # 覆盖自动选择的证书
#   RELEASE=1 Scripts/make-app.sh                   # 通用二进制（arm64+x86_64）
# 证书选择：CODESIGN_IDENTITY → 唯一的 Developer ID Application → 自签证书 Winductor Dev（过渡期）。
# 仅 Developer ID 签名加安全时间戳（需联网；公证要求），其余离线可构建。
# 流程：swift build -c release → 组装 .app（Info.plist 冻结字段见下）→ codesign（Hardened Runtime）。
set -euo pipefail

APP_NAME="Winductor"
BUNDLE_ID="com.lkangd.winductor" # 冻结：TCC designated requirement 含 identifier，一变全部用户授权失效
DISPLAY_NAME="Winductor"
SELF_SIGNED_IDENTITY="Winductor Dev"

cd "$(dirname "$0")/.."
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

BUILD_ARGS=(-c release --product "$APP_NAME")
if [ "${RELEASE:-0}" = "1" ]; then
    BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    IDENTITY="$CODESIGN_IDENTITY"
else
    DEVELOPER_IDS="$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | tr -d '"' | sort -u || true)"
    COUNT="$(printf '%s' "$DEVELOPER_IDS" | grep -c . || true)"
    if [ "$COUNT" = "1" ]; then
        IDENTITY="$DEVELOPER_IDS"
    elif [ "$COUNT" != "0" ]; then
        echo "错误：找到多张 Developer ID Application 证书，请用 CODESIGN_IDENTITY 指定其一：" >&2
        printf '  %s\n' "$DEVELOPER_IDS" >&2
        exit 1
    # 自签证书有时不被 find-identity 枚举，但 codesign 能用，故按证书本体查
    elif security find-certificate -c "$SELF_SIGNED_IDENTITY" >/dev/null 2>&1; then
        IDENTITY="$SELF_SIGNED_IDENTITY"
    else
        cat >&2 <<MSG
错误：登录钥匙串里既没有「Developer ID Application」证书，也没有自签证书「$SELF_SIGNED_IDENTITY」。

过渡期（还没有 Apple Developer Program 账号）先创建自签证书（一次性）：
  钥匙串访问 → 菜单栏「钥匙串访问」→ 证书助理 → 创建证书
    名称：$SELF_SIGNED_IDENTITY
    身份类型：自签名根证书
    证书类型：代码签名
    勾选「让我覆盖这些默认值」，有效期填 3650 天
  创建并存入登录钥匙串后，重新运行本脚本。

有 Developer ID 后：运行 Scripts/setup-distribution.sh（详见 docs/signing.md）。
MSG
        exit 1
    fi
fi

TIMESTAMP_FLAG="--timestamp=none"
case "$IDENTITY" in
    "Developer ID Application:"*) TIMESTAMP_FLAG="--timestamp" ;;
esac

echo "==> swift build ${BUILD_ARGS[*]}"
swift build "${BUILD_ARGS[@]}" "$@"
BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/$APP_NAME"
if [ ! -x "$BIN" ]; then
    echo "错误：未找到可执行文件 $BIN" >&2
    exit 1
fi

echo "==> 组装 $APP_DIR（$VERSION ($BUILD_NUMBER)，$(lipo -archs "$BIN")）"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BIN" "$APP_DIR/Contents/MacOS/$APP_NAME"

# 品牌资源（ui-refactor spec §3）：运行时由 MenubarKit 的 BrandAssets 只从 Contents/Resources 读——
# 菜单栏两态原图原样拷入；应用图标由 appiconset 经 iconutil 生成 AppIcon.icns（Info.plist 的 CFBundleIconFile 指向它）
BRAND_DIR="Resources/Brand"
RES_DIR="$APP_DIR/Contents/Resources"
ICONSET="$BUILD_DIR/AppIcon.iconset"
mkdir -p "$RES_DIR"
cp "$BRAND_DIR"/MenuBar*.png "$RES_DIR/"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
cp "$BRAND_DIR"/AppIcon.appiconset/icon_*.png "$ICONSET/" # iconutil 只认 .iconset 目录 + 规范文件名，不收 Contents.json
iconutil -c icns "$ICONSET" -o "$RES_DIR/AppIcon.icns"
rm -rf "$ICONSET"

# Info.plist：CFBundleIdentifier 冻结；LSUIElement=true 即菜单栏 agent（无 Dock 图标）
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> codesign「$IDENTITY」（Hardened Runtime，$TIMESTAMP_FLAG）"
if ! codesign --force --options runtime "$TIMESTAMP_FLAG" --sign "$IDENTITY" "$APP_DIR"; then
    cat >&2 <<MSG
错误：证书「$IDENTITY」不可用于签名（通常 = 证书不存在、没有配对私钥，或 Developer ID 签名时连不上苹果时间戳服务器）。
若你有含私钥的 .p12 备份：钥匙串访问导入后重试；否则按 docs/signing.md 重新创建证书。
MSG
    exit 1
fi
codesign --verify --strict --verbose=1 "$APP_DIR"

echo "==> 完成：$APP_DIR"
echo "    启动：open $APP_DIR （应成为无 Dock 图标的菜单栏 agent）"
echo "    复核：codesign -dv $APP_DIR （Identifier=$BUNDLE_ID、flags 含 runtime）"
