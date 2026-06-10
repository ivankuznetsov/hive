---
title: hive web
type: command
source: lib/hive/commands/web.rb, lib/hive/web/, hive.gemspec, public/, packaging/docker/
created: 2026-06-04
updated: 2026-06-10
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

`Hive::Commands::Web#call` loads `Hive::Config.load_global_web`, requires Puma,
mounts `Hive::Web::App`, adds one TCP listener, prints the listening URL, and
joins the Puma server thread. It is a foreground server command. Puma runs with
`MAX_THREADS = 32`; the SSE stream cap is `MAX_SSE_STREAMS = 24`, leaving eight
threads for auth/action/diff requests even when dashboards and log tails are
open. A `0.0.0.0` bind without an `https://` `web.origin` emits a startup
warning because Rack::Protection host authorization is disabled for the box and
a trusted reverse proxy or tunnel must validate Host.

## Surface

- `/` renders the live status grid from the same status JSON consumed by
  [[commands/tui]].
- `/events` streams changed status snapshots as named `status` server-sent
  events. All subscribers share one background `StatusFeed` poller, unchanged
  snapshots become keep-alives, and `SseLimiter` returns a plain 503 before the
  response switches to `text/event-stream` when the stream cap is full.
- `/tasks/:project/:slug` shows task artifacts and forms for approve, dispatch,
  and intervention notes.
- `/tasks/:project/:slug/diff` validates the slug, shells out to array-form
  `git -C <worktree> diff --` for the task's configured worktree root, and
  returns 422 instead of rendering stderr as a diff when git fails.
- `/tasks/:project/:slug/logs` validates the slug, tails the newest task log
  under `<hive_state_path>/logs/<slug>/` as named `log` SSE events, releases its
  stream slot on client disconnect or bounded idle timeout, and uses the same
  stream cap as `/events`.
- `POST /tasks/:project/:slug/approve` and `/reject` call
  `Hive::Commands::Approve`; `POST /tasks/:project/:slug/dispatch` writes a
  daemon dispatch request using the same queue writer as [[modules/bot]].
- `POST /tasks/:project/:slug/intervene` writes the operator message into the
  next unanswered slot of `brainstorm.md` via the same
  `Hive::Bot::BrainstormAnswerWriter` path used by Telegram answers; it is only
  valid while the task has a brainstorm file with an unanswered question.
- `POST /ideas` calls `Hive::Commands::New`.
- `/agents` orchestrates Claude/Codex login in a PTY and writes Pi auth JSON.
- `/repos` lists registered projects. `POST /repos` accepts github.com
  HTTPS/SSH URLs or `owner/repo` shorthand, clones through `gh repo clone` into
  `HIVEBOX_REPOS_DIR` (default `/data/repos`) when the target does not exist,
  and otherwise re-runs `hive init` in the existing checkout.
- `POST /repos/:name/delete` unregisters a repo through `Hive::Commands::Forget`.
- `/telegram` validates the bot token with Telegram `getMe` before writing the
  global bot config and `.env` token consumed by [[commands/bot]]. The
  `/telegram/test` POST sends a real test message to configured chats, and a
  successful save SIGHUPs the container supervisor via `HIVEBOX_SUPERVISOR_PID`
  so the bot can start without recreating the container.

## Auth

Every route except `/health`, `/login`, `/logout`, and GitHub OAuth callback
routes is behind the GitHub owner gate. The session secret comes from
`HIVEBOX_SESSION_SECRET` or a generated file under `Hive::Paths.state_home` so
container restarts preserve sessions; cookies are `HttpOnly`, `SameSite=Lax`,
and `Secure` when `web.origin` is HTTPS. POST/PUT/DELETE routes require the
session CSRF token emitted by `csrf_tag`.

GitHub auth is owner-only. `Hive::Web::GithubAuth` builds a GitHub OAuth URL
from `web.origin`, `web.github.client_id`, and a random state; exchanges the
callback code with `HIVEBOX_GITHUB_CLIENT_SECRET`; reads the authenticated login
from `https://api.github.com/user`; and admits only the configured
`web.github.owner` case-insensitively. The callback rejects absent/mismatched
OAuth state, denied-consent callbacks with no code, and non-owner logins, then
renews the session at the auth boundary.

## Agent Auth Relay

The Claude and Codex login flows run the actual provider CLI in a PTY:

| Agent | Command |
|-------|---------|
| Claude | `claude setup-token` |
| Codex | `codex login` |
| Pi | direct JSON write to `~/.pi/agent/auth.json` |

Hivebox captures the first `http(s)://` URL from PTY output, asks the operator to
open the provider URL directly, and writes the pasted code or callback URL back
to the waiting PTY. It does not proxy provider login pages. Login sessions are
bounded by a four-session concurrency cap, a watchdog timeout, and process-group
termination; `complete` waits briefly for success or a clear rejected-code
signal instead of silently redirecting. The design note is
`docs/notes/hivebox-agent-oauth-relay.md`; see [[decisions]] ADR-035.

## Docker

`packaging/docker/` builds the hivebox image from `ruby:3.4-slim`. The image
installs OS tools needed by the box (`git`, `gh`, `tmux`, `nodejs`, `npm`,
`tini`, and build/runtime helpers), copies the repository into `/app`, runs
Bundler without development/test groups, builds the `hive-cli` gem, installs it,
and installs the Claude, Codex, and Pi CLIs globally through npm. The npm
install is fail-closed: a build missing those agent binaries fails instead of
shipping a box whose `/agents` login flows cannot start the expected CLIs.

`hive.gemspec` includes both `lib/hive/web/views/*.erb` and `public/**/*` in
the runtime gem payload. This matters for installed `hive web` and for the
Docker build, which runs from the built gem: the source tree can render views
from `__dir__`, but an installed gem without those ERB templates and CSS/JS
assets would render `/login` and other pages as server errors.

The Docker entrypoint is `/usr/bin/tini -- hivebox-entrypoint`. The entrypoint
ensures `/data/home`, `/data/repos`, `/data/config`, `/data/state`,
`/data/cache`, and `/data/share` exist, executes custom argv when arguments are
passed, and otherwise runs `Hive::Web::Supervisor`. The supervisor starts
`hive daemon start`, `hive web --bind 0.0.0.0`, and `hive bot start
--foreground` when global bot config is enabled. While `run` is active it
publishes `HIVEBOX_SUPERVISOR_PID` so the web child can SIGHUP the supervisor
after enabling Telegram, then restores the caller's prior env value and signal
traps on exit. Crashed daemon/web/bot children restart, fast failures back off,
clean exits and signal deaths do not respawn, and shutdown drains all child
process groups concurrently within the configured daemon grace window before
SIGKILL escalation. The container healthcheck calls `GET /health` on
`127.0.0.1:4567`.

`/data` is the persistence boundary: `HOME`, XDG config/state/cache/data, repos,
Hive state, generated session secret, and agent credential dirs all live there.
`packaging/docker/compose.example.yml` binds `./hivebox-data:/data` and passes
`HIVEBOX_GITHUB_CLIENT_SECRET` plus optional `HIVEBOX_SESSION_SECRET`. The image
serves plain HTTP on port 4567; TLS is expected at a reverse proxy or tunnel.

Backlinks: [[architecture]], [[modules/config]], [[modules/daemon]],
[[modules/bot]].
