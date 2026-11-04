ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
APP := $(ROOT)/build/WindowLayoutRestorer.app
BIN := $(APP)/Contents/MacOS/WindowLayoutRestorer
LOG := $(HOME)/Library/Application Support/WindowLayoutRestorer/logs/app.log
# 实测常用的 app.log 关键行（make log FILTER=... 覆盖）
FILTER ?= aftershock|debounce-extend|deferred-consume|deferred wid|give-up|structure-changed|topology-changed-while|perf|done ok
N ?= 50
# 重启前期望的显示器数（少屏时重启会让冻结点按少屏启动重建；FORCE=1 跳过）
DISPLAYS ?= 3

.PHONY: help build test test-tsan check app relaunch displays spaces debug log log-follow hooks issue

help:
	@echo "Targets:"
	@echo "  make build          swift build"
	@echo "  make test           swift test"
	@echo "  make test-tsan      swift test --sanitize=thread（并发改动必跑）"
	@echo "  make check          Scripts/check.sh（pre-commit 同款门禁）"
	@echo "  make app            Scripts/make-app.sh（release 构建 + 组装 + 签名；留意钥匙串授权弹窗）"
	@echo "  make relaunch       test + app，确认 $(DISPLAYS) 屏后结束旧实例并打开新 app，核对启动晚于构建（FORCE=1 跳过屏数检查）"
	@echo "  make displays       当前显示器数（DebugCLI list-spaces）"
	@echo "  make spaces         DebugCLI list-spaces 全量输出"
	@echo "  make debug ARGS=... DebugCLI 透传（snapshot-now / restore / simulate-restore / undo / probe ...）"
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

app:
	bash "$(ROOT)/Scripts/make-app.sh"

relaunch: test
	@n=$$(cd "$(ROOT)" && swift run -q DebugCLI list-spaces 2>/dev/null | grep -c '^display'); \
	if [ "$$n" != "$(DISPLAYS)" ] && [ -z "$(FORCE)" ]; then \
		echo "当前 $$n 屏，期望 $(DISPLAYS) 屏；确认无误用 FORCE=1 make relaunch"; exit 1; \
	fi
	bash "$(ROOT)/Scripts/make-app.sh"
	pkill -9 -x WindowLayoutRestorer 2>/dev/null || true
	sleep 2
	open "$(APP)"
	@sleep 2
	@echo "构建：$$(stat -f %Sm "$(BIN)")"
	@echo "启动：$$(ps -o lstart= -p $$(pgrep -x WindowLayoutRestorer))"

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
