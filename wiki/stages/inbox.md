---
title: 1-inbox stage
type: stage
source: lib/hive/stages/inbox.rb
created: 2026-04-25
updated: 2026-04-25
tags: [stage, inbox, capture]
---

**TLDR**: `1-inbox/` is an inert capture zone. `hive run` here does *not* spawn an agent; it simply prints guidance to `mv` the task into `2-brainstorm/` first.

## State file

`idea.md` — created by `hive new` from `templates/idea.md.erb`, ends with a trailing `<!-- WAITING -->` marker so `hive status` shows ⏸.

## Behaviour of `hive run`

`Hive::Stages::Inbox.run!` (`lib/hive/stages/inbox.rb:5`) prints to stderr:

```
hive: 1-inbox/ is an inert capture zone. To start work:
  mv <task> <hive-state>/stages/2-brainstorm/
  hive run <new-path>
```

Returns `{commit: nil, status: :inert}` so `Commands::Run` skips the post-run hive commit.

## Why it's special

Other stages are *active* — their `hive run` invokes `claude -p`. `1-inbox/` is deliberately passive: capture should be cheap (`hive new` writes the file and exits) and agent work should only start once the user has explicitly approved by `mv`-ing into `2-brainstorm/`. This is the stage-naming convention noted in the original plan: stage folder = "phase the task is in", with `1-inbox` and `6-done` being the two non-working stages.

## Backlinks

- [[stages/brainstorm]] · [[stages/done]]
- [[commands/new]] · [[commands/run]]
- [[state-model]]
