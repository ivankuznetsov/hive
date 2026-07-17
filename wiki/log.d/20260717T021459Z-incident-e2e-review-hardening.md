---
title: Harden incident e2e isolation and activate landed dependency contracts
date: 2026-07-17
tags: [e2e, incidents, dependencies, hermetic, review]
---

- Activated the #9771 plan-only dependency-gate and cross-project repository-identity incidents against their merged fail-closed reason codes; four sibling-gated fixtures remain pending.
- Made GitHub evidence append-only and lock-verified after background and tmux/TUI producers stop, pinned both PATH and `HIVE_GH_BIN`, inferred cwd-origin repository identity, and rejected replacement scripts.
- Protected run-local home/bundle, all built-in fake-agent binaries, and checkout binaries from scenario overrides so routine e2e cannot reach operator state or consume a real agent subscription.
- Moved nested `script_gh` validation to scenario preflight, rejected untagged incident metadata and duplicate scenario names, exposed lifecycle fields in inventory output, and included sandbox bootstrap in incident duration budgets.
- Kept generated repros hermetic, headless for secondary projects, and fail-closed on unconsumed GitHub interactions after replay producers stop.
- Kept the incident run directory in the runner temp area while scoping the `runner.temp` expression to workflow steps, where GitHub Actions permits that context, so the required CI workflow parses and starts.
