#!/usr/bin/env bash
# release.sh — Developer ID 分发：构建 → 公证 .app → 打 DMG → 公证 DMG → 验收 → 打 tag → GitHub Release。
# 用法：先改 VERSION 并提交，再 make release（或 Scripts/release.sh）。
#   NOTARY_PROFILE=名字   覆盖 notarytool 钥匙串凭据名（默认 winductor-notary）
# 一次性前置（证书、公证凭据、GitHub 仓库）：Scripts/setup-distribution.sh
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="Winductor"
APP_DIR="build/$APP_NAME.app"
NOTARY_PROFILE="${NOTARY_PROFILE:-winductor-notary}"
VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v$VERSION"
DMG="build/$APP_NAME-$VERSION.dmg"
WORK="build/release-work"

die() { echo "错误：$*" >&2; exit 1; }

notarize() {
    local file="$1" result status id
    result="$WORK/notary-$(basename "$file").json"
    echo "==> 提交公证：$file（通常几分钟）"
    xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$result" || true
    status="$(plutil -extract status raw -o - "$result" 2>/dev/null || echo unknown)"
    id="$(plutil -extract id raw -o - "$result" 2>/dev/null || echo "")"
    if [ "$status" != "Accepted" ]; then
        echo "公证未通过（status=$status）。" >&2
        [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2
        cat "$result" >&2
        exit 1
    fi
    echo "    公证通过（$id）"
}

echo "==> 预检 $TAG"
[ -z "$(git status --porcelain)" ] || die "工作区不干净，先提交或清理（发布必须对应一个确定的提交）"
! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || die "tag $TAG 已存在，先在 VERSION 里升版本号"
git remote get-url origin >/dev/null 2>&1 || die "没有 origin 远程仓库，先运行 Scripts/setup-distribution.sh"
gh auth status >/dev/null 2>&1 || die "gh 未登录，先运行 gh auth login"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "钥匙串里没有可用的公证凭据「$NOTARY_PROFILE」，先运行 Scripts/setup-distribution.sh"

echo "==> swift test"
swift test

rm -rf "$WORK"
mkdir -p "$WORK"
RELEASE=1 bash Scripts/make-app.sh

IDENTITY="$(codesign -dvv "$APP_DIR" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
case "$IDENTITY" in
    "Developer ID Application:"*) ;;
    *) die "发布构建必须用 Developer ID Application 证书签名，当前是「$IDENTITY」" ;;
esac

ditto -c -k --keepParent "$APP_DIR" "$WORK/$APP_NAME.zip"
notarize "$WORK/$APP_NAME.zip"
xcrun stapler staple "$APP_DIR"

bash Scripts/make-dmg.sh
notarize "$DMG"
xcrun stapler staple "$DMG"

echo "==> 验收"
codesign --verify --strict --verbose=1 "$APP_DIR"
spctl --assess --type execute --verbose "$APP_DIR"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
xcrun stapler validate "$APP_DIR"
xcrun stapler validate "$DMG"

echo ""
read -r -p "发布 $TAG（$(git rev-parse --short HEAD)）到 GitHub Releases？[y/N] " answer
[ "$answer" = "y" ] || [ "$answer" = "Y" ] || { echo "已取消；产物保留在 $DMG"; exit 0; }

git tag -a "$TAG" -m "$APP_NAME $VERSION"
git push origin "$TAG"
gh release create "$TAG" "$DMG" --title "$APP_NAME $VERSION" --generate-notes --verify-tag
echo "==> 完成：$(gh release view "$TAG" --json url -q .url)"
