## Agent skills

### Issue tracker

Issues live as local markdown files under `.scratch/<feature>/` in this repo. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`), recorded as `Status:` lines in issue files. See `docs/agents/triage-labels.md`.

### Subagent orchestration

When orchestrating subagents (implement-spec fan-out, code-review axes, review-fix dispatch): discipline and invocation contract in `docs/agents/orchestration.md`.

### Domain docs

Single-context layout: one root `GLOSSARY.md` plus `docs/adr/`. See `docs/agents/domain.md`.
