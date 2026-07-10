---
title: hive web
type: command
source: lib/hive/commands/web.rb, lib/hive/web/, web/, packaging/docker/, .github/workflows/release.yml
created: 2026-06-04
updated: 2026-06-30
tags: [command, web, hivebox, rails, turbo]
---

**TLDR**: `hive web` boots the hivebox web UI — a vanilla **Rails 8** app
(importmap, Turbo, Stimulus, propshaft, solid_cable) living in `web/` at the
repo root, shipped in the Docker image at `/app/web`. The web tier adds no
pipeline logic: status reads call `Hive::Commands::Status#json_payload` (via
`Hive::Web::StatusFeed`), gate approval calls `Hive::Commands::Approve`
in-process, task Drop calls `Hive::Commands::Drop` in-process, stage runs go
through the daemon dispatch queue (`Hive::Web::Dispatcher`), daemon status
renders the shared `Hive::Daemon::StatusReport.safe_payload` producer used by
`hive daemon status --json`, and setup flows
reuse `Hive::Web::GithubAuth`, `AgentsAuth`, and the Telegram validators from
the gem. Red task recovery uses the bot's `RecoverySequence` path so the web
Retry button and Telegram Autofix share the same guarded clear plus rerun
contract; the TUI's Recover has its own subprocess-based clear + `hive run`
path with separate gates.

## CLI

`hive web [--bind] [--port]` (defaults from the `web:` config block). The
command locates the Rails app in this order: `HIVEBOX_WEB_APP_DIR` when it
points at a real Rails app, the managed version-stamped app under
`Hive::Paths.web_app_home` (refreshed when stale unless `--no-bootstrap` is
passed), then a source checkout `web/` next to `lib/`; if none exists and
bootstrap is allowed, it downloads/extracts the versioned web release bundle.
Relative `HIVEBOX_WEB_APP_DIR` values are accepted but normalized before the
Rails env is built, so `BUNDLE_GEMFILE` points at the real app Gemfile after
the command changes into the app directory.
It exports `SECRET_KEY_BASE` (derived from the same persisted
`Hive::Web::SessionSecret` file as before — sessions survive container
recreation), `HIVEBOX_ORIGIN` (extra Action Cable origin allow; same-origin
host traffic is accepted without config), and
`HIVEBOX_STORAGE_DIR` (the solid-stack sqlite files, under
`Hive::Paths.state_home/web-storage` so they live on the `/data` mount), runs
`bin/rails db:prepare`, then execs `bin/rails server`. Outside the container,
a source checkout, or a bootstrapped managed bundle the command exits 1 with
guidance — the gem itself does not package the Rails app
(`test/unit/gemspec_test.rb` pins that).

`hive web install [--force] [--json]` installs the separate `hive-web` autostart
service using the invoked user-facing binary path; `hive web start --detach`
starts that service and reloads systemd-user first on Linux so a unit written
while systemd-user was unavailable becomes visible. Foreground
`hive web start` is equivalent to `hive web`. `status --json` emits
`hive-web-status`; `install --json` emits `hive-web-install`.

## Auth

GitHub **device flow** (RFC 8628, see [[decisions]] ADR-036), owner-only.
An ownerless box is CLAIMABLE: the first successful device-flow login writes
itself into `web.github.owner` (config-lock-guarded so concurrent first
logins race safely; the claim is logged loudly) — the install path has no
config-editing step.
`POST /auth/github` starts the flow with scope `repo`; the wait page polls at
GitHub's interval (one poll per render, `slow_down`-aware). On grant the app
keeps the login AND the token in the encrypted Rails session — the token
powers the Repos page's listing of the operator's GitHub repositories and
authenticates `gh repo clone` (passed as `GH_TOKEN`, never persisted).
Non-owner logins, denied grants, and expired codes render 403 pages. A
dev/test-only `/dev_login` seam (route drawn only when `Rails.env.local?`,
double-checked in the action) is how Capybara signs in without driving real
GitHub.
Owner authorization is re-checked against the current global config on every
owner-gated request, not just at sign-in. If `web.github.owner` changes while
an old session is still live, `ApplicationController#require_login` resets that
session and redirects to login so the old repo-scoped token does not remain
usable. The local dev/test seam is exempt only for tokenless local sessions.

