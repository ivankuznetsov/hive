---
title: hive web
type: command
source: lib/hive/commands/web.rb, lib/hive/web/, web/, packaging/docker/, .github/workflows/release.yml
created: 2026-06-04
updated: 2026-07-26
tags: [command, web, rails, turbo, hivebox-container, archive, retention]
---

**TLDR**: `hive web` boots the default native Hive browser UI — a vanilla
**Rails 8** app (importmap, Turbo, Stimulus, propshaft, solid_cable) living in
`web/` at the repo root. It is the browser counterpart to the TUI over the same
local registry and workflow state, with no mandatory sign-in on a verified
loopback request. Hivebox is the separate owner-gated container distribution
of the same app at `/app/web`. The web tier adds no
pipeline logic: status reads call `Hive::Commands::Status#json_payload` (via
`Hive::Web::StatusFeed`), gate approval calls `Hive::Commands::Approve`
in-process, task Drop calls `Hive::Commands::Drop` in-process, stage runs go
through the daemon dispatch queue from the filesystem-backed Rails `Task`, daemon status
renders the shared `Hive::Daemon::StatusReport.safe_payload` producer used by
`hive daemon status --json`, and setup flows
reuse `Hive::Web::GithubAuth`, `AgentsAuth`, `WorkflowLifecycle`, and the
Telegram validators from the gem. Red task recovery submits the fresh status
observation through the neutral `Hive::Recovery::API` to the same
`RecoveryCoordinator` used by Telegram, TUI, CLI/action, recorder, and daemon
healing.

## CLI

`hive web [--bind] [--port]` (defaults from the `web:` config block). The
command locates the Rails app in this order: `HIVE_WEB_APP_DIR` when it
points at a real Rails app, the managed version-stamped app under
`Hive::Paths.web_app_home` (refreshed when stale unless `--no-bootstrap` is
passed), then a source checkout `web/` next to `lib/`; if none exists and
bootstrap is allowed, it downloads/extracts the versioned web release bundle.
Managed installation prepares a staging directory with `bundle install` and a
production `assets:precompile`, requires usable `application.css` and
`application.js` entrypoints, verifies every Propshaft manifest asset resolves
to a contained file, and only then activates it under a refresh lock. Activation
keeps the previous generation as a sibling backup until the staged rename
succeeds; a failed rename restores that generation. Missing or corrupt assets
make even a same-version bundle repair itself.
For a managed bundle, provisioning, `db:prepare`, and the Rails server all run
through the exact Bundler recorded by the authenticated lockfile and the
current Ruby. A newer host-default Bundler cannot take over after a successful
install when systemd starts the service.
Relative `HIVE_WEB_APP_DIR` values are accepted but normalized before the
Rails env is built, so `BUNDLE_GEMFILE` points at the real app Gemfile after
the command changes into the app directory.
It exports `SECRET_KEY_BASE` (derived from the same persisted
`Hive::Web::SessionSecret` file as before — sessions survive container
recreation), `HIVE_WEB_ORIGIN` (extra Action Cable origin allow; same-origin
host traffic is accepted without config), and
`HIVE_WEB_STORAGE_DIR` (the solid-stack sqlite files, under
`Hive::Paths.state_home/web-storage` so they live on the `/data` mount). In
production it guarantees a usable fingerprinted asset graph before Rails
starts. Versioned managed bundles compile and validate assets while they are
provisioned; direct source checkouts and operator-managed app overrides run
`bin/rails assets:precompile` at startup and refuse to boot unless the resulting
manifest and application CSS/JavaScript entrypoints are usable. Startup
compilation uses temporary build storage rather than the live solid-stack
databases. It then runs `bin/rails db:prepare` and execs `bin/rails server`.
Without a container app, source checkout, or bootstrapped managed bundle, the
command exits 1 with guidance. Released package roots include `hive.gemspec`,
so the managed bundle
can resolve its path dependency without a parent source checkout; the Rails
source itself remains a separate authenticated bundle.

Hivebox keeps a separate asset lifecycle: its container image compiles and
validates the Rails asset graph during the image build, then exports the
internal `HIVEBOX_PRECOMPILED_ASSETS=1` marker so the shared launcher does not
repeat native web preparation at container startup.

`hive web install [--force] [--json]` installs the separate `hive-web` autostart
service using the invoked user-facing binary path. Its thin Hive installer owns
web environment rendering and output policy while `Hive::UserService` owns
file drift, plan revalidation, atomic replacement, and manager application.
`--force` also forces an authenticated, rollback-safe managed-bundle
reprovision before replacing the
service, even when the installed bundle has a current version stamp and healthy
assets. This matters when separately merged dependencies or web content change
without a Hive version bump; ordinary foreground/start bootstrap remains a
no-op for a healthy current bundle. If the service was already running, a
successful refresh restarts it exactly once even when the unit file itself is
unchanged. A service-unit upgrade that already restarted it is not restarted a
second time.

The default managed source is the signed release bundle, so a forced refresh can
require network access and `cosign`; verification or preparation failure occurs
before any service-unit mutation and leaves the current bundle and service
intact. Source-checkout dogfood must set `HIVE_WEB_BUNDLE_URL` to that checkout's
`web/` directory when it needs unreleased web content. `--no-bootstrap` is
authoritative and suppresses both managed installation and refresh, including
when combined with `--force`.

