# Pi agent only: pi-subagents invocation

Injected by this project's Pi extension only when subagent tooling is active. The agent-neutral evidence/coordination workflow remains in `docs/agents/orchestration.md`. These API shapes are not instructions for other harnesses.

- Roles: `worker` for implementation/verification, `reviewer` for fresh-context review, `researcher`/`scout` for exploration. Check their actual resolved tools before dispatch.
- One child: `{agent, task, cwd, async: true}`. Independent children: `{workflow: "parallel", async: true, args: {tasks: [...]}}`.
- Use `async: true` for supervised review as well as implementation. Native completion wakes the parent; do independent work or yield, then answer supervisor requests and read the final report. No polling loop is needed. The project extension blocks explicit synchronous launches (`async: false`).
- Batch parallel children into one subagent call per turn. Isolate concurrent writers by cwd/worktree.
- `subagent` and its enable/supervisor tools are model-only: call them directly, outside codemode. Setup and tool/image guard details are in `.pi/extensions/codemode-guardrails/README.md`.
- On launch/tool-setup failure, stop the lane, report the exact failure and preserve run/worktree state. Correct the invocation or supply artifacts before retrying; changing to another coding-agent CLI needs user approval.