Local loopback mode is a deliberate no-auth bypass for local foreground use:
when the CLI bind address is `localhost`, `::1`, or any `127.0.0.0/8` address
and `web.local_loopback` is not `false`, it exports `HIVEBOX_LOCAL_LOOPBACK=1`.
Rails still checks that the request peer is loopback before skipping login.
Non-loopback binds require either `--unsafe` or a configured `web.github.owner`;
when an owner gate authorizes a non-loopback bind, the CLI warns that
`web.github.owner` is the only login gate, and `0.0.0.0` without an HTTPS
origin also prints the Host-header/reverse-proxy warning.

## Surfaces

- **Status grid (`/`)** — a TUI-left-pane-parity project rail filters the
  grid client-side ("All projects" + one button per registered project;
  buttons not links so the permanent composer's typed text survives; a
  `+ Add project` link navigates to Repos because adding a project is a real
  page change; choice mirrored to `?project=` via replaceState; explicit
  project clicks sync the composer project select so new ideas land in that
  context, while filtered deep-links preselect the composer only when it is
  unset; a MutationObserver re-applies the filter after every broadcast
  replace/morph), composer (new idea with image attach: clipboard
  paste AND upload button; images become `[imageN]` placeholders and land in
  the task's `assets/` dir — `Commands::New`'s TUI contract), per-project
  task rows with stage badges and liveness dots. Live-updates over **Turbo
  Streams**: `StatusBroadcaster` subscribes to `StatusFeed#each_snapshot`;
  `StatusFeed` suppresses unchanged snapshots by comparing with only
  `generated_at` and `age_seconds` removed while keeping `mtime` /
  `folder_mtime` as liveness signals. The broadcaster sends the status-channel
  refresh first, then renders and replaces the `projects` frame over
  solid_cable, so task pages without that frame still receive a morph signal if
  the dashboard partial raises. The index opts that refresh into Turbo morphing
  with scroll preservation so a live row arrival does not yank the operator
  back to the top; the composer form is `data-turbo-permanent` because
  typed-but-unsent idea text and staged image chips live in browser state. No
  polling JS, no SSE. The daemon strip on the grid uses
  `Hive::Daemon::StatusReport.safe_payload` directly instead of constructing a
  `Hive::Commands::Daemon` CLI object; the view also reads
  `StatusReport::BINARY_DRIFT_ACTIONABLE` for the Repair affordance, so CLI
  JSON and web drift handling share the same producer constants.
- **Task page** — state-driven actions (Retry stage for red
  `recover_review` / `recover_execute` / `error` rows; Approve only when the
  marker makes a forward move possible; Run <verb> only when the project daemon
  is disabled; Diff only when the worktree exists; Reject, Force approve, and
  Drop — the TUI Shift+X parity hard delete via `Commands::Drop`, no undo — as
  described cards in a bottom Advanced section, confirm-gated), per-question
  brainstorm Q&A (the original idea shown above the form; answers go through
  BrainstormAnswerWriter; the forms are not `data-turbo-permanent`, and the
  answers controller snapshots/restores typed text plus caret across morphs,
  keyed by textarea name, so a new round can replace the old form without
  carrying stale drafts forward), artifacts rendered as sanitized markdown
  (redcarpet, GFM tables/fenced code; raw HTML escaped at render AND
  sanitized after; leading YAML front matter and standalone
  `Hive::Markers::MARKER_RE` comments dropped, while non-marker comments and
  fenced examples of markers remain visible as escaped text). Visual media from
  `7-artifacts` renders in a dedicated Demo section before the text artifacts:
  captured PNG/JPEG/GIF files are served from
  `GET /tasks/:project/:slug/media/:filename` and shown as an inline gallery
  with captions plus screenote links when the manifest carries
  `screenote_url`; failed captures render a warning banner with the recorded
  reason; skipped or absent manifests render nothing. The media route applies a
  first-pass filename constraint (a single component ending in png/jpg/jpeg/gif,
  with `format: false` so a trailing `.rb` cannot masquerade as an implicit
  format); the strict guarantee lives in the controller's `resolved_media_path`,
  which re-checks the filename against an anchored regex, requires `File.basename`
  equality, and resolves `File.realpath` to confirm containment under
  `<task>/media/` — refusing symlink and path-traversal escapes — before
  streaming with inline content type. Artifact summaries are UI chrome:
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
  Server-side, the polled `TasksController#log` path reads only a 256 KiB byte
  window and returns the last 200 lines with a torn leading line dropped, so a
  multi-MB agent log cannot pin a Puma worker every 3 seconds.
  The Diff route has the same bounded-subprocess discipline: it runs
  `git diff --` in its own process group, enforces
  `HIVEBOX_DIFF_TIMEOUT_SEC` (default 15s), writes combined output to a
  tempfile, and renders at most the first 512 KiB with an explicit truncation
  notice.
  Red diagnostic rows also render a danger banner from
  `tasks[].diagnostic.summary` so the page says why the row is stuck before
  offering Retry.