`hive web start --detach` starts that service and reloads
systemd-user first on Linux so a unit written while systemd-user was unavailable
becomes visible. Foreground
`hive web start` is equivalent to `hive web`. `status --json` emits
`hive-web-status.v1`; `install --json` emits `hive-web-install.v1`. Both carry
`mode: "managed_service"`, deduplicated environment migration warnings, and
separate installed, enabled, running, manager availability, URL, and readiness
state on success and pre-dispatch/runtime errors. Readiness probes the local
managed Rails endpoint even when the advertised origin points at DNS or a
reverse proxy. Install success requires the observed service to be installed,
enabled, running, and ready; an inactive or active-but-not-ready service emits
`ok: false` before the command exits non-zero. Mutating install uses 40 health
samples at 250 ms intervals, allowing a cold Rails/bundle boot roughly ten
seconds before reporting `active_not_ready`; read-only status still takes one
immediate sample. Configuration failures from
`status --json` retain the versioned status error envelope on stdout.
Bootstrap and service-install exceptions from `install --json` likewise emit
exactly one versioned install error envelope, distinguished by
`bootstrap_failed` and `service_install_failed`.

## Environment compatibility

`Hive::Web::Environment` is the single resolver for the six shared-app
settings: `HIVE_WEB_APP_DIR`, `HIVE_WEB_ORIGIN`, `HIVE_WEB_STORAGE_DIR`,
`HIVE_WEB_LOCAL_LOOPBACK`, `HIVE_WEB_DIFF_TIMEOUT_SEC`, and
`HIVE_WEB_CLONE_TIMEOUT_SEC`. The corresponding legacy native-web aliases are
`HIVEBOX_WEB_APP_DIR`, `HIVEBOX_ORIGIN`, `HIVEBOX_STORAGE_DIR`,
`HIVEBOX_LOCAL_LOOPBACK`, `HIVEBOX_DIFF_TIMEOUT_SEC`, and
`HIVEBOX_CLONE_TIMEOUT_SEC`. Blank is unset; canonical wins conflicts,
including invalid canonical values, and old-only or both-set input warns with
the replacement and next-major support window. Warnings are deduplicated on
stderr, included in setup/web JSON, and exposed as doctor warning rows.
Container-only Hivebox variables are deliberately outside this deprecated set.
Foreground Rails receives resolved canonical timeout values even when the
operator supplied an alias, and managed systemd/launchd units persist all six
resolved settings so foreground and service-manager launches agree.

## Access and GitHub connection

Owner-gated access uses a GitHub **device flow** (RFC 8628, see [[decisions]]
ADR-036). This includes Hivebox and native Hive web reached through any
non-loopback hostname. An ownerless instance is CLAIMABLE: the first successful device-flow login writes
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

Local loopback mode is a deliberate no-auth bypass for local native use:
when the CLI bind address is `localhost`, `::1`, or any `127.0.0.0/8` address
and `web.local_loopback` is not `false`, foreground launches export
`HIVE_WEB_LOCAL_LOOPBACK=1` and managed services persist the same value. An
explicit non-loopback service bind always persists `0`, even when an inherited
canonical or legacy environment setting enables local loopback mode, so service
and foreground launches share the same bind safety boundary.
Rails checks both the actual socket peer in `REMOTE_ADDR` and the normalized
Host before skipping login; both must be literal loopback values.
It deliberately ignores proxy-expanded `remote_ip` and `X-Forwarded-Host`,
classifying only the literal `HTTP_HOST` authority. Rails accepts every other
syntactically valid hostname so arbitrary VPN, tunnel, and reverse-proxy names
need no Hive allowlist entry, but those requests redirect through the GitHub
owner login even when the proxy's socket peer is loopback. Proxies should
preserve the incoming Host. A proxy or TCP forwarder that lets an untrusted
client send `Host: localhost` enters the local trust boundary and must
authenticate or restrict clients. If `web.github.owner` is empty, the first
successful owner-gated login claims the instance; use the intended owner before
sharing the URL.
A locally authenticated operator sees the
complete primary navigation under the `hive` product identity and is labelled
`Local`; GitHub-dependent repository browsing stays behind an explicit
**Connect GitHub** action. At the 390px mobile breakpoint, all six primary
capabilities fit beside the account action without starting inside a horizontal
scroll overflow; spacing uses fixed small insets so Linux and local Chromium
font metrics preserve the same visible set. Navigation state is grouped by the first segment of
Rails `controller_path`, so namespaced task, workflow, and Telegram resource
controllers retain their parent section's active link when they render a
complete page. Completing the optional GitHub connection from verified
literal-loopback access stores the login and token in the browser session but
never claims or changes `web.github.owner`. The same native service reached
through a non-loopback Host presents owner sign-in instead, and an ownerless
instance is claimable.
Outside loopback mode, native installs use the `Hive web` product identity;
the container-only `HIVEBOX_PRECOMPILED_ASSETS=1` marker preserves the
`hivebox` identity for the Docker distribution.
Non-loopback binds require either `--unsafe` or a configured `web.github.owner`;
when an owner gate authorizes a non-loopback bind, the CLI warns that
`web.github.owner` is the only login gate, and `0.0.0.0` without an HTTPS
origin also prints the TLS/reverse-proxy warning.
Production accepts arbitrary Host values in both modes so the controller-level
login gate can run; Host never grants the no-auth bypass unless it is loopback.

## Surfaces

The project-filtered **Modules** surface presents installed and historical
module rows using the same redacted `Hive::Modules::Status` object as CLI
list/status/inspect. Rails does not parse generation locks or patrol stores.
Install, update, enable, disable, settings changes, and uninstall use the same
preview-bound lifecycle service as CLI: signed receipts bind candidate/current
identity, settings, hooks, bindings, cursors, and individual grants, and any
drift returns a no-write preview-again response. `/workflows` remains the
workflow authoring/selection surface and preserves its existing managed
Honeycomb projections.

