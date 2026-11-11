ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
APP := $(ROOT)/build/Winductor.app
BIN := $(APP)/Contents/MacOS/Winductor
LOG := $(HOME)/Library/Application Support/Winductor/logs/app.log
# 实测常用的 app.log 关键行（make log FILTER=... 覆盖）
FILTER ?= aftershock|debounce-extend|deferred-consume|deferred wid|give-up|topology-changed-while|perf|done ok
N ?= 50

.PHONY: help build test test-tsan test-tooling test-pi-guardrails check check-ui app dmg release setup-dist relaunch displays spaces debug log log-follow hooks issue

help:
	@echo "Targets:"
	@echo "  make build          swift build"
	@echo "  make test           swift test"
	@echo "  make test-tsan      swift test --sanitize=thread（并发改动必跑）"
	@echo "  make check          Scripts/check.sh（pre-commit 同款门禁，不代表 UI 验收）"
	@echo "  make check-ui       单测 + 真 SDK/1x/2x UI 分层报告；先准备 app，不启动产品"
	@echo "  make test-tooling   通用验收/审查脚本回归（Python 3.12+）"
	@echo "  make test-pi-guardrails  Pi agent 专用扩展回归（先 npm ci --prefix .pi/extensions/codemode-guardrails）"
	@echo "  make app            Scripts/make-app.sh（release 构建 + 组装 + 签名：Developer ID，没有则用自签 Winductor Dev）"
	@echo "  make dmg            通用二进制 .app + 未公证 DMG（本地分发，对方首次打开需手动放行）"
	@echo "  make release        Scripts/release.sh（通用二进制 + 公证 + DMG + tag + GitHub Release；先改 VERSION 并提交）"
	@echo "  make setup-dist     Scripts/setup-distribution.sh（一次性：证书、公证凭据、GitHub 仓库、重新授权）"
	@echo "  make relaunch       test + app，结束旧实例并打开新 app，核对启动晚于构建"
	@echo "  make displays       当前显示器数（DebugCLI list-spaces）"
	@echo "  make spaces         DebugCLI list-spaces 全量输出"
	@echo "  make debug ARGS=... DebugCLI 透传（list-presets / snapshot-now / restore / simulate-restore / undo / probe ...；ARGS=help 列用法）"
	@echo "  make log            app.log 关键行 tail -$(N)（FILTER=正则 N=行数 覆盖）"
	@echo "  make log-follow     tail -f app.log 并按 FILTER 过滤"
	@echo "  make hooks          启用 .githooks（core.hooksPath）"
	@echo "  make issue NN=12 STATUS=claimed  改票 Status 行（Scripts/issue-status）"

build:
	swift build --package-path "$(ROOT)"

test:
	swift test --package-path "$(ROOT)"

test-tsan:
	swift test --package-path "$(ROOT)" --sanitize=thread

check:
	bash "$(ROOT)/Scripts/check.sh"

# Agent-neutral: explicit UI acceptance, not a pre-commit requirement (real screens needed).
check-ui:
	python3 "$(ROOT)/Scripts/check-ui.py" --app "$(APP)" $(if $(OUT),--out "$(OUT)",)

test-tooling:
	python3 -m unittest discover -s "$(ROOT)/Tests/ToolingTests" -p 'test_*.py'

# Pi agent only; Node/npm is not required for the Swift app or generic checks.
test-pi-guardrails:
	npm test --prefix "$(ROOT)/.pi/extensions/codemode-guardrails"

app:
	bash "$(ROOT)/Scripts/make-app.sh"

dmg:
	RELEASE=1 bash "$(ROOT)/Scripts/make-app.sh"
	bash "$(ROOT)/Scripts/make-dmg.sh"

release:
	bash "$(ROOT)/Scripts/release.sh"

setup-dist:
	bash "$(ROOT)/Scripts/setup-distribution.sh"

relaunch: test
	bash "$(ROOT)/Scripts/make-app.sh"
	pkill -9 -x Winductor 2>/dev/null || true
	sleep 2
	open "$(APP)"
	@sleep 2
	@echo "构建：$$(stat -f %Sm "$(BIN)")"
	@echo "启动：$$(ps -o lstart= -p $$(pgrep -x Winductor))"

displays:
	@cd "$(ROOT)" && swift run -q DebugCLI list-spaces 2>/dev/null | grep -c '^display'

spaces:
	cd "$(ROOT)" && swift run -q DebugCLI list-spaces

debug:
	cd "$(ROOT)" && swift run -q DebugCLI $(ARGS)

log:
	@grep -E "$(FILTER)" "$(LOG)" | tail -$(N)

log-follow:
	tail -f "$(LOG)" | grep --line-buffered -E "$(FILTER)"

hooks:
	git -C "$(ROOT)" config core.hooksPath .githooks

issue:
	@test -n "$(NN)" -a -n "$(STATUS)" || { echo "需要 NN=<票号或路径> STATUS=<状态>"; exit 1; }
	cd "$(ROOT)" && bash Scripts/issue-status "$(NN)" "$(STATUS)"
