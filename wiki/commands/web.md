---
title: hive web
type: command
source: lib/hive/commands/web.rb, lib/hive/web/
created: 2026-06-04
updated: 2026-06-04
tags: [command, web, hivebox]
---

**TLDR**: `hive web` starts the hivebox Sinatra/Puma web UI. The UI is an
authenticated browser surface over existing Hive primitives: status reads call
`Hive::Commands::Status#json_payload`, workflow dispatch writes daemon queue
requests, and gate approval calls `Hive::Commands::Approve`.

## Surface

- `/` renders the live status grid from the same status JSON consumed by
  [[commands/tui]].
- `/tasks/:project/:slug` shows task artifacts and forms for approve, dispatch,
  and intervention notes.
- `/agents` orchestrates Claude/Codex login in a PTY and writes Pi auth JSON.
- `/repos` clones repos into the box and runs `hive init`.
- `/telegram` writes the global bot config and `.env` token consumed by
  [[commands/bot]].

## Auth

Every route except `/health`, `/login`, and GitHub OAuth callback routes is
behind the GitHub owner gate. The session secret comes from
`HIVEBOX_SESSION_SECRET` or a generated file under `Hive::Paths.state_home` so
container restarts preserve sessions.

## Docker

`packaging/docker/` builds the hivebox image. `/data` is the persistence boundary:
`HOME`, XDG config/state/cache/data, repos, Hive state, and agent credential dirs
all live there.

Backlinks: [[architecture]], [[modules/config]], [[modules/daemon]],
[[modules/bot]].
