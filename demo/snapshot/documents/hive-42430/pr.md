---
pr_url: https://github.com/ivankuznetsov/hive/pull/1015
pr_number: 1015
head_oid: 8c590ed9a001d988b331f2c1d90a9124688983b8
---

## Summary

- Turn each Hive task detail page into one bounded, read-only operator workspace, driven by the same `hive-task-workspace.v1` snapshot for authenticated HTML and JSON.
- Make operational evidence trustworthy: preserve forward-only provenance, one canonical current attempt with distinct sessions and typed resources, a deterministic audit timeline, the bounded dependency component, and isolated artifact and publication views. Missing, stale, partial, or conflicting facts remain explicit.
- Preserve Hive's authority boundaries and existing workflows. `hive-status.v7`, task actions, questions, logs, media, and archive behavior remain compatible; remote publication reads require an explicit authorized refresh, while the responsive workspace and long-form Markdown remain accessible on desktop and narrow screens.

## Test plan

Full workspace validation:

- [x] `bundle exec rake test` — 12,838 runs, 161,332 assertions
- [x] Complete Rails suite — 288 runs, 1,578 assertions
- [x] Browser suite — 59 runs, 573 assertions
- [x] Schema/status compatibility checks — 267 runs, 1,514 assertions
- [x] Exact-HEAD focused proof and golden E2E — 64 runs, 310 assertions
- [x] Brakeman, Bundler Audit, and Wiki compilation checks

Final Markdown presentation follow-up at `8c590ed9a`:

- [x] Task workspace browser suite — 61 runs, 614 assertions
- [x] Markdown sanitizer integration — 1 run, 19 assertions
- [x] RuboCop on the changed browser test — no offenses
- [x] `git diff --check`
- [ ] Hosted GitHub merge gates — running on exact head `8c590ed9a001d988b331f2c1d90a9124688983b8` at finalization

## Review summary

- Two structured Codex review/fix passes resolved all 45 findings: 35 high, 9 medium, and 1 nit. No escalations or active suppressions remain.
- The fixes hardened receipt validation and custody, bounded projection checkpoints, fail-closed action evidence, lossless timeline pagination, dependency and publication deadlines, archive mutation guards, and accessible Turbo interaction state.
- The Claude Opus reviewer could not run in either pass because its session quota was exhausted. This is a reviewer-infrastructure limitation, not a product-test failure.
- Provider and GitHub behavior was verified with bounded injected transports; live provider and live GitHub test calls were intentionally excluded.

## Linked task

- Hive task: `hive:improve-hive-web-task-detail-260812-19e1`
- Approved plan: `Improve Hive Web Task Detail Workspace`















<!-- COMPLETE pr_url=https://github.com/ivankuznetsov/hive/pull/1015 is_draft=false -->
