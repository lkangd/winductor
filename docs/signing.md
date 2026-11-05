# Winductor 签名、公证与分发手册

> 本工程**无 .xcodeproj**：日常构建走 `make app`（`Scripts/make-app.sh`：swift build → 组装
> `build/Winductor.app` → Developer ID 签名 + Hardened Runtime），发布走 `make release`
> （`Scripts/release.sh`）。一次性前置步骤用向导 `make setup-dist`（`Scripts/setup-distribution.sh`）完成。
> 还没有 Developer ID 时按「过渡期」一节用自签证书开发和本地打包。
> 分发方式：Developer ID 签名 + 苹果公证，DMG 发布到 GitHub Releases，不上 Mac App Store
> （App Sandbox 不允许操作其他应用的窗口，且审核拒绝私有 API）。

## 0. 为什么开发和发布用同一张证书

TCC 授权（辅助功能 / 屏幕录制）绑定 designated requirement（bundle ID + 签名证书）。
同一 bundle ID 换证书签名会顶掉授权。开发构建（`make app`）与发布构建（`make release`）
用同一张 Developer ID Application 证书、同一 bundle ID → 本机只需授权一次，开发版与安装版共用。

两个**冻结项**（发布后改动即废全部用户的 TCC 授权）：
- bundle ID：`com.lkangd.winductor`
- 签名证书：Developer ID Application（有效期 5 年；到期续签同一 Team 的新证书时，
  DR 按 Team ID 匹配，授权保留）

## 过渡期：没有 Developer ID 时

`make app` 找不到 Developer ID Application 证书时，自动改用自签证书 `Winductor Dev`
（bundle ID、Hardened Runtime、版本号等其余流程不变）。一次性创建：

1. 钥匙串访问 → 菜单栏「钥匙串访问」→ 证书助理 → 创建证书…
2. 名称 `Winductor Dev`，身份类型「自签名根证书」，证书类型「代码签名」；
   勾选「让我覆盖这些默认值」，有效期填 `3650` 天（默认 365 天，过期重建 = 重新授权）
3. 存入登录钥匙串后 `make app`

本地打包：`make dmg` 产出通用二进制 + 用同一张证书签名的 `build/Winductor-<VERSION>.dmg`，
**不公证**。别人首次打开会被 Gatekeeper 拦截，需要右键「打开」或在系统设置 → 隐私与安全性里放行；
`make release` 仍只接受 Developer ID。

拿到 Developer ID 后运行 `make setup-dist`：`make app` 自动优先选 Developer ID，向导最后一步
清掉 `Winductor Dev` 签名留下的授权、可选删除这张自签证书，再重新授权一次。

## 1. 一次性前置（人工步骤，向导 `make setup-dist` 会逐步引导）

1. **加入 Apple Developer Program**（个人，99 美元/年）：<https://developer.apple.com/programs/enroll/>。
   审核通过后才能创建 Developer ID 证书。
2. **创建 Developer ID Application 证书**：Xcode → Settings → Accounts → 选中 Apple ID →
   Manage Certificates… → 左下角 + → Developer ID Application。证书和私钥落入登录钥匙串。
   验证：

   ```bash
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

3. **导出 `.p12` 私密备份**：钥匙串访问 → 登录钥匙串 → 「我的证书」→ 右键该证书 → 导出…，
   格式选 .p12（含私钥），设强密码，存到私密位置。**绝不放进 git 仓库**。
   私钥丢失 = 只能新建证书，所有用户需重新授权。
4. **公证凭据**：在 <https://account.apple.com> → 登录与安全 → App 专用密码，生成一个，然后：

   ```bash
   xcrun notarytool store-credentials winductor-notary \
       --apple-id 你的AppleID邮箱 --team-id 你的TeamID --password App专用密码
   ```

   凭据存进登录钥匙串，脚本按名字 `winductor-notary` 读取（`NOTARY_PROFILE` 可覆盖）。
5. **GitHub 仓库**：`gh auth login`，然后 `gh repo create` 并设为 `origin`。

## 2. 日常开发：`make app`

- 证书选择：`CODESIGN_IDENTITY` → 钥匙串里**唯一**一张 Developer ID Application → 自签 `Winductor Dev`。
  有多张 Developer ID 或想临时用别的证书时用 `CODESIGN_IDENTITY=证书名 make app`（换证书会让本机授权失效）。
- 只编本机架构；仅 Developer ID 签名加安全时间戳，自签证书离线可构建。
- 始终开启 Hardened Runtime（`--options runtime`），开发与发布行为一致。
  私有框架（SkyLight / HIServices）经 `dlopen` 加载的是苹果签名的系统库，库校验直接放行，
  **不需要任何 entitlement**；辅助功能 / 屏幕录制靠运行时 TCC 授权，同样不需要 entitlement。
- 版本号：`VERSION` 文件 → `CFBundleShortVersionString`；`git rev-list --count HEAD` → `CFBundleVersion`。

## 3. 发布：`make release`

先把 `VERSION` 改成新版本号并提交，然后 `make release`。脚本依次：

1. 预检：工作区干净、`v<VERSION>` tag 不存在、有 origin、gh 已登录、公证凭据可用；跑 `swift test`。
2. `RELEASE=1` 构建：通用二进制（arm64 + x86_64）+ 安全时间戳；确认签名证书是 Developer ID Application。
3. `.app` 打 zip 提交公证 → 通过后 `stapler staple` 到 `.app`（用户从 DMG 拷出后离线首启也能过 Gatekeeper）。
4. `Scripts/make-dmg.sh` 打包 `build/Winductor-<VERSION>.dmg`（含 `/Applications` 快捷方式）并签名 → 公证 → staple。
5. 验收：`codesign --verify --strict`、`spctl --assess`（.app 与 DMG）、`stapler validate`。
6. 确认后打 `v<VERSION>` tag、推送、`gh release create` 上传 DMG。

公证失败时脚本会拉取 `notarytool log` 打印苹果给出的具体问题。

## 4. 验证签名

```bash
codesign -dvv build/Winductor.app
# 应看到：Identifier=com.lkangd.winductor、Authority=Developer ID Application: …、flags=0x10000(runtime)

# designated requirement（TCC 绑定的本体；重编译前后应不变）：
codesign -dvr- build/Winductor.app
```

## 5. 首启授权

顺序固定：**辅助功能 → 屏幕与系统录音**。两项齐备前应用保持**未就绪**（只轮询、不落盘快照、
不触发恢复）；授权生效需**重启应用一次**。不做无权限降级运行。

## 6. 重置与兜底

```bash
# 显式重置某项授权（重新走一次授权即可恢复）
tccutil reset Accessibility com.lkangd.winductor
tccutil reset ScreenCapture com.lkangd.winductor
```

- **证书丢失**：从 .p12 备份导入；没有备份只能新建证书，所有用户需重新授权一次。
- **Gatekeeper 拦截**：说明公证或 staple 没成功，用 `spctl --assess -vv` 和 `xcrun stapler validate` 排查。