- **Repos** — registered projects, clone-by-URL (same allowlist as before:
  github.com https/ssh or `owner/repo`, leading-dash guard), and the
  operator's GitHub repository list (device-flow token; degrades to an inline
  notice when GitHub is unreachable or the grant was revoked). The setup form
  mirrors `hive init`'s questionnaire and carries a select-only Workflow
  control: fresh clone setup lists built-ins only (`coding`, `content`) with
  `coding` preselected, while "Re-run setup" lists built-ins plus that
  project's authored workflows and preselects the current `default_workflow`.
  The selected value is passed as `Hive::Commands::Init.new(..., workflow:)`;
  it is intentionally outside the `prompts:` answers hash. Clone runs call
  `gh repo clone` with the session token in `GH_TOKEN`, in a separate process
  group with `HIVEBOX_CLONE_TIMEOUT_SEC` (default 180s) as a hard deadline; on
  failure or timeout the partial target is removed so retry starts clean. A
  pre-existing directory is treated as a local checkout to re-init; a
  pre-existing non-directory target (file/symlink/etc.) is a 422 refusal, and
  `clone!` also refuses any existing target so its failure-path `rm_rf` only
  deletes a partial clone it created. Every registration runs a
  post-clone/post-existing-dir origin normalization pass:
  absent or non-GitHub remotes are left alone, while GitHub SSH remotes
  (`git@github.com:owner/repo.git` or `ssh://git@github.com/owner/repo.git`)
  become `https://github.com/owner/repo.git`. The box can only push with
  token-fed https credentials (`gh` clones over ssh when the operator's
  `git_protocol` prefers it, and ssh pushes dead-end because the container has
  no keys and no agent for a headless daemon). The Docker image wires git's
  github.com https credential helper to `gh auth git-credential`.
