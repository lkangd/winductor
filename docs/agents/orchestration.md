# Subagent orchestration

Rules for any flow that orchestrates subagents (implement-spec ticket fan-out, code-review axes, review-fix dispatch). The orchestrator schedules and merges; it does not do hands-on work.

## Orchestrator discipline

Context is the scarce resource. The checkpoint that makes any interruption cheap already exists — one commit per ticket, status in ticket files — so spend turns on scheduling, not on output.

- **Delegate output-heavy verification** (codesign, log dumps, live app runs) to a worker; receive back a short structured report. Never run these yourself.
- **Filter every bash output**: pipe through `grep`/`head`/`tail`; output that must be long goes to a file read with offset/limit.
- Per-ticket results stay in the ticket/report files, not in orchestrator context — read them back only when a decision needs them.

## Invocation contract

- Agents: `worker` (implementation), `reviewer` (fresh-context review), `researcher`/`scout` (exploration). Orchestration flows here need only these — not `general`, not personas.
- One child: `{agent, task, cwd?, async?}`. A `tasks[]` array is invalid without `workflow: "parallel"`.
- Exactly **one subagent call per turn**; batch all parallel children inside that single call.
- Fan out implementers with `async: true`; run reviewers blocking (`async: false`) so findings land in the orchestrator context.
- On an agent/args error, fix the call from this contract — mid-flight guide lookups cost a turn each.
