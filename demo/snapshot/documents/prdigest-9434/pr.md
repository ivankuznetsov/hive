---
pr_url: https://github.com/ivankuznetsov/prdigest/pull/1
pr_number: 1
---

## Summary

PRDigest can now run as a deterministic daily oneshot for one VPS operator: it fetches merged pull requests from an ordered repository list, renders safe Telegram HTML, and delivers only to the configured allowlisted chat.

- Scheduled runs resolve local calendar days through IANA timezone rules, durably cap and audit catch-up work, process retained days oldest-first, and checkpoint only settled days.
- Explicit-date replay bypasses state, while dry-run bypasses both state and Telegram. Every path uses a stable redacted result envelope and documented exit codes.
- GitHub pagination, boundary validation, optional line statistics, Telegram retries, flood waits, chunk pacing, and state writes fail closed instead of silently publishing partial data.
- The prepared v0.1.0 gem, non-root Alpine image, and hardened systemd units are documented for operation and rollback. This PR does not tag, publish, or create a release.

## Test plan

- `bundle exec rake test` — passed with 69 runs, 349 assertions, 0 failures, and 0 errors; unstubbed network access is disabled.
- CLI help, version output, and a fixture-backed explicit-date dry run — passed without external network access.
- `test/smoke/gem_install.sh` — passed clean gem build/install and fixture-backed dry-run coverage.
- `test/smoke/docker.sh` — passed non-root execution, timezone data, and application-owned state-volume coverage.
- `test/smoke/systemd.sh` — passed static verification of the supplied service and timer.
- Operator-controlled authenticated GitHub validation, allowlisted Telegram delivery, a clean Ubuntu walkthrough, and remaining independent sign-off are still required before v0.1.0 is release-ready.

## Review summary

Two structured Codex review/fix passes completed. All auto-fix findings were closed, including bounded GitHub retries and pagination, post-rename state semantics, credential-safe object inspection, Thor command/help compatibility, complete partial-progress reporting, Telegram pacing and transport defenses, retry-from-first-chunk coverage, and exclusion of operator data from container layers.

The remaining escalation is evidence-only and requires operator-controlled external access: the live GitHub and Telegram checks, clean Ubuntu walkthrough, and remaining independent validation. The package therefore remains unpublished and not release-ready; no tag or GitHub release was created.

## Linked task

- [Hive task branch: `implement-prdigest-v0-1-0-260715-fe8f`](https://github.com/ivankuznetsov/prdigest/tree/implement-prdigest-v0-1-0-260715-fe8f)

<!-- COMPLETE pr_url=https://github.com/ivankuznetsov/prdigest/pull/1 is_draft=false -->