- **Status board and grid (`/board`, `/grid`, `/`)** — Board is the first-visit
  default. The view-switch forms store a signed browser preference that `/`
  follows thereafter; read-only visits and Turbo refreshes of either explicit
  route do not rewrite that preference. Both are server-rendered views over the same
  `StatusFeed` snapshot and remain equal navigation choices. `Board` groups
  active tasks into project/workflow bands and orders columns from each
  workflow descriptor; empty projects use their configured default workflow,
  an unknown live stage is appended instead of hiding its tasks, and degraded
  projects or unavailable workflows remain visibly marked rather than looking
  like healthy empty pipelines. Cards
  link to the native task resource and reuse the same Retry, Approve, Run, and
  Diff forms as the task page. There is deliberately no parallel drag/drop,
  drawer, cursor, transition, or audit subsystem: workflow mutation continues
  through the existing task controllers. The application shell and primary
  navigation use the full viewport width with fluid edge gutters; the project
  rail grows to a bounded desktop width while the status content receives all
  remaining space. Kanban tracks grow beyond their comfortable minimum when a
  large screen has room, and each band scrolls horizontally inside the page
  when it does not. `Grid` retains the compact per-project task rows and gains
  the same fluid content area. Both ordinary views consume status's
  workflow-aware archive projection:
  expired archived rows are absent, and a positive project count renders
  `… and 1 older archived task (hive archive to view)` or
  `… and N older archived tasks (hive archive to view)` as a direct link to the
  project-scoped archive. A TUI-left-pane-parity project rail filters either view through
  ordinary GET links ("All projects" + one link per registered project;
  projects are ordered by descending in-flight task count, preserving registry
  order for ties, and the grid plus permanent composer selector stay in that
  same order across live updates without losing the current selection). Rails
  reads `?project=`, renders only that project's Board/Grid markup, and
  redirects unknown project names to the same canonical route without the
  stale filter. Unrelated project markup never enters a filtered document. A
  small Stimulus click enhancement selects the explicit project in the
  permanent composer before Turbo follows an unmodified in-tab link, so its
  typed text and staged files survive while new ideas retain the selected
  context. It reads the raw data attribute so JSON-looking project names stay
  identifiers, and modified/new-tab clicks do not mutate the current tab.
  Choosing
  All projects deliberately keeps that composer choice. There is no filter
  observer, animation-frame reconciliation, DOM hiding, or History API state
  mirror. A
  `+ Add project` link navigates to Repos because adding a project is a real
  page change. The composer supports new ideas with image attach (clipboard
  paste AND upload button; images become `[imageN]` placeholders and land in
  the task's `assets/` dir — `Commands::New`'s TUI contract). It shares the
  server's eight-image / 10 MB-per-image limits in rendered Stimulus values,
  accepts the bounded prefix of a mixed batch with accessible rejection
  feedback, and rebuilds the hidden multipart `FileList` once per batch rather
  than once per file. At most 16 picker/clipboard entries are inspected, so a
  forged enormous `FileList` cannot turn the bound into an unbounded main-thread
  scan. Attachment chips deliberately use a constant-memory generic glyph
  instead of decoding attacker-sized image dimensions on the status page. A
  detached form clears its retained `FileList` after a cancellable permanent-
  move window. Puma additionally rejects bodies over the complete valid
  81 MiB idea envelope before Rack multipart parsing; chunked request bodies
  are rejected at the parsed-header boundary because Puma cannot incrementally
  enforce that limit while spooling them. The status view then renders
  per-project
  task rows with stage badges and liveness dots. Live-updates over **Turbo
  Streams**: `StatusBroadcaster` subscribes to `StatusFeed#each_snapshot`;
  a dedicated `StatusChannel` starts that shared subscription when the first
  live page connects and stops it when the last page disconnects, so booting
  or leaving the server idle performs no fleet scans. Pending, active, and
  closed ownership is synchronized per channel: teardown during stream
  verification prevents later acquisition, and repeated cleanup releases an
  accepted channel at most once without blocking unrelated connections. Failed
  first-poller startup rolls the shared subscriber count back, rejects that
  channel, and lets the browser retry. Validation and lease acquisition happen
  before `stream_from` queues adapter registration, preventing a rejected
  startup from landing a late pub/sub handler. A request-time snapshot
  primes the feed before Cable connects, avoiding an immediate duplicate scan.
  Only the first idle request can claim that baseline; a later competing render
  cannot replace the value the first page actually rendered. Each render
  carries a SHA-256 token derived from its exact semantic snapshot (canonical
  key order, with volatile timestamps removed), rather than a process-local
  counter. After Action Cable confirms the subscription,
  `StatusChannel#catch_up` compares that page token with the current feed:
  a current fresh navigation performs no HTTP work, while a genuinely stale
  or competing render receives one targeted Turbo refresh. The token remains
  valid across Puma workers and process restarts, so a worker mismatch cannot
  certify stale markup. The targeted stream echoes the page token; its
  permanent source carries that token and URL only through the same-URL Turbo
  move, then consumes the live-element handoff by URL into connection-local
  state, even if the reconciliation GET renders a different token. A lagging
  Cable worker can therefore cause at most one reconciliation GET on that
  connection rather than a refresh loop. The handoff is a live-element
  property rather than cloneable DOM state, so navigation—including history
  restoration after a page without the status source—cannot revive an older
  URL's attempt. A genuine socket disconnect releases it for later recovery.
  Connected
  pages share one five-second polling cadence regardless of their count. The
  subscribing page already rendered the primed snapshot, so the broadcaster
  does not send a duplicate first refresh.
  The ordinary feed uses `Hive::Tui::StateSource` as a shared bounded
  projection cache, serialized behind `CachedStatusCommand` for concurrent
  Puma callers. Cold construction performs one authoritative ordinary scan but
  no second unfiltered archive scan. Steady liveness refreshes scan only active
  workflow stages and merge cached visible terminal rows, so the five-second
  cadence is proportional to active work rather than total archive size.
  Terminal-directory changes, policy edits, and retention boundaries rebuild
  the ordinary projection immediately; a five-minute backstop repairs missed
  signals. `/archive` remains lossless by invoking the unfiltered Status
  producer on demand and never replacing the ordinary feed's cache. Archive
  task links resolve only the requested registered project and stage through
  the unfiltered producer, so their shell, log, media, diff, and action routes
  do not multiply lossless fleet scans.
  `StatusFeed` suppresses unchanged snapshots by comparing with only
  `generated_at` and `age_seconds` removed while keeping `mtime` /
  `folder_mtime` as liveness signals. Active task-folder mtimes are part of the
  bounded source fingerprint, so an added or removed artifact invalidates the
  page token without waiting for the fallback parse. The poller publishes its
  comparable key with the payload and reuses the existing semantic token when
  that key is unchanged, so volatile-only ticks do not repeat canonical JSON
  hashing.
  `hidden_archived_task_count` remains in that comparison, making a
  boundary- or policy-driven count change material even if every active row is
  unchanged.
  The broadcaster first renders one Turbo Stream
  message containing the refresh plus the server-sorted composer selector,
  then sends that complete message once over solid_cable. The refresh GET
  renders the project rail and the selected Board/Grid subset from the current
  URL, keeping HTTP as the filter authority.
  A partial render failure therefore delivers nothing and can be retried
  without creating a refresh-only request loop. The refresh
  re-renders the current URL (or `/`'s saved preference), so Board and Grid
  cannot be cross-patched with markup for the other view; task pages without
  the dashboard targets still receive the same morph signal. Stable digest IDs
  keep project/workflow bands, columns, and task cards attached to the same DOM
  identity across reorder morphs. A status-level submission guard marks the
  mutation at Turbo's confirmed `submit-start` boundary and defers one refresh while
  the composer or a card action is in flight. It replays after a
  non-redirecting response; a successful redirect's fresh GET already
  reconciles without racing the operator back to the old URL. The final
  submission admission stays at document scope across Stimulus morph
  reconnects, the final redirect URL is guarded on the document root across
  Turbo's body replacement, and both late refresh streams and their old-URL
  replace visits remain suppressed until that URL is active. Declining a
  confirmation does not start submission admission.
  This prevents a
  filesystem broadcast from aborting the mutation. The app-owned Action Cable
  source stays permanent across morphs and performs the version comparison
  only from its confirmed subscription callback; there is no reconnect DOM
  observer, timer, or fresh-navigation refresh. Async Cable setup is
  generation-guarded: a handle whose DOM owner disconnects before confirmation
  waits for the current transport's confirmation, rejection, or disconnect
  before release, so an abandoned page cannot keep the server poller alive or
  race unsubscribe ahead of subscribe—even during reconnect. If no callback
  arrives within five seconds, Hive closes the otherwise-unowned Cable transport
  to force server cleanup before dropping the local handle. The server checks
  teardown before deferred adapter registration and again when registration
  completes, immediately removing any handler that landed after the first
  cleanup. A deferred adapter exception releases the shared lease and closes
  the socket with reconnect enabled. If turbo-rails' lazy
  consumer promise rejects, Hive clears the
  poisoned cached promise before retrying at a bounded five-second cadence;
  if subscription creation throws after Action Cable registration, Hive removes
  the partial registration, disconnects that failed consumer, and creates a
  fresh one. A server-side poller startup failure rejects the subscription, and
  the rejected callback schedules the same bounded retry. Detaching the source
  cancels the retry. The task-page owner encloses every
  mutation form, so those submissions cross the same refresh guard as Board
  actions. A
  failed Turbo broadcast also remains pending across last-subscriber shutdown
  and is retried by the replacement broadcaster. The initial connection does
  not duplicate the fresh page GET. The composer's stream hook keeps the
  browser's current project selection when that project still exists; ordering
  belongs to the server while unfinished form state remains local. A successful
  idea POST returns to the same-origin Board/Grid URL that submitted it, so an
  explicit deep link does not jump to the saved/default view. The index
  opts that refresh into Turbo morphing
  with scroll preservation so a live row arrival does not yank the operator
  back to the top; the composer form is `data-turbo-permanent` because
  typed-but-unsent idea text and staged image chips live in browser state. Its
  Stimulus controller rehydrates the staged-file index if Turbo reconnects the
  permanent node, clears a truly detached form's FileList after a cancellable
  delay, and clears the submitted text, chips, and upload transport on a
  successful `turbo:before-fetch-response`
  while the form is still connected (`turbo:submit-end` remains a fallback);
  `status_refresh_controller.js` owns submission-versus-refresh ordering for
  every form on the status surface, while refreshes on other clients continue
  normally;
  the selected project remains as working context, so the next idea cannot
  accidentally resubmit the completed draft even when Turbo moves the
  permanent node during rendering. At mobile widths the composer toolbar
  becomes a two-row grid: the project selector owns the first row and the
  image/submit actions share the second, so long registered-project names
  cannot widen the document beyond the viewport. The horizontal project rail
  keeps edge padding while it scrolls. No polling JS, no SSE. The daemon strip uses
  `Hive::Daemon::StatusReport.safe_payload` directly instead of constructing a
  `Hive::Commands::Daemon` CLI object; the view also reads
  `StatusReport::BINARY_DRIFT_ACTIONABLE` for the Repair affordance, so CLI
  JSON and web drift handling share the same producer constants.
  It presents one compact state banner (running, warning, or stopped), hides
  internal service-installation fields, and surfaces binary drift as the
  human-facing “Binary path differs” repair action. A running supervised
  hivebox daemon intentionally has no separate platform service unit; the
  strip therefore shows CLI recovery guidance only when the daemon is actually
  down, not merely when `service_installed` is false. A
  stopped, otherwise healthy daemon points to `hive daemon start --detach`;
  a missing or drifted service points to `hive daemon install --force`.
- **Archive (`/archive`)** — requests `StatusFeed#archive_snapshot`, whose
  separate `Status.new(archive: true)` producer bypasses ordinary retention and
  is deliberately excluded from the live feed's priming and dedup baseline.
  It renders every workflow-aware archived task with the existing task
  attributes, preserves `?project=` in its rail and links, and links task pages
  with `source=archive`. `Tasks::BaseController` honors that explicit source
  for the task shell and every child controller, while the shell propagates it
  to log, media, diff, answer, intervention, run, approval, rejection,
  recovery, and drop routes. An expired task opened from the archive therefore
  remains usable instead of its child requests becoming false 404s. Each route
  resolves that exact project/stage rather than rescanning the fleet, and
  terminal archive logs load once without the live task page's three-second
  polling loop. Native Hive web and Hivebox use this same Rails route and
  producer path.
- **Task page** — state-driven actions (Retry stage for red
  `recover_review` / `recover_execute` / `error` rows; Approve only when the
  marker makes a forward move possible; Run <verb> only when the project daemon
  is disabled; Diff only when the worktree exists; Reject, Force approve, and
  Drop — the TUI Shift+X parity hard delete via `Commands::Drop`, no undo — as
  described cards in a bottom Advanced section, confirm-gated). Because every
  browser stage run is still consumed by the single daemon dispatcher, an
  enrolled task whose daemon is down shows an explicit auto-advance blocker
  with `hive daemon start --detach` instead of offering a queue action that
  cannot run. The liveness-only probe avoids the service/binary inspection cost
  of the full dashboard envelope. The page also provides per-question
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
  format); the strict guarantee lives in `Task#media_path`,
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
  It also skips timer ticks while Turbo marks the frame busy, so a slow frame
  request cannot be repeatedly cancelled and restarted by its own interval.
  Server-side, the polled controller delegates to `Task#latest_log`, which
  reads only a 256 KiB byte
  window and returns the last 200 lines with a torn leading line dropped, so a
  multi-MB agent log cannot pin a Puma worker every 3 seconds.
  `Task#diff` has the same bounded-subprocess discipline: it runs
  `git diff --` in its own process group, enforces
  `HIVE_WEB_DIFF_TIMEOUT_SEC` (default 15s), writes combined output to a
  tempfile, and renders at most the first 512 KiB with an explicit truncation
  notice; `Tasks::DiffsController#show` only exposes that result. The model also
  owns original-idea/title resolution and the workflow-aware passable,
  recovery, terminal, dispatch-action, and run-verb decisions used by the
  dashboard and task page. Displayed run verbs consume
  `TaskAction::READY_COMMANDS`, retaining only the web-specific `run` to
  `stage` label, so display and dispatch cannot derive separate command maps.
  Model tests drive successful, failed, and timed-out diff subprocesses and
  pin process-group termination, reaping, readable errors, and tempfile
  cleanup. Status projects/tasks are wrapped before ERB, so presentation
  helpers no longer read task files or duplicate command policy.
  Red diagnostic rows also render a danger banner from
  `tasks[].diagnostic.summary` so the page says why the row is stuck before
  offering Retry. A stopped-daemon blocker is shown only for non-terminal
  tasks; terminal directories come from every registered workflow descriptor,
  so content, bench, managed, and project-authored workflows do not inherit the
  coding workflow's `9-done` assumption.
