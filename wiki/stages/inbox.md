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

`Hive::Stages::Inbox.run!` (`lib/hive/stages/inbox.rb:10`) **raises `Hive::WrongStage`** with the suggested `mv` + re-run command in the message. `bin/hive` rescues it and exits with code `4` (`ExitCodes::WRONG_STAGE`) so agent callers can branch on wrong-stage without parsing stderr — see [[cli]] for the full exit-code contract.

The error message format is:

```
1-inbox/ is an inert capture zone. To start work: mv <task> <hive-state>/stages/2-brainstorm/ && hive run <new-path>
```

No commit is produced — the runner never returns a result, the lock is released by `with_task_lock`, and `Commands::Run#commit_after` / `report` are skipped because the raise unwinds before them.

## Why it's special

Other stages are *active* — their `hive run` invokes `claude -p`. `1-inbox/` is deliberately passive: capture should be cheap (`hive new` writes the file and exits) and agent work should only start once the user has explicitly approved by `mv`-ing into `2-brainstorm/`. This is the stage-naming convention noted in the original plan: stage folder = "phase the task is in", with `1-inbox` and `6-done` being the two non-working stages.

## Backlinks

- [[stages/brainstorm]] · [[stages/done]]
- [[commands/new]] · [[commands/run]]
- [[state-model]]
