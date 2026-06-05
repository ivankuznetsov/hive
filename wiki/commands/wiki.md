---
title: hive wiki
type: command
source: lib/hive/commands/wiki.rb, lib/hive/wiki_log.rb
created: 2026-06-05
updated: 2026-06-05
tags: [command, wiki, changelog, generated]
---

**TLDR**: `hive wiki compile-log [PROJECT_PATH]` rebuilds `wiki/log.md`
from per-change fragments under `wiki/log.d/*.md` plus the preserved
legacy changelog body. Agents should add a uniquely named fragment
instead of editing `wiki/log.md` directly; the compiler is for
post-merge refreshes or local aggregate checks, not ordinary feature PR
diffs.

## Fragment Flow

Each wiki refresh writes a new Markdown fragment:

```text
wiki/log.d/20260605-220000-short-topic.md
```

The fragment body is a normal changelog entry starting with `## [...]`.
`Hive::WikiLog` reads non-empty `*.md` fragments sorted by filename
descending, wraps the generated section in explicit markers inside
`wiki/log.md`, and leaves any pre-fragment legacy entries below that
section. Re-running the compiler is idempotent and does not duplicate
entries already inside the generated block.

## Commands

| Command | Behavior |
|---------|----------|
| `hive wiki compile-log` | Regenerate `wiki/log.md` in the current project. |
| `hive wiki compile-log PATH` | Regenerate another checkout's changelog. |
| `hive wiki compile-log --check` | Exit non-zero if `wiki/log.md` is stale. |

The command exits with `Hive::InvalidTaskPath` / EX_USAGE when the
project has no `wiki/` directory or when `--check` finds stale output.

## Concurrency Rationale

`wiki/log.md` used to be the single append-only changelog file every PR
touched, so concurrent Hive PRs routinely conflicted at the tail even
when the actual source and wiki page edits were independent. Fragments
turn that hot append point into many independent files; the generated
aggregate can be refreshed after rebasing or after merge.
