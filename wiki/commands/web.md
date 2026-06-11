---
title: hive web
type: command
source: lib/hive/commands/web.rb, lib/hive/web/, web/, packaging/docker/
created: 2026-06-04
updated: 2026-06-11
tags: [command, web, hivebox, rails, turbo]
---

**TLDR**: `hive web` boots the hivebox web UI — a vanilla **Rails 8** app
(importmap, Turbo, Stimulus, propshaft, solid_cable) living in `web/` at the
repo root, shipped in the Docker image at `/app/web`. The web tier adds no
pipeline logic: status reads call `Hive::Commands::Status#json_payload` (via
`Hive::Web::StatusFeed`), gate approval calls `Hive::Commands::Approve`
in-process, task Drop calls `Hive::Commands::Drop` in-process, stage runs go
through the daemon dispatch queue (`Hive::Web::Dispatcher`), and setup flows
reuse `Hive::Web::GithubAuth`, `AgentsAuth`, and the Telegram validators from
the gem.

## CLI

`hive web [--bind] [--port]` (defaults from the `web:` config block). The
command locates the Rails app (`HIVEBOX_WEB_APP_DIR` override, else `web/`
next to `lib/`), exports `SECRET_KEY_BASE` (derived from the same persisted
`Hive::Web::SessionSecret` file as before — sessions survive container
recreation), `HIVEBOX_ORIGIN` (Action Cable origin check), and
`HIVEBOX_STORAGE_DIR` (the solid-stack sqlite files, under
`Hive::Paths.state_home/web-storage` so they live on the `/data` mount), runs
`bin/rails db:prepare`, then execs `bin/rails server`. Outside the container
or a source checkout the command exits 1 with guidance — the gem itself does
not package the Rails app (`test/unit/gemspec_test.rb` pins that).

## Auth

GitHub **device flow** (RFC 8628, see [[decisions]] ADR-036), owner-only.
`POST /auth/github` starts the flow with scope `repo`; the wait page polls at
GitHub's interval (one poll per render, `slow_down`-aware). On grant the app
keeps the login AND the token in the encrypted Rails session — the token
powers the Repos page's listing of the operator's GitHub repositories and
authenticates `gh repo clone` (passed as `GH_TOKEN`, never persisted).
Non-owner logins, denied grants, and expired codes render 403 pages. A
dev/test-only `/dev_login` seam (route drawn only when `Rails.env.local?`,
double-checked in the action) is how Capybara signs in without driving real
GitHub.

## Surfaces

- **Status grid (`/`)** — a TUI-left-pane-parity project rail filters the
  grid client-side ("All projects" + one button per registered project;
  buttons not links so the permanent composer's typed text survives; choice
  mirrored to `?project=` via replaceState; a MutationObserver re-applies
  the filter after every broadcast replace/morph), composer (new idea with
  image attach: clipboard
  paste AND upload button; images become `[imageN]` placeholders and land in
  the task's `assets/` dir — `Commands::New`'s TUI contract), per-project
  task rows with stage badges and liveness dots. Live-updates over **Turbo
  Streams**: `StatusBroadcaster` subscribes to `StatusFeed#each_snapshot`,
  strips volatile fields (`generated_at`, `age_seconds`), broadcasts a replace
  of the `projects` frame over solid_cable, and also sends a page refresh for
  subscribers that do not have that frame. The index opts that refresh into
  Turbo morphing with scroll preservation so a live row arrival does not yank
  the operator back to the top; the composer form is `data-turbo-permanent`
  because typed-but-unsent idea text and staged image chips live in browser
  state. No polling JS, no SSE.
- **Task page** — state-driven actions (Approve only when the marker makes
  a forward move possible; Run <verb> only when the project daemon is
  disabled; Diff only when the worktree exists; Reject, Force approve, and
  Drop — the TUI Shift+X parity hard delete via `Commands::Drop`, no undo — as
  described cards in a bottom Advanced section, confirm-gated), per-question
  brainstorm Q&A (the original idea shown above the form; answers go through
  BrainstormAnswerWriter), artifacts rendered as sanitized markdown
  (redcarpet, GFM tables/fenced code; raw HTML escaped at render AND
  sanitized after; leading YAML front matter and HTML comments — i.e. stage
  markers — dropped, GitHub-style). Artifact summaries are UI chrome:
  filename-style tabs in muted monospace, while rendered markdown bodies sit
  in a bordered document panel so the file label and document headings do not
  visually compete. Open/closed choices survive pushed morphs (a Stimulus
  controller snapshots/restores them around the morph while content stays
  live) and artifact order is
  stage-aware — chronological (idea first) while working, artifact.md first
  and open from 8-finalize/9-done — and, as the page's appendix after the
  artifacts, a log tail in a turbo-permanent turbo-frame
  whose own reloads use Turbo frame morphing, patching the live pane in place
  instead of replacing it on every poll. The poll controller gives the pane
  `tail -f` semantics: it pins to the bottom while following, pauses reloads
  while the operator scrolls up to read, and resumes when scrolled back down.