- **Workflows** — a project-scoped view of the real `hive workflow list`
  dimensions: built-in and authored descriptors, managed selected/retained
  generations, integrity, version/provenance, and the configured default.
  Owner-authored scaffolds delegate to `Hive::Commands::Workflow new` with the
  packaged templates and commit on `hive/state`; the page links back to project
  setup to choose the default. Managed install/update/remove are two-step:
  their first POST runs the command's exact no-write dry-run and renders
  permissions, content/file/dependency/security changes, escalation reasons,
  or retained/deletable generations. Preview forms intentionally use native
  navigation because they return a successful review page rather than Turbo's
  required mutation redirect. Applying requires an explicit checkbox plus a
  15-minute MessageVerifier receipt bound to project and operation, plus source
  for install or workflow name for update/remove, and the exact package or
  selection commit+digest. The adapter re-fetches candidate packages
  and requires complete candidate/current identity fields; the command/store
  layers recheck the selected baseline, so stale or incomplete receipts fail
  before mutation. Security expansion has a second, non-composable checkbox.
  Receipt tests cover cross-operation replay, real expiry, and missing consent
  for every mutation. Rails represents lifecycle list rows as `Workflow`
  models and preview/application state as `WorkflowChange`; the established
  URLs route to standard `create` actions for preview and change resources.
  The operation comes from the matched route's path parameters, so a submitted
  `operation` field cannot redirect an install preview into another lifecycle
  action. A fixture-backed integration test runs the real workflow commands
  through the adapter for the full preview/apply lifecycle.
  The known legacy-vs-v2 `workflow publish` gap is stated in the page instead
  of exposing a button that opens an unusable registry PR. At mobile widths the
  primary header wraps to a second full-width row, keeping all five sections
  visible without document overflow while preserving the local GitHub-connect
  action.
