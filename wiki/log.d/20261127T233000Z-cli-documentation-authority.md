---
title: Make docs/cli.md the single authoritative public CLI reference
created: 2026-11-27T23:30:00Z
tags: [wiki, cli, documentation, authority, commands]
---

- Established `docs/cli.md` as the sole authoritative public CLI reference for
  every visible `bin/hive` command, selector leaf, alias, option, behavioral
  mode, JSON/JSON-Lines/text framing contract, remote-context posture, side
  effect, and exit code, backed by bidirectional drift checks in
  `test/unit/docs_cli_authority_test.rb`.
- Demoted `README.md`, `CONTRIBUTING.md`, [[cli]], [[commands]], all live
  `wiki/commands/*.md` pages (including [[commands/stage_action]]),
  [[modules/worktree]], and [[modules/plan_review]] from competing public CLI
  contracts to orientation and internal controller/storage/architecture
  documentation with relative authority links to `docs/cli.md`.
- Removed stale daemon/web and two-command JSON claims from `CONTRIBUTING.md`
  and reconciled the stale `hive new` prose-only note in `README.md`.
- Preserved historical [[commands/migrate]] with its migration-guide pointer
  and kept `wiki/commands/workflow.md`'s [[modules/workflow_package]] ownership
  link intact.
- Transferred the five former Wiki semantic preservation assertions (web
  status/install schemas, daemon v1 schemas and exit matrix, version exit
  codes, metrics/status/act serialization policies, and refactor-patrol job
  pagination) onto their owning records in `docs/cli.md` and updated
  `WikiCommandIndex::Guard` to check architecture navigation and resolvable
  authority links.
