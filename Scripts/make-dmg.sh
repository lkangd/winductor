#!/usr/bin/env bash
# make-dmg.sh — 把已构建的 build/Winductor.app 打成 build/Winductor-<VERSION>.dmg，并用 .app 的签名证书签 DMG。
# 不构建、不公证：make dmg 先跑 RELEASE=1 make-app.sh；make release 在公证 .app 之后调用本脚本再公证 DMG。
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="Winductor"
APP_DIR="build/$APP_NAME.app"
VERSION="$(tr -d '[:space:]' < VERSION)"
DMG="build/$APP_NAME-$VERSION.dmg"
STAGING="build/dmg-staging"

[ -d "$APP_DIR" ] || { echo "错误：没有 $APP_DIR，先运行 Scripts/make-app.sh" >&2; exit 1; }
IDENTITY="$(codesign -dvv "$APP_DIR" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
[ -n "$IDENTITY" ] || { echo "错误：$APP_DIR 没有证书签名" >&2; exit 1; }

echo "==> 打包 $DMG"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP_DIR" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGING"

TIMESTAMP_FLAG="--timestamp=none"
case "$IDENTITY" in
    "Developer ID Application:"*) TIMESTAMP_FLAG="--timestamp" ;;
esac
codesign --force "$TIMESTAMP_FLAG" --sign "$IDENTITY" "$DMG"
codesign --verify --verbose=1 "$DMG"
echo "==> 完成：$DMG（签名：$IDENTITY）"