- **Repos** — registered projects, clone-by-URL (same allowlist as before:
  github.com https/ssh or `owner/repo`, leading-dash guard), and the
  operator's GitHub repository list (device-flow token; degrades to an inline
  notice when GitHub is unreachable or the grant was revoked). The setup form
  mirrors `hive init`'s questionnaire and carries a select-only Workflow
  control: fresh clone setup lists built-ins only (`coding`, `content`, `bench`) with
  `coding` preselected, while "Re-run setup" lists built-ins plus that
  project's authored workflows and preselects the current `default_workflow`.
  The selected value is passed by `Project#setup!` as
  `Hive::Commands::Init.new(..., workflow:)`; it is intentionally outside the
  `prompts:` answers hash. The `Project` model also supplies a non-TTY
  provisioning input and a request-local error capture,
  so CLI preflight questions can never wait on Puma's inherited terminal and
  strand the browser on “Cloning…”. Non-interactive doctor/agent-skill findings
  return as an alert alongside the successful registration/settings notice
  instead of disappearing into Puma stderr. Clone runs call
  `gh repo clone` with the session token in `GH_TOKEN`, in a separate process
  group with `HIVE_WEB_CLONE_TIMEOUT_SEC` (default 180s) as a hard deadline; on
  failure or timeout the partial target is removed so retry starts clean. A
  pre-existing directory is treated as a local checkout to re-init; any
  pre-existing symlink or non-directory target is a 422 refusal. The
  `Repository` model also refuses any existing clone target so failure-path
  cleanup only deletes a partial clone it created. Model tests exercise both
  nonzero clone exits and hard-deadline expiry, including process-group
  kill/reap behavior plus partial-target and tempfile cleanup. Every
  registration runs a
  post-clone/post-existing-dir `Repository` origin-normalization pass:
  absent or non-GitHub remotes are left alone, while GitHub SSH remotes
  (`git@github.com:owner/repo.git` or `ssh://git@github.com/owner/repo.git`)
  become `https://github.com/owner/repo.git`. The box can only push with
  token-fed https credentials (`gh` clones over ssh when the operator's
  `git_protocol` prefers it, and ssh pushes dead-end because the container has
  no keys and no agent for a headless daemon). The Docker image wires git's
  github.com https credential helper to `gh auth git-credential`.
