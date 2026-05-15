# Security Policy

## Supported versions

Hive is in Phase 1 MVP. Only the latest commit on `main` is supported.

## Trust model

Hive runs `claude -p` with `--dangerously-skip-permissions` on the developer's local machine. This is a deliberate **single-developer trust model** — the agent has the same disk access as the user. Multi-user deployments, CI environments, and shared workstations are explicitly out of scope and would require a re-design.

The boundaries Hive does enforce:

1. **Prompt-injection wrapping with a per-process random nonce** — user-supplied content is wrapped in `<user_supplied_<hex16>>…</user_supplied_<hex16>>` with a tag that rotates per process; attacker `</user_supplied>` payloads cannot terminate the wrapper.
2. **Physical isolation via `--add-dir` discipline** — the brainstorm and plan stages restrict the agent's filesystem access to the task folder only. The execute stage adds the feature worktree but never another project.
3. **Post-run integrity checks** — SHA-256 pre/post on `plan.md` and `worktree.yml` around both the implementation and reviewer passes; tampering yields a structured `<!-- ERROR reason=implementer_tampered|reviewer_tampered -->` marker.
4. **PR body secret-scan** — `Stages::OpenPr` (after the agent's `gh pr create`) and `Stages::Finalize` (after the agent's `gh pr edit`, before the runner's `gh pr ready`) both regex-scan the published PR body via `Hive::Gh.scan_pr_for_secrets` for api-key / AWS / GitHub-token / PEM patterns. On a hit, `Stages::Finalize` reverts the ready-flip and redacts the body; `Stages::OpenPr` scrubs + closes the leaked draft. The actual `gh auth status` precondition lives in `Hive::Gh.ensure_authenticated!`.

See [`wiki/decisions.md`](wiki/decisions.md) ADR-008 for the full reasoning.

## Reporting a vulnerability

**Do not open a public issue.** Please email the maintainer directly:

- Ivan Kuznetsov — `ivan@ikuznetsov.com`

Include:
- Hive commit SHA you're testing against
- Steps to reproduce
- The actual vs expected behavior, and the security impact you believe it has

You should receive an acknowledgement within 7 days. If a fix is warranted, expect a follow-up with timeline and disclosure plan within 14 days.

## Out of scope

- The `--dangerously-skip-permissions` decision itself (documented design choice, not a vulnerability).
- Reports against deployments outside the single-developer trust model — multi-user or CI deployments are not supported and not within scope.
- Issues in upstream `claude`, `gh`, or `git` CLIs — please report those to their respective maintainers.
