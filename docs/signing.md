# 签名与授权前置操作手册（spec §4 落地）

> 票 10 把 spec §4 的 HITL 清单整理成可照抄的操作手册。本工程**无 .xcodeproj**：
> 日常构建走 `Scripts/make-app.sh`（swift build → 组装 `build/WindowLayoutRestorer.app` → codesign），
> 证书名默认 `WindowLayoutRestorer Dev`（可用 `CODESIGN_IDENTITY` 环境变量覆盖）。
> §3 的 Xcode 红线适用于将来用 Xcode 构建此工程时的配置；当前按脚本签名时已天然满足。

## 0. 为什么必须自签证书（背景）

TCC 授权（辅助功能 / 屏幕录制）绑定代码签名身份。ad-hoc 签名每次重编译都变 → 授权**静默失效**，
每次重建都要重开两个系统开关。自签证书身份稳定 → designated requirement 稳定 →
**TCC 授权跨重建、跨重启保留**。Developer ID（公证/分发他人）与纯自用冲突，不买。

两个**冻结项**（改动即废全部 TCC 授权）：
- bundle ID：`com.lkd.window-restore`（spec §4.4，spec 定稿即永久冻结，此后重构不得更改）
- 证书有效期 3650 天：默认 365 太短，过期重建 = 换身份 = 全部重授权

## 1. 创建自签代码签名证书（一次性，人工步骤）

1. 打开 **钥匙串访问**（Keychain Access）
2. 菜单栏 **钥匙串访问 → 证书助理 → 创建证书…**
3. 填写：
   - **名称**：`WindowLayoutRestorer Dev`（须与 make-app.sh 默认一致；用别的名字则构建时
     `CODESIGN_IDENTITY=证书名 Scripts/make-app.sh`）
   - **身份类型**：自签名根证书
   - **证书类型**：代码签名
   - **电子邮件地址**：留空
   - **有效期（天）**：`3650`
4. 点「创建」→ 证书落入**登录**钥匙串
5. 验证：

   ```bash
   security find-identity -v -p codesigning
   # 应出现一行：  N) <40位哈希> "WindowLayoutRestorer Dev"
   ```

## 2. 导出 `.p12` 私密备份（一次性）

1. 钥匙串访问 → 登录钥匙串 → 「证书」类别 → 右键 `WindowLayoutRestorer Dev` → **导出…**
2. 格式选 **个人信息交换（.p12）**（含私钥），设强密码
3. 存到**私密位置**（私人云盘 / 加密盘）
4. **绝不放进 git 仓库**（任何目录都不行，勿依赖 .gitignore 兜底）

## 3. Xcode 签名红线（spec §4.3；本工程当前由 make-app.sh 代行）

若将来创建/使用 Xcode 工程构建本应用：

- 关闭 **"Automatically manage signing"**；不要选 "Sign to Run Locally"——
  **那就是 ad-hoc**，重编译授权失效
- **Code Signing Identity** 显式填证书名 `WindowLayoutRestorer Dev`
- bundle ID 显式填 `com.lkd.window-restore`（冻结）
- **不启用 Hardened Runtime、不做公证**（纯自用不上架）

`Scripts/make-app.sh` 已经按以上约束签名（显式 identity、无 hardened runtime 标志）。

## 4. 验证签名与冻结项

```bash
Scripts/make-app.sh
codesign -dv build/WindowLayoutRestorer.app
# 应看到：Identifier=com.lkd.window-restore、Authority=WindowLayoutRestorer Dev

# designated requirement（TCC 绑定的本体；重编译前后应不变）：
codesign -dvr- build/WindowLayoutRestorer.app
```

**跨重建复核**：改一行代码 → 重新 `Scripts/make-app.sh` → `codesign -dvr-` 输出应与之前一致
（`identifier "com.lkd.window-restore" and certificate leaf = 证书哈希`）。
这是「重编译后 TCC 授权保留」的前提，票 10 验收项之一。

## 5. 首启授权（应用侧硬前置，票 18 接引导窗）

顺序固定：**辅助功能 → 屏幕与系统录音**。两项齐备前应用保持**未就绪**（只轮询、不落盘快照、
不触发恢复）；授权生效需**重启应用一次**。不做无权限降级运行（spec §4.6/§8.3）。

## 6. 重置与兜底

```bash
# 显式重置某项授权（重新走一次授权即可恢复）
tccutil reset Accessibility com.lkd.window-restore
tccutil reset ScreenCapture com.lkd.window-restore
```

- **证书丢失**：按「重新授权一次」的可接受代价兜底（重新创建同名证书 + 两个开关点回；
  spec 不依赖「同名重建保持 DR」的社区经验）
- **Gatekeeper**：仅跨机拷贝 .app 时需放行一次（右键「打开」或 `xattr -cr <app>`），
  本机构建产物无 quarantine 属性，不是首启步骤
