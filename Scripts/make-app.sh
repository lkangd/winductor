#!/usr/bin/env bash
# make-app.sh — 组装并签名 build/Winductor.app（票 10；spec §4 签名前置）。
# 用法：Scripts/make-app.sh [swift build 参数透传]
#   CODESIGN_IDENTITY=证书名 Scripts/make-app.sh   # 覆盖默认证书名
# 流程：swift build -c release → 组装 .app（Info.plist 冻结字段见下）→ codesign。
# 证书缺失：给出中文指引后退出非零（证书创建步骤见 docs/signing.md）。
set -euo pipefail

APP_NAME="Winductor"
BUNDLE_ID="com.lkd.window-restore" # 冻结（spec §4.4）：TCC designated requirement 含 identifier，一变授权全废
# 保留旧签名证书名以沿用现有 macOS 授权身份；它不是产品显示名。
IDENTITY="${CODESIGN_IDENTITY:-WindowLayoutRestorer Dev}"
DISPLAY_NAME="Winductor"

cd "$(dirname "$0")/.."
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
BIN=".build/release/$APP_NAME"

echo "==> swift build -c release"
swift build -c release "$@"
if [ ! -x "$BIN" ]; then
    echo "错误：未找到可执行文件 $BIN" >&2
    exit 1
fi

echo "==> 组装 $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BIN" "$APP_DIR/Contents/MacOS/$APP_NAME"

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
    <key>CFBundleName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> 检查签名证书「$IDENTITY」"
# 注意：不要用 security find-identity 做硬门禁——证书助理自签证书有时不会被它枚举，
# 但 codesign 完全能用。这里只查证书本体存在性；签名失败才是权威判据。
if ! security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    cat >&2 <<MSG
错误：登录钥匙串里没有名为「$IDENTITY」的可用的代码签名证书。

请按 docs/signing.md 创建（一次性 HITL 步骤）：
  钥匙串访问 → 菜单栏「钥匙串访问」→ 证书助理 → 创建证书
    名称：$IDENTITY
    身份类型：自签名根证书
    证书类型：代码签名
    有效期：3650 天
  创建并存入登录钥匙串后，重新运行本脚本。

若已有别的名字的证书：CODESIGN_IDENTITY=证书名 Scripts/make-app.sh

（.app 已组装在 $APP_DIR，仅差签名这一步。）
MSG
    exit 1
fi

echo "==> codesign --sign \"$IDENTITY\" --force"
if ! codesign --sign "$IDENTITY" --force "$APP_DIR"; then
    cat >&2 <<MSG
错误：证书「$IDENTITY」存在但不可用于签名（通常 = 没有配对私钥，或密钥不在登录钥匙串）。
若你有含私钥的 .p12 备份：钥匙串访问导入后重试；否则按 docs/signing.md 重建证书。
若用别的证书：CODESIGN_IDENTITY=证书名 Scripts/make-app.sh
MSG
    exit 1
fi
codesign --verify --verbose=1 "$APP_DIR"

echo "==> 完成：$APP_DIR"
echo "    启动：open $APP_DIR （应成为无 Dock 图标的菜单栏 agent，点菜单栏网格图标见占位菜单）"
echo "    复核：codesign -dv $APP_DIR （Authority=$IDENTITY / Identifier=$BUNDLE_ID）"