- **Agents** — PTY login relay (ADR-035) with a polled turbo-frame instead of
  meta-refresh; pi token form. Login create/show/completion enter the dedicated
  `AgentLogin`, `Agents::LoginsController`, and
  `Agents::LoginCompletionsController` resources while keeping the existing
  URLs. The status URL renders only one immutable login snapshot; its
  two-second refresh never rebuilds account statuses, registered projects, or
  selected-project skill health from the Agents collection page. Turbo-frame
  responses omit a self-referential `src`, and polling is attached to
  replaceable inner content so the final completed snapshot disconnects the
  timer. `gh` joins the relay (login supplies git push
  credentials via the image's credential helper); its `--web` flow blocks on
  a bare Enter rather than a paste-back code, which the relay auto-answers.
  Codex uses `codex login --device-auth` rather than the localhost-callback
  `codex login`, because the callback server would bind inside the container
  and surface an unreachable localhost URL to the host browser. Grok uses
  `grok login --device-auth`, exposed through the same first-class login action
  and constrained session routes as the other relayed agents. Codex, Grok,
  and `gh`
  are operator-ward poll flows: the one-time code is entered at the provider,
  the CLI keeps polling, and the status turbo-frame keeps refreshing until the
  PTY child exits while hiding the paste-back form. Claude remains the
  paste-back `claude setup-token` flow. Grok status also recognizes
  `XAI_API_KEY`, `GROK_AUTH_PATH`, and credentials under `GROK_HOME`. Raw PTY bytes are scrubbed to
  render-safe UTF-8 before the `<pre>` output is interpolated, and captured
  URLs are sanitized by replacing ANSI/terminal-control runs with spaces
  before re-extracting the first URL so adjacent URLs are split rather than
  spliced into one href. The page also exposes the managed-skill health model
  shared with `hive doctor`: the operator explicitly checks one registered
  project at a time (opening Agents does not synchronously inventory every
  agent CLI), then sees per-capability health and remediation. **Repair safe
  changes** delegates to `hive setup-agents`' in-process command with explicit
  browser consent and a non-TTY input. It installs or updates missing/stale
  Hive-managed packages and rechecks the result; conflicting and custom skills
  retain the provisioner's no-overwrite behavior. Failed/residual repair
  redirects include the command classification and up to three failed/skipped
  operation messages (or residual health/stderr fallback), and the same bounded
  details are logged so transient registry failures are distinguishable from
  persistent configuration conflicts.
- **Telegram** — first-timer setup guide (collapsible, open while the bot is
  unconfigured) covering BotFather `/newbot`, numeric chat IDs from
  `@userinfobot`, sending `/start` before the round-trip test, the
  no-webhook/long-polling model, and BotFather `/revoke` token rotation;
  getMe-validated token save, allowlist, supervisor SIGHUP, round-trip test
  message, and first-contact pairing. Pairing can securely bootstrap with an
  empty allowlist: the form persists `bot.pairing_enabled`, pending 24-hour
  codes come from the shared `hive pairing list` JSON contract, and an
  owner-confirmed approval delegates to the command's atomic
  resolve/allowlist/reload/notice/consume lifecycle. An already validated token
  can be left blank while changing authorization settings; only a replacement
  token is sent through `getMe` and persisted. Chat IDs are parsed with strict
  `Integer(..., exception: false)`
  before any Telegram network call or config/env write: when pairing is off,
  blank input renders 422, and handles such as `@mychannel` always render 422
  and persist nothing. These rules, secret persistence, supervisor reload,
  test delivery, and pairing lifecycle are owned by the Rails `TelegramBot`
  model. The settings controller is limited to `show`/`update`; the existing
  test-message and pairing-approval URLs now target standard `create` actions
  on named resources.

Task Drop is routed as `POST /tasks/:project/:slug/drop` →
`Tasks::DropsController#create` → `Task#drop!` → `Hive::Commands::Drop`. It is
intentionally in-process, not a daemon dispatch:
the task is gone after success, so the controller redirects to the grid. The
form posts the row's rendered `stage` as `from`; if the task moved after the
page rendered, `Commands::Drop` raises `Hive::WrongStage`, Rails renders the
typed 422 error page, and the moved task folder is left intact.

Task recovery is routed as `POST /tasks/:project/:slug/recover` →
`Tasks::RecoveriesController#create` → `Task#recover!`. The shared base
controller re-reads the current status row rather than trusting form-posted
stage/marker state, then submits that observation to the canonical recovery
writer. The queued/cooldown/running/blocked/terminal/unavailable receipt is
flashed verbatim. `StatusFeed` overlays the same durable receipt onto the
ordinary status payload with an in-memory join, so a snapshot still performs
one fleet scan. Pending lifecycle states keep Retry visible but disabled with
an accessible status summary; terminal recovery hides it.

Typed `Hive::Error`s render a readable error page (422; `InvalidTaskPath` →
404) — never a blank 500. Stage-run posts validate the action map before
writing a daemon request. `Task#run!` compares the submitted action and stage
with the freshly loaded row, refuses stale forms, and wraps queue-writer
`ArgumentError`s (for example the queue's stricter slug grammar) as typed 422s
instead of surfacing an opaque 500. Idea creation likewise enters
`Project#add_idea!`. `Hive::Commands::New#call!` deliberately leaves
`SystemCallError`/`IOError` raising for in-process adapters, so the Rails
resource normalizes those failures to a path-redacted typed 422 while retaining
the original exception as its cause for diagnostics. Other exceptions still
follow the ordinary programmer-error 500 path rather than being mislabeled as
operator failures. `POST /daemon/repair` is the conventional create action
on `DaemonRepairsController`, backed by `Daemon#repair!`. CSRF is Rails-default (per-form
tokens). Outside verified local-loopback access every route except `/health`, `/up`, `/login`,
`/logout`, `/auth/github*`, and the dev/test-only `/dev_login` is behind the
owner gate; a verified local loopback request bypasses that gate for the
complete local UI.

## Tests

`web/test/integration/` drives the real GithubAuth through the device-flow
routes via the `http:` DI seam (no API stubbing), including ownerless
first-login claim, persisted `web.github.owner`, request-time owner-change
session eviction, and later non-owner refusal,
and the real `Commands::New`/`Approve`/`Drop` plus web recovery queue writes
against a sandboxed `HIVE_HOME` (the suite NEVER touches the developer's real
config — `test_helper.rb` sets the sandbox before the app loads). It pins that
a loopback-authenticated local operator gets the full navigation and an
explicit GitHub connection action. It also covers Tailscale-style forwarded
client addresses over a loopback socket, arbitrary proxy hostnames reaching
the GitHub login instead of a Host-authorization 403, mutation rejection before
side effects, local `hive` branding, optional GitHub connection without owner
claim, and local logout returning to the usable dashboard. Managed-bundle tests
pin staged dependency/asset preparation,
same-version missing-asset repair, explicit force refresh of a healthy
same-version bundle, the ordinary-start no-op, install-command propagation, and
preservation of the previous bundle on preparation or activation failure.
Command tests additionally pin exactly-once restart after refreshing an
unchanged running service, no duplicate restart after a unit upgrade, and help
text that discloses the refresh and service-repair scope. Repository setup
always invokes the CLI init adapter with
non-TTY provisioning input. It also pins that
a red task page shows the diagnostic banner and Retry button, and that the
  route submits the current row to the durable recovery coordinator and renders
  its queued/cooldown/running/blocked/terminal receipt. It also
pins the Telegram first-run guide shape, strict token/chat-ID validation,
empty-list pairing bootstrap, saved-token reuse, pending-code rendering,
corrupt-store visibility, consent-gated approval, and the test-message
resource's missing-token/success rendering, repo clone target refusal
for non-directories,
agent-login resource lookup/route ownership, status-only rendering without
Agents inventory work, self-reference-safe frame responses, binary PTY output,
Grok route reachability, and operator-ward poll flows,
managed-skill opt-in inspection and consent-gated repair, root favicon/icon
assets, repair failure-cause rendering, successful repo-init preflight alerts,
workflow list/scaffold delegation, signed preview tamper rejection,
cross-operation replay/expiry/missing-consent rejection, non-composable update
escalation consent, real adapter-to-command lifecycle execution, and
removal-retention disclosure,
running/stopped daemon banner behavior plus descriptor-derived terminal-stage
suppression,
plain-vs-deep health semantics, the oversized diff cap/truncation notice,
media route streaming/refusal cases, and captured/skipped/failed Demo
rendering. Repos coverage pins the workflow select's built-in fresh list and
that posting `settings[workflow]` writes the same real `default_workflow` that
CLI init writes.
`web/test/system/` runs Capybara +
**capybara-playwright-driver**: login gate, composer image attach (upload
button for real; clipboard paste via a synthetic DataTransfer event — the
sanctioned JS exception), Board/Grid route switching with saved preference,
descriptor-ordered board cards with native task actions, mobile board
containment, Turbo Stream live row arrival without reload, grid
project-rail filtering with URL sync, composer project sync, and
`+ Add project` routing, plus re-application after a live broadcast, grid
scroll plus composer draft preservation across a live broadcast, successful
composer text/chip/file reset before Turbo renders with project-context
retention, failed-submit
draft/file retention on a 422-shaped Turbo event, and attachment-index rebuild
after a real Stimulus disconnect/reconnect before adding and submitting another
image, eight-image/10 MB browser enforcement with bounded batch transport,
constant-memory non-decoding chips, staged-File cleanup after a true disconnect
without cleanup during a permanent move, Puma pre-Rack declared-length and
chunked-body rejection,
non-overlapping busy-frame polling, dedicated agent-login polling that renders
only its resource and disconnects after completion, both approve
paths (typed refusal page + confirmed force), Q&A round replacement without a
lingering old form, typed Q&A preservation across a pushed morph, log-tail
follow/pause/resume with node-preserving frame morph reloads, artifact
open-state preservation across pushed morphs with live content refresh, and
ordinary-board hidden summaries navigating through the lossless Archive route
to an expired task detail page, plus
repo setup workflow selection (fresh `content` writes config, re-run lists a
project-authored workflow and preselects the current default), plus
real browser workflow scaffolding and exact-permission managed install review,
plus browser-visible Demo gallery images and failed-capture banner states. CI runs
both in the `web` job (`.github/workflows/ci.yml`) plus the web app's own
rubocop, and it explicitly runs `web/test/e2e/golden_path_e2e.rb`; the golden
path's daemon/Turbo row-replacement retry contract is covered in [[testing]].

`web/script/record_box_demo.rb` is a manual demo recorder, not a test. It
stages a temporary local repo, boots the real Rails app and real `hive daemon`,
uses stage-aware fake `claude` / `gh` shims so the pipeline advances in
seconds, drives Chromium through Playwright, and writes
`web/tmp/box-demo.webm` / `web/tmp/box-demo.mp4` via ffmpeg.
Its real-resume helper uses a sandbox state home, reads the live status row,
submits recorder-owned recovery through the same writer, and boots the daemon
to consume it; it never deletes `plan.md` or foreground-runs the plan stage.

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
`packaging/docker/smoke.sh`: native amd64 and arm64 jobs each push untagged
content by digest, require both `/health` and a ten-second stable window of
daemon-backed `/health?deep=1`, and recheck deep health after the front-door
assertions. Only then does a promotion job attach the versioned and `latest`
tags to a multi-arch manifest built from those exact proven digests. The arm64
job runs on native `ubuntu-24.04-arm` Docker. This replaced the old hosted macOS/Colima
attempt: hosted Apple Silicon runners do not expose nested virtualization, so
Colima cannot boot a Linux VM there. Current `.github/workflows/ci.yml` does
not run a push/PR Docker image smoke; it covers Rails web tests, the
golden-path browser E2E, and the Windows installer harness. The smoke covers
web and daemon health plus the front door (`/health`, `/health?deep=1`,
claimable `/login`, owner-gated `/`) and fetches the exact digest-stamped CSS
and JavaScript graph advertised by that page, then runs the managed-install
manifest predicate against the real precompile output. The Windows workflow
cannot run Linux
containers on hosted runners, so it syntax-checks `install-box.ps1` and runs
`packaging/docker/test-install-box.ps1` against a stubbed Docker CLI to pin the
installer's diagnostics and pull/run argv shape.

Root web assets are served from `web/public/`: `/favicon.ico` (multi-size
legacy icon), `/icon.svg`, and `/icon.png` (apple-touch). The layout links all
three so browsers no longer emit a root favicon 404, and the icon mark is the
terracotta honeycomb hive glyph rather than the old placeholder.

## Task-local reads and degraded status

Ordinary task show, log, diff, media, and mutation routes resolve one registered
project and task through `Hive::Web::TaskTargetResolver`; they do not call the
fleet-wide status producer. Explicit `source=archive` routes use that same
targeted resolver with retention filtering disabled, so hidden terminal tasks
remain addressable and mutations revalidate current task state without a stale
fleet cache. One process-wide `StatusFeed` owns polling,
single-flight refresh, actual scan count, and latest-good state. First-scan
failure renders an explicit unavailable page. A later failure retains the last
good rows with an accessible warning and disables freshness-dependent mutation
controls until a fresh token arrives.

Task diff uses `Hive::Web::TaskDiff`: it validates the owned worktree pointer,
runs argv-form Git commands in bounded process groups, caps and redacts output,
and separates committed, staged, unstaged, and untracked changes. HTML and JSON
share typed `available`, `empty`, `truncated`, and `unavailable` results with
409/422/503/504 failure mappings. Browser log/resource polling chains one
abortable timeout at a time, pauses while hidden, backs off failures, and
ignores late responses after disconnect.

## Supervised worktree capture server

`hive web capture --task-folder TASK_FOLDER [--source-root WORKTREE]` is the
supported task recorder. The task must be in `7-artifacts`, have a current
`required` capture receipt, and own the exact clean source worktree. The
optional source root is an assertion: it must resolve to that owned worktree.
The command seeds deterministic private fixture data, records the board-to-task
flow through pinned Playwright Chromium, verifies PNG and WebM output with
ffmpeg/ffprobe, rechecks the clean source HEAD, and publishes task-local media
plus `media/capture-manifest.json` only after teardown. `--json` emits that
manifest; the text form reports the retained artifact count and destination.
Capture applicability ignores generated HTML marker comments, so fields such
as `browser=skipped` cannot manufacture a user request for visual proof.

`hive web capture-server` is an internal recorder interface. It requires an
exact clean source root, private runtime root, lifecycle token, and inherited
control descriptor. A lockfile-keyed `SourceBundle` cache installs the web gems
outside the source worktree under a private flock and atomic rename. It invokes
the exact `BUNDLED WITH` version through RubyGems rather than assuming the
`bundle` shim is on the service or agent PATH; a missing locked Bundler fails
before cache population. The same resolved executable owns bundle installation,
Rails asset/database preparation, the Rails server, and fixture CLI setup.
The supervisor prepares isolated assets/databases, binds literal `127.0.0.1`
on an allocated port, and emits `hive-web-capture-runtime` v1 readiness JSON.
The server thread owns its duplicate of the readiness descriptor until it
exits; startup failures include the bounded, redacted private server log.
Closing the control channel tears down the owned process group and runtime.
The runtime root is accepted only when it is empty and unclaimed, or when its
private owner receipt proves the same lifecycle token. Cleanup repeats that
ownership proof before removing runtime state, so a recorder cannot adopt or
erase an unrelated directory.

The private production server enables Propshaft's asset middleware only for the
capture runtime, so its externally compiled CSS and JavaScript are served in
the recording without writing `public/assets` into the source worktree. Normal
production web service asset handling is unchanged.

The environment is deny-by-default: it gets private HOME/XDG/Hive/storage,
bundle, assets, and tmp roots plus an ephemeral Rails secret; provider,
GitHub/Telegram/release, SSH-agent, proxy, Bundler/Gem override, and Ruby hook
state is not inherited. `BrowserBundle` installs the exact Playwright 1.60.0
package declared in `web/package-lock.json` and its Chromium payload into a
private lockfile-keyed cache outside linked worktrees. Capture preflights that
cache, ffmpeg, and ffprobe.

Backlinks: [[architecture]], [[modules/config]], [[modules/daemon]],
[[modules/bot]], [[decisions]].