- **Agents** — PTY login relay (ADR-035) with a polled turbo-frame instead of
  meta-refresh; pi token form. `gh` joins the relay (login supplies git push
  credentials via the image's credential helper); its `--web` flow blocks on
  a bare Enter rather than a paste-back code, which the relay auto-answers.
  Codex uses `codex login --device-auth` rather than the localhost-callback
  `codex login`, because the callback server would bind inside the container
  and surface an unreachable localhost URL to the host browser. Grok uses
  `grok login --device-auth`. Codex, Grok, and `gh`
  are operator-ward poll flows: the one-time code is entered at the provider,
  the CLI keeps polling, and the status turbo-frame keeps refreshing until the
  PTY child exits while hiding the paste-back form. Claude remains the
  paste-back `claude setup-token` flow. Grok status also recognizes
  `XAI_API_KEY` and credentials under `GROK_HOME`. Raw PTY bytes are scrubbed to
  render-safe UTF-8 before the `<pre>` output is interpolated, and captured
  URLs are sanitized by replacing ANSI/terminal-control runs with spaces
  before re-extracting the first URL so adjacent URLs are split rather than
  spliced into one href.
- **Telegram** — first-timer setup guide (collapsible, open while the bot is
  unconfigured) covering BotFather `/newbot`, numeric chat IDs from
  `@userinfobot`, sending `/start` before the round-trip test, the
  no-webhook/long-polling model, and BotFather `/revoke` token rotation;
  getMe-validated token save, allowlist, supervisor SIGHUP, round-trip test
  message. Chat IDs are parsed with strict `Integer(..., exception: false)`
  before any Telegram network call or config/env write: blank input and
  handles such as `@mychannel` render 422 and persist nothing.

Task Drop is routed as `POST /tasks/:project/:slug/drop` →
`TasksController#drop` → `Hive::Web::Dispatcher#drop` →
`Hive::Commands::Drop`. It is intentionally in-process, not a daemon dispatch:
the task is gone after success, so the controller redirects to the grid. The
form posts the row's rendered `stage` as `from`; if the task moved after the
page rendered, `Commands::Drop` raises `Hive::WrongStage`, Rails renders the
typed 422 error page, and the moved task folder is left intact.

Task recovery is routed as `POST /tasks/:project/:slug/recover` →
`TasksController#recover` → `Hive::Web::Dispatcher#recover`. The controller
re-reads the current status row rather than trusting form-posted stage/marker
state. The dispatcher refuses manual-only states with
`RecoverySequence.manual_only_text`, derives the most discriminating
`--match-attr` through `NotificationBuilders.recovery_match_attr`, then writes
the first command (`hive markers clear ... --json`) to the daemon dispatch
queue with `trigger=web_recover` and persists the stage rerun as the same
request's sequence sidecar. If the guarded clear exits non-zero, the rerun is
not promoted.

Typed `Hive::Error`s render a readable error page (422; `InvalidTaskPath` →
404) — never a blank 500. Stage-run posts validate the action map before
writing a daemon request, and `Hive::Web::Dispatcher#dispatch` wraps queue
writer `ArgumentError`s (for example the queue's stricter slug grammar) as
typed 422s instead of surfacing an opaque 500. CSRF is Rails-default (per-form
tokens); every route except `/health`, `/up`, `/login`, `/logout`,
`/auth/github*`, and the dev/test-only `/dev_login` is behind the owner gate.

## Tests

`web/test/integration/` drives the real GithubAuth through the device-flow
routes via the `http:` DI seam (no API stubbing), including ownerless
first-login claim, persisted `web.github.owner`, request-time owner-change
session eviction, and later non-owner refusal,
and the real `Commands::New`/`Approve`/`Drop` plus web recovery queue writes
against a sandboxed `HIVE_HOME` (the suite NEVER touches the developer's real
config — `test_helper.rb` sets the sandbox before the app loads). It pins that
a red task page shows the diagnostic banner and Retry button, and that the
route queues the marker-clear command plus the hidden rerun sequence. It also
pins the Telegram first-run guide shape and strict chat-ID validation, repo
clone target refusal for non-directories, agent-login status rendering for
binary PTY output and operator-ward poll flows, root favicon/icon assets,
plain-vs-deep health semantics, the oversized diff cap/truncation notice,
media route streaming/refusal cases, and captured/skipped/failed Demo
rendering. Repos coverage pins the workflow select's built-in fresh list and
that posting `settings[workflow]` writes the same real `default_workflow` that
CLI init writes.
`web/test/system/` runs Capybara +
**capybara-playwright-driver**: login gate, composer image attach (upload
button for real; clipboard paste via a synthetic DataTransfer event — the
sanctioned JS exception), Turbo Stream live row arrival without reload, grid
project-rail filtering with URL sync, composer project sync, and
`+ Add project` routing, plus re-application after a live broadcast, grid
scroll plus composer draft preservation across a live broadcast, both approve
paths (typed refusal page + confirmed force), Q&A round replacement without a
lingering old form, typed Q&A preservation across a pushed morph, log-tail
follow/pause/resume with node-preserving frame morph reloads, artifact
open-state preservation across pushed morphs with live content refresh, and
repo setup workflow selection (fresh `content` writes config, re-run lists a
project-authored workflow and preselects the current default), plus
browser-visible Demo gallery images and failed-capture banner states. CI runs
both in the `web` job (`.github/workflows/ci.yml`) plus the web app's own
rubocop, and it explicitly runs `web/test/e2e/golden_path_e2e.rb`; the golden
path's daemon/Turbo row-replacement retry contract is covered in [[testing]].

`web/script/record_box_demo.rb` is a manual demo recorder, not a test. It
stages a temporary local repo, boots the real Rails app and real `hive daemon`,
uses stage-aware fake `claude` / `gh` shims so the pipeline advances in
seconds, drives Chromium through Playwright, and writes
`web/tmp/box-demo.webm` / `web/tmp/box-demo.mp4` via ffmpeg.

## Docker

`packaging/docker/Dockerfile`: agent CLIs install in an early cached layer;
the gem builds/installs from `/app`; the Rails app bundles and precompiles
assets (propshaft — no node build) at `/app/web` with a dummy build-time
secret. Local non-Docker installs instead use the managed release bundle
described in [[commands/setup]]. The image includes `asciinema` (records a terminal `.cast`) and
`ffmpeg`, but NOT a terminal-GIF encoder (`agg`/`vhs`) — `ffmpeg` cannot read a
`.cast`, so an in-box TUI/CLI demo records a `.cast` and then writes a `failed`
capture unless the agent installs `agg`/`vhs`. Browser capture depends on the
project/agent environment having agent-browser or Playwright available, and
missing tools record a failed media manifest instead of failing the pipeline.
The image sets git's system credential helper for `https://github.com`
to `gh auth git-credential`, so the Agents-page `gh` login also supplies push
credentials for repos under `/data/repos`. The supervisor still spawns
`hive web --bind 0.0.0.0` — unchanged
interface, now exec-ing Rails. Plain `/health` is unauthenticated web-tier
liveness; the Docker `HEALTHCHECK` hits `/health?deep=1`, which also verifies
the daemon pidfile through `Hive::PidFile` semantics and returns 503 when the
daemon child is down or stale.
`/data` remains the persistence boundary; the sqlite files for
cable/cache/queue live under `/data/state/hive/web-storage`.

`packaging/docker/install-box.sh` is the shell one-command install entrypoint
intended for `curl -fsSL https://hivecli.sh/box | sh`; Windows PowerShell uses
the same contract through `packaging/docker/install-box.ps1`, intended for
`irm https://hivecli.sh/box.ps1 | iex`. Both require reachable Docker, honor
`HIVEBOX_IMAGE` / `HIVEBOX_NAME` / `HIVEBOX_PORT` / `HIVEBOX_DATA` /
`HIVEBOX_BIND`, refuse to overwrite an existing container name, pull the image,
start it with `--restart unless-stopped`, mount persistent data, and print the
local URL plus claim reminder. The bind default is `127.0.0.1`, because an
ownerless box is claimed by its first GitHub login; operators can set
`HIVEBOX_BIND=0.0.0.0` after claiming or when fronting the box with a trusted
tunnel/proxy. The PowerShell variant uses Docker Desktop-oriented diagnostics
and avoids requiring `sh` or Git Bash volume-path translation.
`.github/workflows/release.yml` publishes the matching multi-arch GHCR image as
`ghcr.io/<owner>/hivebox:<version>` and `ghcr.io/<owner>/hivebox:latest` after
`release-finalize` succeeds. Image publishing is smoke-gated by
`packaging/docker/smoke.sh`: the release job boots the amd64 image before
pushing tags, and the post-publish `hivebox-smoke-arm64` job pulls the arm64
registry image on native `ubuntu-24.04-arm` Docker and runs the same smoke
against the published manifest. This replaced the old hosted macOS/Colima
attempt: hosted Apple Silicon runners do not expose nested virtualization, so
Colima cannot boot a Linux VM there. Current `.github/workflows/ci.yml` does
not run a push/PR Docker image smoke; it covers Rails web tests, the
golden-path browser E2E, and the Windows installer harness. The smoke is
intentionally front-door only (`/health`,
claimable `/login`, owner-gated `/`). The Windows workflow cannot run Linux
containers on hosted runners, so it syntax-checks `install-box.ps1` and runs
`packaging/docker/test-install-box.ps1` against a stubbed Docker CLI to pin the
installer's diagnostics and pull/run argv shape.

Root web assets are served from `web/public/`: `/favicon.ico` (multi-size
legacy icon), `/icon.svg`, and `/icon.png` (apple-touch). The layout links all
three so browsers no longer emit a root favicon 404, and the icon mark is the
terracotta honeycomb hive glyph rather than the old placeholder.

Backlinks: [[architecture]], [[modules/config]], [[modules/daemon]],
[[modules/bot]], [[decisions]].
