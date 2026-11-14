---
date: 2026-11-14
type: feature
---

Patrol Fix no longer parks a fix forever when publication's secret scan flags it.

- Validate runs `GithubPublication.commit_secret_findings`, the seam publication's `ensure_secret_free!` now uses, on the fix's commit range before any validation command. It uses the same scan base, HEAD, Betterleaks binary and config, operator ignore file, and `SecretRework.base_branch` scoping, which Publish also uses. A finding appends a validate-stage `decision` (`code: secret_detected`) with only path/line/rule findings and fixed feedback: no credential-like literals, reuse the project's test constants or a scanner-safe construction, rewrite every commit since Base, and no suppressions.
- While the shared `patrol.max_rework_cycles` budget (`PatrolFix::ReworkBudget`, now also used by review) remains, the decision routes to `2-fix` as a new generation through `Transition#apply_secret_rework!`. After that it parks in `3-validate` as `publication_blocked`, owned by the operator.
- New operator-attested action `workflow.secret_rework`: `hive act workflow.secret_rework PROJECT:SLUG --observation TOKEN --confirm`. Operational status advertises it in a new task `secret_rework` field next to `closure`. It releases only a current validate gate or a Publish `secret_detected` block that covers `diff`, runs only locally, and replays an applied token as `already_reworked`.
- Fix renders secret decisions as `secret_scan_feedback`, and treats a secret rework as progress only when HEAD changes.
- Schemas: `hive-patrol-fix-receipt.v1` (validate/publish secret decisions, gated reopens), `hive-patrol-fix-projection.v1`, `hive-operational-status.v5` (`secret_rework`), and `hive-act.v2` (`workflow.secret_rework`, `result.secret_rework`).