- **Repos** — registered projects, clone-by-URL (same allowlist as before:
  github.com https/ssh or `owner/repo`, leading-dash guard), and the
  operator's GitHub repository list (device-flow token; degrades to an inline
  notice when GitHub is unreachable or the grant was revoked). Every
  registration runs a post-clone/post-existing-dir origin normalization pass:
  absent or non-GitHub remotes are left alone, while GitHub SSH remotes
  (`git@github.com:owner/repo.git` or `ssh://git@github.com/owner/repo.git`)
  become `https://github.com/owner/repo.git`. The box can only push with
  token-fed https credentials (`gh` clones over ssh when the operator's
  `git_protocol` prefers it, and ssh pushes dead-end because the container has
  no keys and no agent for a headless daemon). The Docker image wires git's
  github.com https credential helper to `gh auth git-credential`.
- **Agents** — PTY login relay (ADR-035) with a polled turbo-frame instead of
  meta-refresh; pi token form.
- **Telegram** — getMe-validated token save, allowlist, supervisor SIGHUP,
  round-trip test message.

Task Drop is routed as `POST /tasks/:project/:slug/drop` →
`TasksController#drop` → `Hive::Web::Dispatcher#drop` →
`Hive::Commands::Drop`. It is intentionally in-process, not a daemon dispatch:
the task is gone after success, so the controller redirects to the grid. The
form posts the row's rendered `stage` as `from`; if the task moved after the
page rendered, `Commands::Drop` raises `Hive::WrongStage`, Rails renders the
typed 422 error page, and the moved task folder is left intact.

Typed `Hive::Error`s render a readable error page (422; `InvalidTaskPath` →
404) — never a blank 500. CSRF is Rails-default (per-form tokens); every
route except `/health`, `/up`, `/login`, `/logout`, `/auth/github*`, and the
dev/test-only `/dev_login` is behind the owner gate.

## Tests

`web/test/integration/` drives the real GithubAuth through the device-flow
routes via the `http:` DI seam (no API stubbing), and the real
`Commands::New`/`Approve`/`Drop` against a sandboxed `HIVE_HOME` (the suite
NEVER touches the developer's real config — `test_helper.rb` sets the sandbox
before the app loads). `web/test/system/` runs Capybara +
**capybara-playwright-driver**: login gate, composer image attach (upload
button for real; clipboard paste via a synthetic DataTransfer event — the
sanctioned JS exception), Turbo Stream live row arrival without reload, grid
project-rail filtering with URL sync and re-application after a live broadcast,
grid scroll plus composer draft preservation across a live broadcast, both
approve paths (typed refusal page + confirmed force), log-tail
follow/pause/resume with node-preserving frame morph reloads, and artifact
open-state preservation across pushed morphs with live content refresh. CI runs
both in the `web` job (`.github/workflows/ci.yml`) plus the web app's own
rubocop.

## Docker

`packaging/docker/Dockerfile`: agent CLIs install in an early cached layer;
the gem builds/installs from `/app`; the Rails app bundles and precompiles
assets (propshaft — no node build) at `/app/web` with a dummy build-time
secret. The image sets git's system credential helper for `https://github.com`
to `gh auth git-credential`, so the Agents-page `gh` login also supplies push
credentials for repos under `/data/repos`. The supervisor still spawns
`hive web --bind 0.0.0.0` — unchanged
interface, now exec-ing Rails. The healthcheck hits the Rails `/health`.
`/data` remains the persistence boundary; the sqlite files for
cable/cache/queue live under `/data/state/hive/web-storage`.

Backlinks: [[architecture]], [[modules/config]], [[modules/daemon]],
[[modules/bot]], [[decisions]].
