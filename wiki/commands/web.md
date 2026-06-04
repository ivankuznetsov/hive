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
requests, gate approval calls `Hive::Commands::Approve`, and setup flows write
the same global config and credential files used by the CLI, daemon, bot, and
agent profiles.

## CLI

`lib/hive/cli.rb` registers `hive web` with two options:

| Option | Effect |
|--------|--------|
| `--bind` | Overrides `web.bind` for this server run. |
| `--port` | Overrides `web.port` for this server run. |

`Hive::Commands::Web#call` loads `Hive::Config.load_global_web`, requires Puma
and Rackup, mounts `Hive::Web::App`, adds one TCP listener, prints the listening
URL, and joins the Puma server thread. It is a foreground server command.

## Surface

- `/` renders the live status grid from the same status JSON consumed by
  [[commands/tui]].
- `/events` streams changed status snapshots as server-sent events.
- `/tasks/:project/:slug` shows task artifacts and forms for approve, dispatch,
  and intervention notes.
- `/tasks/:project/:slug/diff` shells out to array-form `git -C <worktree> diff
  --` for the task's configured worktree root.
- `/tasks/:project/:slug/logs` streams the newest task log under
  `<hive_state_path>/logs/<slug>/`.
- `POST /tasks/:project/:slug/approve` and `/reject` call
  `Hive::Commands::Approve`; `POST /tasks/:project/:slug/dispatch` writes a
  daemon dispatch request using the same queue writer as [[modules/bot]].
- `POST /tasks/:project/:slug/intervene` appends an operator note to
  `web-interventions.md` in the task folder.
- `POST /ideas` calls `Hive::Commands::New`.
- `/agents` orchestrates Claude/Codex login in a PTY and writes Pi auth JSON.
- `/repos` clones repos into the box and runs `hive init`.
- `POST /repos/:name/delete` unregisters a repo through `Hive::Commands::Forget`.
- `/telegram` writes the global bot config and `.env` token consumed by
  [[commands/bot]].

## Auth

Every route except `/health`, `/login`, and GitHub OAuth callback routes is
behind the GitHub owner gate. The session secret comes from
`HIVEBOX_SESSION_SECRET` or a generated file under `Hive::Paths.state_home` so
container restarts preserve sessions. POST/PUT/DELETE routes require the
session CSRF token emitted by `csrf_tag`.

GitHub auth is owner-only. `Hive::Web::GithubAuth` builds a GitHub OAuth URL
from `web.origin`, `web.github.client_id`, and a random state; exchanges the
callback code with `HIVEBOX_GITHUB_CLIENT_SECRET`; reads the authenticated login
from `https://api.github.com/user`; and admits only the configured
`web.github.owner` case-insensitively.

## Agent Auth Relay

The Claude and Codex login flows run the actual provider CLI in a PTY:

| Agent | Command |
|-------|---------|
| Claude | `claude setup-token` |
| Codex | `codex login` |
| Pi | direct JSON write to `~/.pi/agent/auth.json` |

Hivebox captures the first `http(s)://` URL from PTY output, asks the operator to
open the provider URL directly, and writes the pasted code or callback URL back
to the waiting PTY. It does not proxy provider login pages. The design note is
`docs/notes/hivebox-agent-oauth-relay.md`; see [[decisions]] ADR-035.

## Docker

`packaging/docker/` builds the hivebox image. The entrypoint runs
`Hive::Web::Supervisor`, which starts `hive daemon start`, `hive web --bind
0.0.0.0`, and `hive bot start --foreground` when global bot config is enabled.
`/data` is the persistence boundary: `HOME`, XDG config/state/cache/data, repos,
Hive state, and agent credential dirs all live there. The image serves plain HTTP
on port 4567; TLS is expected at a reverse proxy or tunnel.

Backlinks: [[architecture]], [[modules/config]], [[modules/daemon]],
[[modules/bot]].
