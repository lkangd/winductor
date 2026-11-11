# Subagent orchestration

Applies to implementation fan-out, code review and review-fix dispatch. Delegate only when the current request or applicable instructions authorize it.

## Evidence before dispatch (all agents)

The orchestrator schedules and merges. Output-heavy verification belongs to a worker; full logs stay in artifacts, with short results returned to the parent.

Before a fixed-range review, prepare immutable, readable evidence:

```bash
python3 Scripts/prepare-review.py BASE --head HEAD \
  --spec .scratch/FEATURE/spec.md --context AGENTS.md \
  --out build/reviews/FEATURE-RUN
python3 Scripts/prepare-review.py --check build/reviews/FEATURE-RUN
```

Use `--no-spec` only when there is no spec. `--context` is repeatable for local issues or handoffs. The artifact contains pinned base/head/merge-base, range.diff, commits.txt, a committed-head snapshot and checksums. Local context is explicitly separate from committed source. Work-in-progress changes are not included; use a checkpoint commit or a separately labelled WIP diff instead of treating an empty range as a completed review.

Before launch, check the **resolved child tools**, not the parent's tools:

- A read-only reviewer needs file reading and access to the evidence directory; it does not need Git, shell or add-directory tools when all material is supplied there.
- A verification worker needs the requested shell/test tools and access to every required directory. Supply authorization and accessible material before launch.
- Put the evidence path, pinned refs, spec path (or no-spec), edit boundary and expected verdict in the brief. The child first reads manifest.json and confirms required files are readable. Missing evidence blocks the review; it is not a code defect or a passing verdict.
- Re-run `--check` before accepting results. A hash check detects changed/missing material; it does not grant permissions or prove the child read every file.

## Coordination (all agents)

Use a background/non-blocking launch whenever a child may ask its supervisor for a decision or missing material. The parent must remain able to answer. A synchronous child is suitable only for a self-contained task that cannot require parent interaction.

Each implementation ticket ends with a checkpoint and ticket status. Keep detailed per-ticket results in artifacts; read them back only when a decision requires them. Bound shell output and retain complete logs by path.
