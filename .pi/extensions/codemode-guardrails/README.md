# Pi agent only: codemode guardrails

**Scope: Pi's codemode tool and project-local extension API only.** These are not Swift rules and do not apply to Claude Code, Codex or other agent harnesses. The generic UI/review CLI scripts remain usable without Pi, Node or npm.

## Setup

```bash
# Node 22.18+ (for the extension's TypeScript integration tests)
npm ci --prefix .pi/extensions/codemode-guardrails --ignore-scripts
make test-pi-guardrails
```

The trusted project's `.pi/extensions/codemode-guardrails/index.ts` is auto-discovered by Pi. Use `/reload` after installing dependencies or changing the extension; a running agent cannot reload itself mid-turn. Untrusted projects do not load project extensions. This implementation targets the documented Pi 1.5.2 `tool_call`/tool exposure API and uses only project files, not patches to Pi's installation or global settings.

## Pi-only instruction loading

`orchestration.md` beside this extension is the single source for Pi's invocation contract. The extension reads it on load and injects it into Pi's structured prompt section only when `subagent`, `subagents_enable` or `subagent_supervisor` is active. The enable-tool case supplies the contract before the first launch; repeated runs replace the same section rather than duplicating instructions. Without those tools, the section is removed. Codemode's setup pointer is likewise injected only when codemode is active.

Shared `AGENTS.md`, review skills and `docs/agents/orchestration.md` carry no Pi-specific invocation rules or pointers into this directory. Other harnesses do not execute Pi's extension hooks, so they receive neither these prompt additions nor the runtime guards. This is automatic-loading isolation, not filesystem access control: an agent deliberately reading `.pi/` can still see the files.

## Enforced behavior

Explicit synchronous `subagent` launches (`async: false`, without a management action) are blocked before dispatch to keep supervisor replies possible. Use `async: true`; management/status calls are unaffected. Other harnesses' scheduling APIs are not intercepted.

At a `codemode` tool call, before the script executes:

1. Parse JavaScript with pinned Acorn. Inspect literal `tools.name`, `tools["name"]` and object destructuring from `tools` against Pi's live tool catalog and active set. Reject missing/inactive/hidden or model-only references before any nested read/write starts. Deferred/codemode-exposed tools remain callable without direct model activation. Tool calls appearing only in comments or strings do not trigger a block.
2. Inject an output boundary into the QuickJS script. Typed image objects passed to `text()`, console methods or a top-level return are emitted through `image()`; nested image objects are replaced in text with small descriptors. Binary/base64 data stays out of text output. Explicit `image(block)` and ordinary text/structured results retain their behavior; the first-line codemode options are preserved.

Call model-only enable/orchestration/supervisor tools directly from the model. Discover other tools first, then use their literal codemode identifiers. Prefer `image(await tools.read({path: "screenshot.png"}))` explicitly even though the guard repairs typed-image output.

## Boundaries

This is an accident-prevention hook, **not a security sandbox**. Static preflight does not resolve arbitrary aliases or dynamically computed property names, nor prove argument validity; Pi still validates each actual nested call. Strings already containing serialized base64 cannot reliably be distinguished from ordinary text. Avoid deliberately bypassing the typed output boundary with custom serialization or custom globals.

The extension intercepts only Pi `codemode` and the explicit synchronous `subagent` launch shape above; it does not change permissions, authorize delegation, or replace Pi's tool implementation. It needs the host's mutable `tool_call.input.code` and `getAllTools()` exposure metadata. Load errors are not successful protection: check Pi's extension diagnostics after reload. Regression tests exercise parsing and output behavior; a native codemode smoke test can be run with `PI_CODEMODE_EXECUTOR` set to the host's `dist/extensions/codemode/execute.js` path.

Node/npm tests are separate (`make test-pi-guardrails`), not silently skipped inside the generic Swift pre-commit check. The extension package and lockfile are versioned; its `node_modules` is ignored.
