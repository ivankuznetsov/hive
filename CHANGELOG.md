# Changelog

All notable changes are documented here, newest first. Hive ships frequent micro-releases (see [docs/RELEASING.md](docs/RELEASING.md#versioning-policy)): each `vX.Y.Z` git tag gets a `## X.Y.Z` section with user-facing bullets and, for notable releases, descriptive subsections — no `[Unreleased]` accumulator. Versioning is [SemVer](https://semver.org): PATCH for fixes and small changes (the common case), MINOR for notable features, MAJOR for milestones.

## 0.6.9

- Fixed managed llm-wiki services timing out during a valid multi-batch drain.
  The outer systemd limit now covers the worker's bounded worst case of three
  agent and indexing batches, while retaining the 4 GiB memory limit, no-swap
  policy, and machine-wide provider lock.

## 0.6.8

- Fixed headless llm-wiki hooks losing their memory-bounded scheduler after a
  missing user-systemd bus environment. Hive now reconstructs the standard bus
  variables, preserves the installed service marker when signaling fails, and
  safely falls back through the host-wide provider lock.
- Fixed generated `wiki/log.md`-only commits recursively entering the wiki
  queue and launching an agent despite containing no new source material.
  Source fragments and other project/wiki changes continue to refresh.
- Fixed project configuration accepting unsupported root keys at some command
  boundaries; Hive now rejects them consistently before task work begins.
  (#790)

## 0.6.7

- Fixed large llm-wiki backlogs opening a source-pin circuit before any bounded
  recovery could run. Source refs are now pinned in configurable batches, and
  crash-left queue records are reconstructed when their commit and diff remain
  available instead of silently stranding recoverable work. (#836)
- Fixed an older linked checkout overwriting the repository-shared llm-wiki
  runner and headless-agent configuration. Hive now keeps the primary checkout
  authoritative for the shared runtime, preventing a stale worker from
  restoring unsafe pre-fix behavior. (#836)

## 0.6.6

- Fixed scheduled llm-wiki refreshes multiplying into thousands of host timers
  from disposable repositories. Hive now installs one bounded timer per
  primary repository, removes catch-up stampedes, reconciles old units, and
  serializes refreshes behind a machine-wide lock and memory limit. Scheduled
  updates publish through `llm-wiki/refresh` without dirtying protected
  checkouts. (#828)
- Added managed draft-PR handoff for agent work, with bounded branch publication
  and recovery evidence when an agent reaches a review boundary. (#827)
- Made native Hive web the default experience and added the workflow-derived
  Kanban board, mobile status improvements, and clearer first-run launch paths.
  (#796, #817, #822, #826)
- Made Hive operations agent-native across Claude, Codex, Pi, and OpenClaw with
  fresh status/action contracts and canonical managed skill projections. (#824)
- Fixed generic approve binding to the task's actual stage and simplified the
  workflow, Rails, and patrol architecture around value-bearing work. (#799,
  #816, #825)

## 0.6.5

Hive 0.6.5 makes autonomous maintenance quieter, sharper, and safer. Patrols
carry source-backed findings through proof and delivery, Architecture Patrol
has its own bounded capacity, and scheduled wiki upkeep stays out of developer
checkouts while respecting the subscription circuit. The release also hardens
the logs and web surfaces operators depend on when work runs unattended.

### Patrols that produce actionable work

- Added a complete evidence-to-delivery path for ordinary patrol. Reviewers get
  bounded source context and the exact single-line evidence contract; completed
  fixes survive token boundaries; shipping cycles reserve validation capacity;
  and the configured patrol timeout now governs the independent proof. (#805,
  #808)
- Gave post-merge Architecture Patrol separate durable launch accounting and a
  higher 96-run daily safety backstop without weakening shared token budgets or
  full-lifetime launch locks. Fresh projects enable confined autofix with a
  reviewable GitHub issue fallback, while existing discovery-only projects do
  not gain mutation authority silently. (#808)
- Fixed provider-limit holds waiting until a distant advertised reset date.
  Hive now keeps that date as an operator-visible estimate while retrying
  hourly, so account switches, usage resets, and credit top-ups recover without
  manual marker surgery. (#810)

### Safer unattended operation

- Fixed attempt-log recovery after a torn final write. Reopened stream logs now
  isolate the incomplete tail before appending, so the first fully written
  post-restart frame remains replayable. (#807)
- Fixed the bot logger raising during the failure of both rotation and reopen.
  Rotation, fallback, and writes are serialized, and events degrade to stderr
  without losing the in-flight record. (#814)
- Rebuilt scheduled llm-wiki maintenance around the shared Git queue and the
  llm-wiki 0.1.15 drain contract. Empty or circuit-blocked runs exit before QMD,
  worktree creation, or provider launch; real refreshes use a disposable branch
  instead of modifying any registered checkout; linked worktrees share one
  recoverable runtime. (#820)
- Fixed re-enabled Linux wiki timers becoming active with no future trigger.
  Their first run is now ten minutes after activation, followed by the existing
  daily cadence. (#821)

### Web and agent setup

- Fixed native `hive web` access behind authenticated loopback proxies and made
  production asset installation atomic and self-repairing. Source checkouts now
  compile and validate assets before Rails starts, while Hivebox retains its
  build-once image path. (#815, #819)
- Fixed a live-refresh race that could create an idea successfully but leave
  the submitted text and attachment ready to send again. Only page-wide refresh
  streams pause during submission; targeted updates and other clients remain
  live. (#813)
- Refreshed the public OpenClaw skill with current workflows, bounded status
  monitoring, subscription-aware patrol guidance, and explicit preview and
  consent gates. Removed unattended package transactions, runtime patching,
  direct service overrides, and the embedded polling program. (#813)
- Updated the repository's tested ERB lock to 6.0.5. (#809)

## 0.6.4

- Fixed hivebox occasionally retaining a successfully submitted idea in its
  permanent composer while Turbo rendered the redirect. Successful responses
  now clear duplicate-ready text and attachments before the permanent node can
  disconnect, while retaining the selected project as working context.
- Fixed concurrent babysitter dry-run commands racing to create their shared
  audit log and dropping all but the first record. Dry-run setup now creates a
  private empty log before agent commands launch; every append retains the
  existing fail-closed target and descriptor checks.

## 0.6.3

- Retired the reduced Architecture and Writing scaffold templates now that
  their full reviewed workflows ship through Honeycomb. Old `--template`
  invocations now point to the corresponding install command; blank and
  research scaffolds remain available.
- Fixed Architecture Patrol rejecting a valid leading JSON fence when Claude
  appended a plain-text leverage rationale. Hive now treats that first fenced
  document as canonical while still rejecting leading prose or ambiguous
  additional backtick/tilde fences, and retains the exact raw response for
  audit.

## 0.6.2

- Fixed ordinary patrol exhausting its launch allowance without advancing past
  source-verified clean features. Review batches now fit the remaining launch
  headroom, preserve clean-prefix progress, and keep one fixer launch available
  when the quota permits it.
- Fixed Architecture Patrol depending on the registered developer checkout.
  Discovery and retry now use a detached exact worktree pinned to committed
  default-branch source, so local branches and uncommitted edits cannot block or
  contaminate analysis.
- Fixed Architecture Patrol quota churn and lost reviewer evidence. Bounded
  runs stop after the first failed slice, back off until the next UTC budget
  window when daily headroom is exhausted, accept a strict whole-message JSON
  fence, and retain raw reviewer responses with their job context.

## 0.6.1

- Fixed Honeycomb installation defaults for scoped workflow actors. When a
  project-default agent cannot enforce a slot's tool scope, Hive now suggests
  Claude for that slot while preserving fail-closed admission for explicit
  incompatible mappings.

## 0.6.0

- Install and update full Honeycomb workflows with immutable per-slot
  agent/model/effort mappings selected by the operator.
- Bind optional package inputs to authorized executable slots without storing
  values, and expose manifest-bound tools and prompt assets at runtime.
- Add bounded council completion for capped editorial workflows while keeping
  the existing operator-wait behavior as the default.

## 0.5.3

- Fixed Architecture Patrol merge intake timing out after querying every merged
  pull request. Bounded runs now use one exact GitHub merged-time range and
  inspect only pull requests from the current patrol window.

## 0.5.2

- Added the production Honeycomb catalog-v2 client. `hive workflow install`,
  `update`, `list`, and `remove` now resolve the official flat catalog, verify
  canonical manifests, complete package trees, release fingerprints, catalog
  commit pins, lifecycle state, Hive compatibility, and security-sensitive
  update diffs before mutation.
- Added fail-closed runtime admission for reviewed v2 packages. The current
  release admits only the lossless low-risk task-local read-only permission
  shape; broader coarse disclosures remain blocked until Hive can enforce them
  exactly.

## 0.5.1

### Diagnostics and release safety

- Fixed `hive doctor` aborting when a configured custom reviewer has no
  Hive-managed skill resolver; unmanaged agents now remain visible as
  informational diagnostics.
- Fixed the published-release verifier reaching the operator's live user
  service manager. Lifecycle checks now use inert `systemctl` / `launchctl`
  stubs inside the isolated verification prefix.

### Hivebox reliability

- Fixed the hivebox daemon crashing at startup because the architecture-patrol
  schema validator was missing from the packaged gem's runtime dependencies.
- Fixed image publication so native amd64 and arm64 images must each sustain
  daemon-deep health before their exact digests are promoted to the versioned
  and `latest` multi-architecture tags.
- Fixed supervised hivebox dashboards showing the daemon as both running and
  down when no separate platform service unit is installed.

## 0.5.0

Hive 0.5.0 makes long-running autonomous work durable, adds a safe lifecycle
for reusable community workflows, and substantially expands both ordinary and
architecture patrol. It includes every change merged since v0.4.2; the
previously prepared but unpublished 0.4.3 changes are included here.

### Community workflows and agent setup

- Added the Honeycomb workflow lifecycle: `hive workflow install`, `list`,
  `update`, `remove`, and `publish` can manage reviewed community workflows
  with deterministic manifests, immutable task-pinned generations, semantic
  and security diffs, crash-safe activation, and explicit consent for
  permission escalation. Managed workflows fail closed before installation and
  again before agent launch when their tool, command, path, or network policy
  cannot be enforced; existing built-in and project-authored workflows keep
  their previous behavior. (#751)
- Added evidence-backed diagnosis and provisioning for the enabled Claude,
  Codex, and Pi skills Hive depends on. `hive doctor` remains read-only,
  `hive setup-agents` previews and verifies one consented repair plan, and
  interactive `hive init` can hand unresolved defaults to the same engine
  without overwriting user-owned aliases or Codex sources. (#750)
- Added path-qualified `Read(...)` and `Edit(...)` workflow permissions, with
  exact task/repository scope projection and fail-closed portable-path
  validation. Workflows can now read a repository while limiting writes to
  selected files or subtrees. (#769)
- Added strict repository-aware dependency admission across manual commands,
  daemon dispatch, and status. Missing, ambiguous, corrupt, cross-repository,
  or stale dependencies now hold safely with an explicit reason and correction
  instead of running against the wrong prerequisite.
- Fixed upgrades from the former project-local hive-bench workflow. An exact
  legacy `bench.yml` remains visible and runnable with a migration hint, and
  `hive init PROJECT --workflow bench` archives it and atomically selects the
  built-in workflow without disturbing modified or independently authored
  descriptors. (#747)

### Durable autonomous execution

- Added durable task-stage attempt ownership. Accepted agents run under a
  detached supervisor with leases, heartbeats, checkpoints, framed logs, and a
  terminal receipt, so work can survive the CLI, bot/web request, or daemon
  process that launched it. Daemon restarts adopt live work, duplicate delivery
  attaches or replays instead of spawning a second agent, and a definitively
  lost owner preserves evidence for a bounded successor. (#767)
- Added generation-scoped task conditions backed by an fsynced event journal
  and rebuildable projection. Execute decisions now use evidence from the
  current task input, attempt family, and exact HEAD, so an old no-change wait
  cannot block a repaired attempt that produced a commit; status, daemon, TUI,
  bot, web, and task actions consume the same reproducible decision. (#768)
- Added durable implementation identity across execute, PR opening, and review
  fixes. Retries and restarts keep the selected provider/model, PR opening uses
  that provider's utility model, review and CI fixes retain the exact execute
  model, and CLI/JSON/TUI/web status explains the ownership and effort source.
  (#773)
- Fixed generic agent stages overwriting provider-limit cooldowns and other
  agent-authored terminal errors with `agent_preflight_failed`; the daemon can
  now retain and resume the specific retryable state. (#728)

### Patrol and architecture patrol

- Expanded post-merge architecture patrol into a durable scheduled workflow:
  immutable merge manifests feed bounded language-neutral discovery, semantic
  finding families, leverage scoring, resumable fenced actions, isolated
  automatic fixes, validated GitHub issue/PR publication, and persistent
  reconciliation after crashes or partial remote success.
- Raised ordinary patrol signal quality with repository-wide candidate
  selection, evidence/impact/novelty ranking, component-level deduplication,
  immutable selection receipts, proof-gated fixes, and shared token, turn,
  timeout, concurrency, and daily-spend ceilings for ordinary and architecture
  patrol.
- Fixed patrol scanning and review handoff so every new or resumed publication
  proves the current remote default-branch commit and exact patrol head. Failed
  fetches, unusable saved pins, same-named tags, stalled transports, or an
  advanced base now fail closed instead of publishing stale review work. (#783)
- Fixed malformed or unreadable project configuration taking down the global
  daemon. Patrol now isolates that project, refuses model spend when no
  validation command can prove a shippable fix, and measures each patch from
  its immutable pre-agent base. (#758)
- Hardened patrol and incident-regression CI against option-value spoofing,
  unsafe repository Git helpers, path/symlink/rename escapes, unbounded logs or
  work, stale artifacts, non-hermetic subprocess state, incomplete retries,
  corrupt durable state, and publication/reconciliation edge cases.

## 0.4.2

- Added `bench` as a third built-in workflow for reproducible coding-agent
  campaigns. `hive init PATH --workflow bench` installs the self-contained,
  versioned `extract -> generate -> judge -> publish` harness without requiring
  a separate hive-bench checkout. (#734)
- Made long-running benchmark and other generic agent stages quota-aware, so
  provider-limit failures retain cooldown metadata and can resume after reset
  while malformed results and non-limit failures still stop for review. (#734)
- Fixed daemon child logging to write bounded per-task captures under Hive's XDG
  state directory instead of shared `/tmp`, preventing temporary-directory quota
  exhaustion from crashing dispatch and keeping logs out of tracked state. (#718)

## 0.4.1

- Fixed Grok auth overrides so explicit `GROK_AUTH_PATH` and `GROK_HOME`
  values must be absolute, including API-key flows. This prevents preflight and
  task-worktree processes from resolving different credential locations. (#714)
- Fixed daemon reloads so updated project/global concurrency limits take effect
  immediately and atomically; invalid reloads keep the last valid limits. (#716)
- Fixed pre-dispatch `--json` usage failures to emit the command-specific
  published schema instead of a generic or mismatched envelope. (#709)
- Hardened babysitter dry runs: the prompt now treats stderr skip markers as
  authoritative, and the optional skip log refuses group/world-readable or
  writable files before appending sensitive command arguments. (#703, #710)
- Hardened `hive-eval` against inherited Rake dry-run options, incomplete or
  cross-run scenario reports, unsafe report directories, and non-atomic report
  publication. (#711)
- Fixed `hive drop` so verified descendants in nested process groups are
  terminated with PID-reuse guards; incomplete process discovery fails safely
  instead of claiming a complete tree cleanup. (#701)

## 0.4.0

- Added xAI Grok as a built-in agent backend, with headless streaming output,
  stage/config overrides, diagnosis and web-login support, honest unavailable
  token telemetry, and a compact report-only Compound Engineering reviewer.
  Authentication follows `GROK_AUTH_PATH`, `GROK_HOME`, API-key, and device-login
  flows, including passwd-less runners. Requires Grok CLI 0.2.90 or newer.
  (#695, #713)
- Added enforceable `timeout_sec` and `budget_usd` resource controls to custom
  workflow stages. Descriptor values outrank project defaults; agent and council
  commands share process-group timeout handling, while unsupported native budget
  caps are reported clearly. (#700)
- Added `hive refactor-patrol`, a first-class architecture cleanup discovery
  command that turns bounded findings into the existing patrol workflow. (#656)
- Hardened Hive's self-review and E2E toolchain around symlinked artifacts,
  report-path validation, dynamic-loader/PATH injection, descendant cleanup,
  git diff/merge drivers, and leading JSON help/version parsing. (#655, #661–#688)
- Fixed relative web-app overrides, rotated TUI marker artifact capture, and
  merged-PR digest wrapper coverage. (#697–#699)
- Updated the development lint stack to RuboCop 1.88.2. (#670)

## 0.3.7

- Fixed hive failing to start on Arch Linux with `cannot load such file -- erb`:
  erb is now a declared runtime dependency. Distros ship erb as a separate
  package since ruby unbundled it, so every verb (`tui`, `plan`, the daemon)
  crashed on a vendored install that lacked it. (#693)
- Fixed the daemon crashing on its first tick — and systemd restart-looping to
  `start-limit-hit` — whenever a legacy-layout project is registered: the
  dispatcher's `:legacy_layout_detected` log event was missing from the daemon
  logger's whitelist, so the log call itself raised. Legacy projects now log
  and continue. (#694)
- Custom workflows learned review councils, per-stage agent/model overrides,
  and agent-terminal stages. (#687)
- Fixed the patrol babysitter's dry-run git stub blocking help-viewer
  execution. (#673)

## 0.3.6

- Fixed the hivebox Docker image build: `hive web` now exports `HIVE_CLI_ROOT`
  only when serving the managed web bundle, so the image's prebuilt `/app/web`
  bundle (installed against its own `..`) is no longer invalidated at boot and
  the pre-push smoke passes — the image publishes again for the first time
  since v0.3.2.
- The daily digest gains a merged-PR source: PRs merged the previous day are
  listed alongside task activity.

## 0.3.5

- Fixed the hivebox container startup path so the supervisor passes
  `--allow-public` when binding the web UI to `0.0.0.0`; the GitHub owner gate
  still protects the UI, and the release image smoke can boot a fresh box.
- Fixed AUR channel verification to retry the fallback `hive-bin` clone, so a
  transient AUR HTTPS EOF does not fail post-release verification after publish.

## 0.3.4

- Added an `hive init` prompt for ad-hoc PR auto-fix, so `hive review --pr`
  defaults to review-only mode while still letting operators opt into local fix
  commits.
- Enabled GitHub review publishing in freshly rendered project configs by
  default, so ad-hoc PR review comments land back on the PR.
- Updated Hivebox project setup to expose the same ad-hoc auto-fix choice and
  pass it through the shared `hive init` prompts contract.

## 0.3.3

Hive goes local-first: one `hive setup` command installs and runs the web UI without
Docker, strangers can pair with the Telegram bot via a one-time code approved from the
CLI, the daemon auto-retries recoverable failures, and review errors now carry
classified, actionable reasons. Any GitHub PR can be reviewed ad hoc without a
pipeline task.

### Local web install & run (non-Docker)

- New `hive setup`: one-command local provisioning — dependency diagnostics with exact
  fix commands (external CLIs like `gh`/`claude`/`codex` are diagnosed, never silently
  installed or authenticated), bootstraps qmd and the managed Rails web bundle,
  installs the daemon service pinned to the invoking binary, and enrolls the current
  project. `--service` also installs the managed web service; `--no-bootstrap` is
  diagnose-only; `--json` emits an ordered phase envelope whose `ok` always matches
  the exit code.
- `hive web` grows a managed-service lifecycle: `install`, `start --detach`, `stop`,
  `status [--json]` via systemd-user (Linux) / launchd (macOS). Foreground `hive web`
  works as before.
- Loopback binds (default `127.0.0.1:4567`) need no login; `web.local_loopback: false`
  opts back into GitHub login. Non-loopback binds are refused without a configured
  owner or an explicit `--unsafe`/`--allow-public`.
- The managed web bundle is fetched per-version from the release asset, bundle-installed
  in staging before swap (a failed upgrade can't break the working install), and
  auto-refreshed when stale after a CLI upgrade.
- Binary-drift detection: `hive daemon status --json` reports the unit's installed
  binary vs the expected one (`binary_drift`: path/version/unparseable/unreadable);
  the web dashboard shows daemon health and a "Repair daemon" button that queues
  `hive daemon install --force` through the daemon's own maintenance queue.

### Telegram bot: self-service pairing

- With `bot.pairing_enabled`, an unknown chat's `/start` now gets a one-time pairing
  code instead of silence. The owner approves with
  `hive pairing approve telegram <CODE>`: the chat lands on the allowlist, a live bot
  is SIGHUP-reloaded, and the user gets a "✅ Approved" DM. `hive pairing list` shows
  pending codes; both commands take `--json` (`hive-pairing-list.v1` /
  `hive-pairing-approve.v1`). The bot can boot with an empty allowlist when pairing
  is enabled, so a fresh install is reachable before any chat is approved.

### Daemon self-healing

- The daemon auto-retries recoverable terminal error markers (kill switch:
  `daemon.auto_retry.enabled`, default on).
- Fixed: Claude stop-hook fix failures are retried instead of parking the task.

### Review pipeline

- `hive review --pr <number|#number|URL>` reviews any GitHub PR ad hoc — no pipeline
  task needed; fix commits on borrowed PRs stay opt-in.
- Non-limit triage/fix failures now stamp a classified `reason=` (`merge_conflict`,
  `network_timeout`, `tool_permission_denied`, `agent_crashed`, `unknown`) instead of
  flat `triage_failed`/`fix_failed`; the condensed raw cause is preserved in
  `message=`.
- Fixed: provider usage-limit failures in 6-review are classified correctly and keep
  the cooldown-based self-heal.
- Fixed: `hive diagnose` surfaces on-disk evidence instead of a bare fallback.
- Fixed: launcher scripts ship in the gem, and the Claude 2.1.179 tmux ready prompt
  is detected.

### Internals

- Architecture pass over the local web mode: the daemon-status envelope moved to
  `Hive::Daemon::StatusReport` (CLI and web dashboard share one producer); the
  daemon/bot/web service installers share one unit-path rule and one renderer pair;
  `hive setup` phases run through a single failure-recording runner; the unused
  `--yes` flag was removed before ever shipping.
- New `Hive::AtomicFile` — the one atomic tempfile+rename write helper; the pairing
  store and approval queue use it. Dropped the unemitted `rate_limited` enum member.

### CI & testing

- A macOS runner now exercises the real launchd install round-trip for the daemon and
  web services (previously stub-only).
- Fixed: `web/Gemfile.lock` path-gem sync restored the hivebox-web CI job after the
  root lockfile gained `rexml`.
- The Telegram `/idea` e2e driver handles the bot's file-collection "Done" step.

### Docs

- OpenClaw hive-skill playbooks: status bundle, daemon diagnostics & safe repair,
  local dogfood workflow, marker recovery, daemon auto-advance fallback, and a task
  watch recipe.

### Also

- A batch of `hive patrol` hardening fixes: git-grep separator smuggling, asciinema
  2.4/v3 flag compatibility, hidden copied artifacts in manifests, optional-asciinema
  TUI aborts, gh Git-trace env scrub, tui_refute tmux preflight, dry-run skip-log
  dedup.

## 0.3.2

Setup, the Telegram bot, and TUI performance are the focus of this release. Selected agent backends now persist globally so new projects inherit them; the bot gains idea-by-default capture, a `/waiting` view backed by a daily pending-answer digest, task-id slash commands, and structured JSON errors; and TUI status polling now scales with the number of active tasks instead of the whole archive.

### Setup

- Selected agent backends now persist globally, so new projects inherit your choice instead of re-prompting each time.

### Telegram bot

- Bare text sent to the bot is now captured as an idea by default instead of erroring.
- New `/waiting` command lists tasks awaiting your input, backed by a daily pending-answer digest so nothing stalls unseen.
- Slash commands accept a bare task id (e.g. `/approve 42`).
- Added log severity levels and quieted routine `bot.log` noise.
- `--json` usage errors now return a structured `hive-bot-status` envelope instead of prose.
- Fixed: every needs-input row now gets a working action button or is suppressed — no dead buttons.
- Fixed: "Show details" always renders row content.
- Fixed: stuck-task alerts are suppressed for healthy live-agent retries.

### Performance

- TUI status polling cost now scales with the number of active tasks rather than the full archive.

### Pipeline & status

- Fixed: markerless `3-plan` tasks are runnable instead of being parked behind a needs-input gate.
- Fixed: tmux review-fix no longer stamps terminal `REVIEW_ERROR phase=fix reason=fix_failed` when Claude finished cleanly but the interactive Stop hook missed `.done` / `result.json`; Hive now requires artifacts plus commit/no-change evidence and emits `claude_completion_fallback`.
- Needs-input status labels now differentiate by the reason a task paused.

### Packaging

- Fixed: the published arm64 hivebox image is smoke-tested on native arm64 Linux instead of macOS/colima.

### Also

- A batch of `hive patrol` dry-run sandbox hardening fixes.

## 0.3.1

Custom workflows: Hive's pipeline engine is now generic data. Author your own per-project workflow — writing, research, triage, translation, anything — in a few lines of YAML, scaffold it from a sample, and let the daemon run it the same way it runs `coding`. This release also lands a large patrol-driven security-hardening wave, a redesigned daily digest, task dependencies with stacked PRs, and device-flow agent logins in hivebox.

### Custom workflows (workflow-as-data)

- A workflow is now just an ordered list of stages in a YAML descriptor under `.hive-state/workflows/<id>.yml`. The built-in `coding` and `content` pipelines and your own project-authored ones all run through one generic engine — stage `kind:` (`agent`/`terminal`) drives runner, status, and advance behavior. Descriptors validate strictly at author time: `SAFE_SLUG` ids, bare `state_file` basenames, exactly one of `instruction`/`skill` per agent stage, last stage must be terminal.
- `hive workflow new ID` scaffolds a project-local descriptor plus stage instruction(s), commits them on `hive/state`, and points you at the exact instruction file to edit before the first run.
- `hive workflow new ID --template NAME` seeds from a curated sample instead of a blank stub — real stage instructions copied in, not placeholders. Ships `blank`, `writing` (inbox → research → draft → edit → done), and `research` (inbox → gather → synthesize → report → done); an unknown name lists what's available.
- `hive init --new-workflow ID [PATH]` bootstraps a project and binds it to a freshly scaffolded custom workflow as its `default_workflow`, in one command.
- Workflow selection is a first-class setup step in both `hive init` (CLI) and the hivebox web new-project form — you pick the workflow when you create the project. `--workflow` help advertises project-authored workflows alongside the built-ins.
- A bare or unknown `hive workflow` subcommand is now a friendly usage error (exit 64), with a structured `expected` array under `--json`.
- Full guide: https://hivecli.sh/docs/custom-workflows/

### Patrol security hardening

- A large wave of fixes to the `hive patrol` dry-run sandbox, where stubbed `gh`/`git` passthrough could be abused. Closed: auth-token leakage via passthrough and to attacker-controlled hosts; dry-run reads targeting arbitrary hosts, executing repo-configured transport/remote helpers, GPG signature helpers, or askpass, or launching a pager on TTY git reads; gh-api guard bypass via glued `-F=` fields, short flags, or absolute URLs slipping the host gate; skip-log FIFOs hanging stubs or following symlinks; replay accepting symlinked repro scripts; invalid-byte git argv crashing the stub; cache writes during dry-run.
- JSON usage/error envelopes completed across the patrol and eval command surface; scenario-basename validation enforced; stale eval reports no longer survive usage errors; hive-eval stops emitting spurious plural positional-argument errors; non-executable or unusable repro scripts now report precisely instead of as generic failures.

### Pipeline & daemon

- Task dependencies: a `depends_on` gate holds a task until its dependency completes, and dependent PRs stack on their parent's branch instead of collapsing onto main.
- PR numbers now show across all task-list surfaces (TUI, CLI, hivebox).
- The daemon assigns ids to tasks created outside `hive new`, self-heals non-token error classes, and closes a web/ auto-commit scope gap.
- Fixed: an AgentLimit false-positive that killed healthy runs; finalize now short-circuits on an already-merged PR and fast-forwards a stale rebase-duplicate worktree instead of looping on `unpushed_commits`.
- Fixed: transient duplicate rows and `ENOENT` during stage moves; tmux-mode stage completion hardened against missing terminal markers; large pastes settle before submit.
- Fixed: the babysitter skips PRs owned by an active pipeline task and gitignores dry-run scaffolding so it can't trip clean-exit review.
- `hive drop` accepts a bare numeric task id; `bin/hive new` lifts recognized options out of the task text.
- Execute holds real provider quota walls (usage-limit reached) on cooldown and retries, instead of failing the task.

### Reviewers

- Self-diagnosing review failures, transient-triage retry, and whole-class fixes; triage and fix usage-limit failures now self-heal like reviewers do.
- Codex-native reviews read codex's real answer instead of the echoed prompt template and normalize native `[Pn]` output so patrol reviews stop failing; the codex session transcript is dropped from published findings.
- Triage bare timeout/budget fallbacks aligned with `DEFAULTS`; the default review wall-clock cap is doubled to 8h.
- Findings you triage as no-fix are suppressed from re-raising on later review passes.

### Digest

- Daily shipped digest Telegram message, redesigned with a brand header, summary, per-project sections, and a stats footer. Defaults ON when Telegram is configured (dropped `bot.digest_chat_id`) and loads `~/.config/hive/.env` so the daemon digest can authenticate.

### hivebox & web

- Visual demo capture surfaced in hivebox task artifacts.
- Operator-ward device-flow logins completed in the Agents UI (codex headless device-auth); binary PTY output scrubbed so the agent-login status page can't 500; the `sanitize_url` splice bug is fixed; honeycomb favicon.

### hive-bench

- `hive bench submit` packages a completed task as a corpus producer for the hive-bench coding-agent benchmark; preflight delegates to hive-bench's canonical SecretScan.

### Integrations

- Screenote integration: connects via OAuth 2.1 / MCP, replacing the previous API-key upload.

### Dependencies

- Fixed: `concurrent-ruby` 1.3.6 → 1.3.7 (CVE-2026-54904/5/6). Dependabot/action bumps: rubocop 1.88, brakeman 8.0.5, docker/* actions v4, actions/checkout 7.

## 0.3.0

Hive in a box: one Docker container with a web UI — drop ideas from any browser and get reviewed PRs. First release that publishes the `ghcr.io/ivankuznetsov/hivebox` image.

### hivebox (alpha)

- **One-command install**: `curl -fsSL hivecli.sh/box.sh | sh` (Windows: `box.ps1`). Runs hive + a Rails web UI in a single container; all state (agent logins, config, repos, ownership) lives in a bind-mounted data dir, so the container is disposable and updating is pull + recreate. Image is multi-arch (amd64/arm64), published per release after a pre-push boot smoke, with an arm64/macOS (colima) smoke job.
- **Web UI**: idea composer with image attachments, live task grid (Turbo morph push updates — no reload flicker, scroll position preserved), task pages with artifacts/live log/diff, brainstorm Q&A answering, Approve / Diff / Drop / Recover actions, Repos page (clone via gh + the full `hive init` questionnaire), Agents page (claude/codex/gh logins), Telegram setup with real getMe validation and a test-message round trip (plus `/start` now replies and the bot ships a command menu).
- **Sign-in**: GitHub OAuth **device flow** — no client secret, no callback URL. An unclaimed box is claimed by the first successful login (taken under the config lock); everyone else is refused. Install scripts and compose/README examples bind 127.0.0.1 until ownership is pinned. The GitHub token stays in the session only — never persisted.
- **Ops**: container healthcheck hits `/health?deep=1` and fails when the daemon child is down; log tails and diffs are byte-capped with timeouts; clones run with a deadline and clean up only what they created; registered repos get ssh→https origin rewrite so the headless daemon can push.

### Pipeline

- **Claude session-limit wall** ("You've hit your session limit · resets …") now classifies as `limits_reached` with a retry-after marker the daemon heals automatically, instead of stranding the task as a plain error; the healthy-pane "Approaching session limit" warning is explicitly benign.
- **Stale-agent healer** re-enqueues a plan rerun through the dispatch queue for every 3-plan heal (including limits), instead of leaving an unhealable empty plan.
- **Schemas**: `hive-dispatch-request` v2 (requestor enum gains `healer`), `hive-drop` v2; a schema-identity test pins filename ↔ `$id` ↔ title ↔ `SCHEMA_VERSIONS` for every exported schema.

### CI

- Golden-path E2E: the full idea→PR pipeline runs in CI against a staged agent, through the real web UI, daemon, and git worktrees.
- Windows PowerShell installer harness; release workflow builds, smokes, and publishes the hivebox image.

## 0.2.4

Hive-launched claude sessions stop silently billing the operator's interactive model.

- **`claude.model` / `claude.effort`** (global or per-project config, asked at `hive init`): sessions now launch with `--model default` — Claude Code's live alias for its recommended model (Opus-class today) — instead of inheriting the operator's interactive pick (e.g. a premium long-context configuration). `inherit` restores the old behavior; any alias/full name passes through; `effort` accepts low/medium/high or keeps Claude Code's own tier. Applies to every stage including reviewers, triage, and fix phases.

## 0.2.3

Hotfix: parallel agents were being killed by another task's cleanup sweep.

- **Fixed**: the post-run orphan sweep `pkill`ed every command line matching the claude wrapper — including the tmux **server**, whose argv retains the first `new-session` command. Killing the server took down every other running agent on the box (`tmux_session_terminated` errors in parallel brainstorms/plans/reviews). The sweep now kills per-PID and never touches tmux itself; skipped PIDs are recorded in `claude-tmux-orphan-sweep.log`.

## 0.2.2

Hotfix: claude launches were failing for every subscriber whose Claude Code shows the plan-inclusion banner.

### Limits detection — false positive + hardening

- **Fix**: Claude Code's informational startup/footer line — "Included in your plan limits until Jun 22, then switch to usage credits to continue." — matched the bare `usage credits` limit pattern, so every healthy claude launch (daemon, TUI-triggered runs, CLI verbs, bot dispatches) was classified `limits_reached` and killed in seconds; the same footer text persists for the whole session, so the mid-run sentinel poll was also killing healthy running agents.
- **Hardening so chrome copy changes can't repeat this**: readiness now wins at launch (no fail-fast limit check while claude is still painting its UI; only a session that never becomes ready is classified, by the post-timeout check), and limit patterns run line-by-line behind a benign filter (plan-inclusion promos, `/status` usage hints, reset-date notices, box-drawing chrome). The documented bias: a missed wall degrades to a clean timeout the daemon healer retries; a false positive killed healthy sessions everywhere.

## 0.2.1

Patrol reviews get dramatically cheaper, the Telegram bot now confirms successes, a scrollable TUI help overlay, daemon archive-recovery, a wave of patrol-found CLI/dry-run safety fixes, and a new public website.

### Patrol — much cheaper reviews

- **Native `codex review` reviewer**: patrol PRs are now reviewed by codex's single-pass `codex review` instead of the multi-persona `ce-code-review` fan-out — far cheaper per review, via a new `kind: codex_review` reviewer. Human PRs keep the full `ce-code-review`.
- The `hive init` patrol default stays **medium** (the commit-driven `low` mode is costlier on high-velocity repos).

### Telegram bot

- The bot now **confirms successful actions**, not just failures — the daemon→bot channel relays all completions, and a misleading "exit 0" diagnosis on an empty result is fixed.

### TUI

- New **scrollable, word-wrapping help overlay**, including mouse-wheel scrolling.

### Daemon

- Fixed: a task whose finalize errored on an **already-merged PR** now archives cleanly instead of getting stuck.

### Safety & CLI hardening

- Fixed: leading `--json=true/1/yes` no longer leaks option values as commands or targets — unified JSON-flag normalization + rejection across `hive` and `hive-e2e`.
- Fixed: `hive-e2e` no longer dispatches successful commands twice, and no longer emits duplicate JSON documents.
- Fixed: the patrol/babysitter **dry-run git stub** now blocks `git grep -O`/pager abbreviations and short-option clusters, and `--textconv` / `cat-file --filters` external-command seams (with hardened, hermetic git passthrough).
- Fixed: `hive-eval` honors the scenario-root override.

### Docs & website

- New public website — **[hivecli.sh](https://hivecli.sh)**: an outcome-first landing page, curated docs, and AI-native `llms.txt` / per-page markdown. The README now links to it.

### Packaging & internals

- Bumped `sqlite3` 2.9.4 → 2.9.5.
- GitHub Release notes are now pulled from the matching `CHANGELOG.md` section.
- Hardened two flaky subprocess-timing tests (the `hv` recursion guard and a tmux pane-capture test).

## 0.2.0

A big release: smarter and cheaper autonomous **patrol**, a new PR-repair **babysitter**, a richer **Telegram bot**, and a much more resilient **daemon** — plus a wave of reliability/tmux and safety fixes.

### Patrol — smarter, cheaper, and opt-in

- **One `patrol.mode` dial** (`ultrapatrol` / `high` / `medium` / `low` / `off`) sets how aggressively patrol scans, instead of hand-tuning several knobs; `hive init` now prompts for it.
- **Opt-in by default** — a project with no patrol config stays disabled. Patrol only runs where you explicitly turn it on.
- **Per-project, parallel scans** — projects patrol independently (one scan at a time each) instead of competing for a single global slot.
- **Token spend is visible** — a `patrol` row in the TUI token-stats view shows how much patrol is costing.
- Patrol opens **ready (non-draft) PRs** and hands them straight into the review flow; added a `continuous` scheduler trigger.

### Babysitter — keeps open PRs green and mergeable

- New experimental **`hive babysit`** daemon: watches open PRs, runs bounded agent repair attempts in isolated worktrees, and hands off to a human when it can't fix one.
- **Auto-rebases green-but-behind PRs** onto their base and force-pushes, so they don't get stuck behind a moving `main` (conflicts and drafts are left alone).
- Prioritizes dirty/at-risk PRs, skips drafts, and recovers cleanly from restarts.

### Telegram bot

- Capture ideas with **photo/document attachments** and **voice notes** (auto-transcribed, with confirm / edit / discard).
- **Deterministic brainstorm answering** — the old Codex "draft-assist" path was retired.
- Thread-safe conversation handling, and no more noisy "questions waiting" pings while you're mid-answer.

### Daemon — more resilient automation

- **Self-heals** tasks whose display name never generated, and **auto-retries tasks parked on a provider usage limit** once the limit resets (cooldown + bounded retries) instead of leaving them stuck.
- **Tolerates a `hive-status` schema bump** between the long-running process and the updated CLI instead of crashing `/status` — and surfaces a clear "restart to pick up the new version" hint.
- Faster pipeline (lower inter-stage latency), plus recovery for finalize push failures and agent-loss errors.
- Queue inspection and operator feedback: `hive daemon queue`, dispatch-result notices back to the Telegram bot, at-most-once request claims, and bounded result pruning.
- Added human-readable task ids/display names alongside slugs, and an Archive view that hides old archived tasks.

### Reliability & tmux hardening

- Brainstorm and review runs now **fail fast with a clear marker when a tmux session vanishes or a pane is unreadable**, instead of hanging.
- Reviewer tmux resilience, with room for long (1–2h) reviews.
- Heals orphaned `REVIEW_WORKING` markers left by a signal/kill so review can retry.

### Safety & CLI hardening

- Patrol/eval **dry-run is locked down**: the `git`/`gh` stubs refuse mutating, remote, browser/pager, and implicit-write commands; `hive-eval` is confined to safe scenario names and rejects bad CLI usage.
- `--json` (and `--json=true`) usage errors always emit the JSON envelope with the documented exit code.
- TUI subprocess/log artifact caps enforced; Asciinema v3 casts honor the requested terminal size.

### Install & packaging

- The gem now ships its dry-run stubs; the bash installer's `hv` wrapper works correctly; `hv` no longer accidentally launches Apache Hive from a fallback path (with a portable macOS path fallback).

### Other fixes & internals

- **TUI**: terminal-resize handling, cursor preserved across refreshes, faster startup.
- Dispatch/result-queue edge cases hardened; raised the Faraday dependency to the patched security version.
- **Docs/tests**: changelog compiled from fragments, Discord community link, test tmpdir-leak cleanup (`rake test:clean_tmp` + a `HIVE_WORKTREE_BASE` override), `QueueCommand` extraction, and refreshed install/release/wiki docs.

## 0.1.11

- Added the experimental `hive babysit` PR repair daemon. It can inspect repository projects, classify PR health, run bounded agent repair attempts in PR worktrees, record structured babysitter state/logs, and preserve dry-run and human-handoff paths.
- Added `hive patrol`, an opt-in repository patrol that maps feature slices, asks the configured agent to review them, fixes validated findings in isolated worktrees, and opens draft PRs for passing fixes.
- Added the OpenClaw skill bundle and install docs, including coverage for `hive babysit`, `hive patrol`, daemon/bot/init/admin-safe flows, and collision-safe `/hive-new` / `/hive-approve` names.
- Added daemon/bot queue inspection and operator feedback surfaces: `hive daemon queue`, dispatch-result notices back to the Telegram bot, at-most-once request claims, and bounded result pruning.
- Changed daemon dispatch behavior around request queues, restart baselines, per-child timeouts, capacity gates, and PR-merge archive handoff so queued work survives restarts more predictably.
- Changed brainstorm Q&A recovery so the daemon waits for all questions to be answered before resuming, the bot creates missing answer slots instead of stranding the task, and `hive status --json` exposes `unanswered_questions`.
- Fixed llm-wiki post-commit hook execution by sanitizing inherited Git hook environment, preventing hook-side QMD/plugin repository checkouts from dirtying unrelated Hive worktrees.
- Fixed review/fix recovery contracts so dirty-worktree and failed-status-check states are surfaced as manual-only when automation cannot safely fix them.
- Fixed the TUI cursor so the selected slug is preserved across snapshot polls and row reordering.
- Fixed dispatch-request and result-queue edge cases around schema-valid claim sidecars, stale-claim recovery, timeout/killed child reporting, queue CLI JSON errors, spawn-failure claim release, and result backlog expiry/capping.
- Fixed babysitter follow-up issues found during review: missing OpenClaw skill coverage, init-answer drift guards, logger fallback handling, coverage-gate gaps, and Brakeman false-positive documentation for argv-form GitHub commands.
- Updated release/install docs and wiki coverage for the current install surface, Homebrew/AUR/bash channels, daemon queue, babysitter, patrol, OpenClaw, and llm-wiki hook behavior.
- Recorded operational learnings for daemon autostart, tmux-capture marker footguns, silent stage rename drift, and review auto-commit policy.
- Bumped RuboCop from 1.86.2 to 1.87.0 and `actions/upload-artifact` from v4 to v7.

## 0.1.10

- Fixed the daemon stranding already-answered `needs_input` tasks across a restart. The `[project, slug] → state_file_mtime` baseline map (consulted by `Policy#decide_edit` to detect fresh user input) was in-memory only, so a pre-restart answer never looked "newer than baseline" on first sight and got skipped on every tick forever until you manually `touch`ed the state file. Baselines now persist to `daemon_dispatch_baselines.json` under the state home (atomic write + fail-closed load + sibling-flock + orphan-tmp sweep), reload on startup, and prune to the live task set each successful tick — bounded to the projects in the snapshot so a per-project status error doesn't wipe its baselines.
- Fixed features getting stuck for hours at `8-finalize` with `:error reason=dirty_worktree` whenever a stage left orphan edits behind (e.g. a `6-review` fix agent that wrote one more file after the per-pass auto-commit window closed). Promoted "the worktree is clean at stage exit" to a stage-level invariant enforced once in `Hive::Stages::Base.with_stage_events`: residue is auto-committed as `chore(<stage>): commit residual worktree changes` with `Hive-Auto-Commit: residue` trailers, gated by the existing `review.fix.auto_commit.scope_check` allowlist and skipped for the four pause markers. `Finalize.verify_state!` re-runs the same check on entry so any feature already stuck pre-merge self-heals on its next tick. The bot routes dirty-worktree `:error` markers as manual-only, stopping the Autofix retry loop.

## 0.1.9

- Fixed every tmux-mode Claude launch failing with `claude_launch_failed` after a Claude Code TUI update moved the input caret to the end of a context-prefixed line (`<cwd> <git-status>  ❯`) with a hint footer beneath it. The readiness check now detects the caret at the start or end of its line and tolerates the footer, so brainstorm/plan/review stop timing out. Hardened to be robust to future caret repositioning.
- Fixed the Telegram bot `/idea` flow giving no feedback on success: capturing an idea through the silent project picker now sends an acknowledgement.

## 0.1.8

- Fixed a crash in v0.1.7's update flow: the daemon's update-check log events (`update_available`, `update_check_no_result`, `update_check_error`, `update_nudge_no_command`) and the bot's (`update_nudge_pushed`, `update_nudge_error`) were never added to the loggers' closed event enums, so a real daemon raised `ArgumentError` on its first "behind" tick and crashed (and the bot logged a spurious fatal). The events are now registered, with regression tests that exercise the real loggers.

## 0.1.7

- Added a daemon-driven update flow: the daemon checks the latest GitHub release (~daily) and, when you're behind, surfaces a nudge with the exact update command in the TUI footer and as a one-time Telegram bot push (brew/AUR/install.sh are nudge-only — hive never drives your package manager). Opt out via `update.check` / `update.auto` in the global config.
- `hive daemon status --json` now reports `current_version` and `update_nudge` so agents can detect an available update too.

## 0.1.6

- `install.sh` now manages the qmd wiki indexer; `hive doctor` gained a managed-qmd probe and clearer failure reporting.
- Fixed `hive tui` footer ordering (hints render before token counters).

## 0.1.5

- Fixed `yay -S hive-bin`: the AUR `package()` aborted on an invalid `gem install --ignore-dependencies=false` flag — the published package never actually installed. Caught by the new real-install CI matrix.
- Fixed the `hv` shim on Homebrew and AUR: it pointed at the gem's bash `bin/hv` via a Ruby binstub that can't run it; `hv` is now a symlink to the working `hive` wrapper.
- Fixed Homebrew install-channel detection: the marker is now written under `<prefix>/share/hive` (was `libexec/share`, which is never linked) so `hive update` recognizes brew installs.

## 0.1.4

- Fixed AUR publishing: accept the `aur.archlinux.org` SSH host key on first connect so the `hive-bin` push no longer fails host-key verification.

## 0.1.3

- Fixed AUR publishing: install `ruby-erb` in the Arch publish container so `packaging/render.rb` can `require "erb"`.

## 0.1.2

- Finished Homebrew tap + AUR (`hive-bin`) publishing — previously only `install.sh` worked. A `vX.Y.Z` tag now fans out from `release.yml`: the signed `hive-cli` gem → `repository_dispatch` to the `ivankuznetsov/homebrew-hive` tap (renders `Formula/hive.rb` from the repo's ERB template), plus an `aur-publish` job that cosign-verifies the gem (pinned identity), renders the `PKGBUILD`, generates `.SRCINFO` via `makepkg --printsrcinfo`, and pushes the AUR `hive-bin` package.
- Added `packaging/render.rb` — one fail-closed ERB renderer shared by the formula and PKGBUILD so they can't drift on the substituted version/sha; removed the stale `packaging/aur/.SRCINFO.template`.
- Added the `docs/RELEASING.md` runbook; recorded the design in ADR-032.
- Fixed the Homebrew-tap dispatch (`client_payload` must be a JSON object, not a string — it was rejected with HTTP 422) and made the tap-notify step non-fatal so it can't block the AUR publish.

## 0.1.1

- Release-pipeline shakedown; no user-facing changes.

## 0.1.0

Initial public release of Hive — the folder-as-agent pipeline. The entries below are the accumulated 0.1.0 changes, kept in their original categorized form; releases from 0.1.1 on use the flat per-version style above.

### Added — token usage stats

- Hive now records one SQLite `token_usage` row for each hive-driven agent spawn that emits structured usage, with per-agent/profile extractors for Claude, Codex, and Pi. `hive tui` shows scoped token aggregates in the footer and opens a full-screen token matrix with `T`.

### Changed — task drop

- Added `hive drop <slug>` and rebound `hive tui` Shift+X to hard-delete the focused task: kill the active agent, remove active-stage task folders, logs, worktree, branch, locks, and close any draft PR best-effort. This is irreversible and has no confirmation prompt beyond the Shift+X gesture.
- Breaking TUI binding change: Shift+X no longer drops `(missing)` project registry entries. Use `hive forget NAME` or `hive prune` from the shell for registry cleanup.

### Changed — `7-artifacts` pipeline stage inserted

- Inserted `7-artifacts` between `6-review` and the existing finalize/done stages. The new stage owns per-task artifact capture (demo reels for visualisable work, PR-description refreshes for backend-only work) before the PR is marked ready. This commit ships the registry plumbing (U1); the stage runner lands in a follow-up unit.
- Renumbered the pipeline tail: `7-finalize` → `8-finalize`, `8-done` → `9-done`. The full pipeline is now `1-inbox`, `2-brainstorm`, `3-plan`, `4-execute`, `5-open-pr`, `6-review`, `7-artifacts`, `8-finalize`, `9-done`.
- Added the `hive artifacts <slug>` workflow verb (`6-review` → `7-artifacts`) and a matching grid-mode `A` keybinding in the TUI (capital so it doesn't collide with `a` for archive).
- Extended `hive migrate`'s `STAGE_RENAMES` to relocate in-flight `7-finalize/<slug>` → `8-finalize/<slug>` and `8-done/<slug>` → `9-done/<slug>` on upgrade. Existing projects must run `hive migrate` before resuming task work; daemon-driven projects should restart the daemon after migration so the in-memory `archive` verb template re-derives from the new layout.
- Schema enums in `hive-status`, `hive-stage-action`, `hive-approve`, `hive-findings`, and `hive-run` widened in place to include the new stage names; consumers pinned to the old enum sets must update.

### Added — install channels

- Hive now ships as a rubygem (`hive-cli`) attached to each GitHub Release, signed with cosign keyless attestation. The Homebrew tap formula, AUR `hive-bin` template, and `install.sh` all download the same signed `.gem` and `gem install` it. The earlier tebako/static-binary build path was dropped — Hive already requires Ruby 3.4 on the user's machine, so bundling a Ruby runtime into a single binary added build-pipeline complexity for no user gain.
- Added XDG path resolution, install-channel markers, `hive update`, `hive uninstall`, and the `hv` fallback entrypoint for Apache Hive PATH collisions.
- `hive init` now writes the per-user daemon service unit and asks whether to enable and start it immediately.
- The bash installer now installs Hive's managed QMD wiki indexer from `@tobilu/qmd` into `${XDG_DATA_HOME:-~/.local/share}/hive/qmd` when npm is available, links `qmd` beside the Hive binary, and `hive doctor` reports missing/broken QMD non-fatally with native ABI rebuild guidance.

### Added — `hive tui` manual steering

- `hive tui` now binds `s` to open the focused task in the configured development agent inside its feature worktree, mark it `MANUAL_STEERING` so automation skips it, and archive it under `archived-manual/` when the agent exits.

### Added — global Claude launch mode

- Added top-level `claude.mode` with values `tmux` and `headless`. Fresh projects default to `tmux`, and missing keys in existing projects are treated as `tmux`; switch modes by editing `.hive-state/config.yml` and restarting the stage.
- Every Claude-driven stage now goes through the shared launcher. `2-brainstorm`, `3-plan`, `4-execute`, `5-open-pr`, `6-review` sub-spawns, `7-artifacts`, and `8-finalize` honor `claude.mode`; stages configured with non-Claude agents keep their existing headless path.
- In `claude.mode: tmux`, Claude reviewer passes in `6-review` run sequentially inside one shared tmux session for the pass. Non-Claude reviewers still spawn headless.
- `hive init` now prompts for `claude.mode` instead of the brainstorm-only runtime. Legacy `brainstorm.runtime` remains readable for one release as a deprecated 2-brainstorm fallback, and `hive doctor` warns when it is still present.
- `hive doctor` reports a `claude/tmux` dependency row whenever `claude.mode: tmux`; missing or too-old tmux is a hard failure, with no silent fallback to headless.
- **Daemon / service hosts MUST set `claude.mode: headless`** in `.hive-state/config.yml`. The new `tmux` default expects an attached terminal for the trust-prompt and ready-prompt detection; daemons run without a TTY and would hard-fail on every Claude-backed task otherwise (auto-fallback to headless is explicitly out of scope — see ADR-030 Consequences). Existing daemon-driven projects that previously relied on `brainstorm.runtime: headless` MUST migrate to `claude.mode: headless` before the legacy `brainstorm.runtime` fallback is removed (see deprecation note below).
- **Legacy env-var prefix `HIVE_BRAINSTORM_TMUX_*` is deprecated.** The new `HIVE_CLAUDE_TMUX_*` prefix is preferred for every tmux tuneable (`READY_WAIT_TIMEOUT_SEC`, `POLL_INTERVAL_SEC`, `SENTINEL_INTERVAL_SEC`, `CLAUDE_READY_WAIT_TIMEOUT_SEC`, etc.). The legacy `HIVE_BRAINSTORM_TMUX_*` fallback is kept readable for ONE release and will be dropped in the NEXT minor release after this entry. Update any service unit, CI step, or `direnv` env that sets the legacy form.

### Changed — PR-first workflow

- Added `5-open-pr`: after `4-execute`, hive pushes the feature branch and opens a draft GitHub PR before autonomous review starts.
- Renumbered the pipeline to `1-inbox`, `2-brainstorm`, `3-plan`, `4-execute`, `5-open-pr`, `6-review`, `7-finalize`, `8-done`.
- Repurposed `7-finalize` from "open PR" to final wrap-up: verify clean/pushed state, refresh the PR body, write `summary.md`, and mark the draft PR ready for review.
- `6-review` now mirrors each reviewer and escalations file to the open PR as a PR-level comment. Local `reviews/*.md` files remain authoritative; GitHub publish failures warn and do not block the loop.
- Added `hive migrate` to opt-in rename in-flight old-stage task folders (`5-review` → `6-review`, `6-pr` → `7-finalize`, `7-done` → `8-done`).

### Added — `hive tui` new-idea editing and paste support

- The `n` new-idea prompt now supports cursor-aware title editing: Left/Right, Home/End, Ctrl+A/Ctrl+E, Backspace, Delete, and insertion at the cursor.
- TUI input now uses a Hive-owned paste-aware Bubble Tea runner that drains complete raw terminal chunks. Plain multi-character paste and bracketed paste both reach the prompt, with CR/LF/TAB normalized to spaces for the single-line `hive new` title.
- The e2e harness gained `tui_keys` `paste: true` for sending one literal text chunk through tmux; `tui_new_idea_editing` covers paste plus mid-title correction before submit.

### Changed — `hive tui` render layer migrated from curses to Charm bubbletea + lipgloss

- The TUI now boots a [bubbletea-ruby](https://github.com/marcoroth/bubbletea-ruby) MVU runtime and renders frames with [lipgloss-ruby](https://github.com/marcoroth/lipgloss-ruby) styles. `KeyMap` is the single source of truth for keystroke→action mapping, returning typed `Hive::Tui::Messages::*` values that flow through `Hive::Tui::Update.apply(model, msg) → [model, cmd]`. Views are pure functions of the frozen Model — no I/O — which makes layout regressions reproducible in unit tests.
- **Curses backend removed.** The `curses` gem is no longer a runtime dependency; the legacy `Hive::Tui::Render::*` modules and the `Hive::Tui.run_curses` entry point are deleted. `HIVE_TUI_BACKEND=curses` raises `Hive::InvalidTaskPath` (exit 64) with a removal-pointer message rather than silently falling back to charm.
- **What didn't change:** every keystroke binding, every workflow-verb shell-out, every flash message, every JSON contract on adjacent CLI surfaces. The Thor surface (`hive tui`, `--json` rejection with EX_USAGE 64, non-tty USAGE-64 alignment) is identical. `Hive::Tui::Snapshot` / `Hive::Tui::StateSource` / `Hive::Tui::Help::BINDINGS` / `Hive::Tui::SubprocessRegistry` are untouched.
- **Visual quality:** Lipgloss handles color/bold/reverse and adapts to the detected color profile. Grid action-key colors (cyan for `agent_running`, yellow for error/recover, green for `ready_*`) carry over verbatim. Help overlay renders inside a Lipgloss NORMAL border with rounded padding.
- **Test ergonomics gap (documented):** lipgloss-ruby v0.2.2 strips ANSI when stdout is not a tty and exposes no force-color escape hatch. View tests therefore pin layout/text content; visual styling is validated by manual dogfood. Tracked in `docs/solutions/2026-04-27-charm-bubbletea-api-gaps.md`.

### Breaking changes

- **Stage directories renumbered: `5-pr` → `6-pr` and `6-done` → `7-done`.** Position 5 is reserved for the upcoming `5-review` stage (CI-fix → multi-reviewer → auto-triage → fix → browser-test loop, per `docs/plans/2026-04-25-001-feat-5-review-stage-plan.md`). `5-review` is NOT yet present — `Hive::Stages::DIRS` currently has a numeric gap at position 5 that fills when U9 ships.

  **Upgrade path for users with active hive tasks at the time of upgrade:**

  ```sh
  cd <project-root>
  # If a task is in 5-pr/, move it to 6-pr/
  if [ -d .hive-state/stages/5-pr ]; then
    mkdir -p .hive-state/stages/6-pr
    mv .hive-state/stages/5-pr/* .hive-state/stages/6-pr/ 2>/dev/null || true
    rmdir .hive-state/stages/5-pr
  fi
  # If a task is in 6-done/, move it to 7-done/
  if [ -d .hive-state/stages/6-done ]; then
    mkdir -p .hive-state/stages/7-done
    mv .hive-state/stages/6-done/* .hive-state/stages/7-done/ 2>/dev/null || true
    rmdir .hive-state/stages/6-done
  fi
  ```

  `hive init` on fresh projects creates the new directory layout automatically. The migration is one-shot per project; no auto-migration helper ships in v1.

### Added — `hive tui` (live dashboard + keystroke-driven workflow)

- `hive tui` — full-screen, modal, curses-based dashboard over `hive status`. Polls `Hive::Commands::Status#json_payload` in-process at 1 Hz from a non-daemon background thread; renders rows grouped by `TaskAction` action label across registered projects; dispatches workflow verbs as fresh subprocesses on single-key keystrokes. Human-only — `hive tui --json` is rejected with EX_USAGE (64); agent-callable surfaces stay on `hive status` and the typed verbs.
- Four modes — status grid (default), findings triage (Enter on `review_findings`), agent log tail (Enter on `agent_running`), help overlay (`?`); plus a filter prompt (`/`, Esc clears, Enter commits) and per-project scope (`1`–`9`, `0` clears).
- Verb keystrokes: `b` brainstorm, `p` plan, `d` develop, `r` review, `P` (capital) pr, `a` archive. Pressing a verb on an `agent_running` row whose `claude_pid_alive` is true flashes a hint instead of dispatching, pre-empting `ConcurrentRunError` (exit 75); when the PID is provably dead the verb dispatches normally so `Hive::Lock` can reap the stale lock.
- Findings triage: per-`Space` toggles via `hive accept-finding` / `hive reject-finding` use a quiet subprocess flavor (no screen tear-down) so the screen never flashes; `d` dispatches `hive develop --from 4-execute` via full-screen takeover. Bulk `a` / `r` (rebound from grid-mode archive/review) accept/reject every finding at once. After every toggle the document reloads and the cursor relocates by `(severity, title-prefix)` to handle concurrent rewrites.
- Agent log tail: tails the latest `<state>/logs/<slug>/*.log` file via non-blocking reads driven by the render loop's 100 ms input timeout. Handles inode rotation (re-open new inode), truncation (rewind cleanly), and transient `Errno::*` (swallow + retry). Footer shows `[stale: claude_pid no longer alive]` when the producing agent's PID is dead.
- Terminal hostility: `at_exit` cleanup + SIGHUP cooperative cancellation are installed BEFORE the first `Curses.init_screen` so a crash during init still restores the terminal. Resize handled via injected `KEY_RESIZE` (no Ruby `Signal.trap("WINCH")` per ruby/curses#9). Ctrl+Z suspend / SIGCONT resume rely on ncurses' default handlers. SubprocessRegistry holds the in-flight pgid (or `:placeholder` sentinel) under a `Monitor` so the trap path can reap subprocesses without racing the spawn.
- New runtime gem: `curses ~> 1.6` (production block of `Gemfile`). Stdlib-extracted, ruby-core maintained; ships every primitive needed (`def_prog_mode`/`reset_prog_mode`/`endwin` for subprocess takeover, `KEY_RESIZE` injection, automatic SIGTSTP/SIGCONT). Containerised consumers need `apk add ncurses-dev` / `apt install libncurses-dev`.
- New typed exception: `Hive::NoLogFiles < Hive::Error` (exit code 64 USAGE) — raised by `LogTail::FileResolver.latest` when a slug's log directory contains no `*.log` files yet.

- Five workflow verbs `hive brainstorm`, `hive plan`, `hive develop`, `hive pr`, `hive archive` — each is a single Thor command that resolves a slug or folder, then either runs the target stage's agent (already at target) or promotes from source-stage and runs the target's agent. `--from STAGE` is the idempotency assertion: a retry after a successful advance fails with `WRONG_STAGE` (4) instead of silently advancing twice. `--json` emits a single `hive-stage-action` v1 envelope (success and error). `archive` is idempotent at 6-done.
- `Hive::Workflows` module — single source of truth for the verb→source/target stage map. `VERBS` hash plus `verb_advancing_from(stage_dir)` and `verb_arriving_at(stage_dir)` reverse lookups. `Hive::Commands::StageAction`, `Hive::TaskAction`, `Hive::Commands::Approve`, and `FindingToggle` all delegate so renaming or adding a verb is a one-file change.
- `Hive::TaskAction` — `(Task, Marker)` → action classifier with stable `key` (per `Hive::Schemas::TaskActionKind`), human `label`, and copy-paste `command` for the next step. Powers `hive status` action grouping, the `tasks[].action` JSON field, and `next_action.command` emissions in `hive run`, `hive approve`, `hive accept-finding`, and `hive reject-finding`.
- `Hive::Commands::StageAction` — promote-or-run dispatcher backing the workflow verbs.
- `Hive::Schemas::TaskActionKind` self-derived closed enum mirroring `NextActionKind` — pinned by `test/unit/exit_codes_test.rb`.
- `schemas/hive-stage-action.v1.json` published — draft 2020-12 oneOf success/error.
- `Hive::Commands::Approve#initialize` and `Hive::Commands::Run#initialize` accept a `quiet:` kwarg. When set, the inner command does its work but emits no stdout/stderr (errors still raise typed). Used by `StageAction` so a workflow-verb invocation produces a single unified envelope rather than mixed Approve+Run output.
- `hive findings TARGET [--pass N] [--project NAME] [--json]` — list GFM-checkbox findings in `<task>/reviews/ce-review-NN.md` (latest pass by default; `--pass N` for a specific pass). Read-only; emits text table or single-line `hive-findings` JSON document. Schema version 1.
- `hive accept-finding TARGET [ID...] [--severity S] [--all] [--pass N] [--project NAME] [--json]` — tick `[ ]` → `[x]` on review findings so they are re-injected into the next implementation pass via `Hive::Stages::Execute#collect_accepted_findings`. Selectors (positional IDs, `--severity high|medium|low|nit`, `--all`) are unioned. Atomic write (tempfile + rename), task-lock'd, audit-trail commit on hive/state. Idempotent — already-accepted findings are no-ops and excluded from the `changes` array.
- `hive reject-finding TARGET [ID...] [--severity S] [--all] [--pass N] [--project NAME] [--json]` — inverse: tick `[x]` → `[ ]`. Same selectors, same locking, same idempotency.
- `Hive::Findings` module — parser + writer for review files. `Document` exposes a `findings` list (1-based stable IDs in document order), `summary` (total / accepted / by_severity counts), `toggle!(id, accepted:)`, and atomic `write!`. `review_path_for(task, pass:)` resolves the latest or named-pass review file.
- `Hive::TaskResolver` (`lib/hive/task_resolver.rb`) — extracted slug-or-folder resolution shared between `approve`, `findings`, `accept-finding`, and `reject-finding`. `Hive::Commands::Approve` now delegates to it; future commands can compose on the same resolver.
- `Hive::NoReviewFile` (exit 64 / USAGE) and `Hive::UnknownFinding` (exit 64 / USAGE) typed exceptions; `UnknownFinding` carries the offending `id` for the JSON error envelope.
- `Hive::NoSelection` (exit 64 / USAGE) typed exception for `accept-finding` / `reject-finding` invocations with no IDs, no `--severity`, and no `--all`. Distinct from `InvalidTaskPath` so callers branching on `error_kind` get a precise signal.
- `Hive::Schemas::ErrorEnvelope.build(schema:, error:, error_kind:, extras:)` helper — single source for the JSON error envelope shape. Used by the `findings` and `accept-finding` / `reject-finding` commands; per-error structured fields (`candidates` / `id` / `path` / `stage`) are pulled from the typed exception automatically.
- `Hive::RollbackFailed` (exit 1 / GENERIC) typed exception. Raised by `Hive::CommitOrRollback.attempt!` when the rollback step itself fails after a commit failure. Distinct from a plain `Hive::Error` so the JSON envelope's `error_kind: "rollback_failed"` lets agents distinguish "commit failed but rollback succeeded → fs/git pristine, safe to retry" from "commit failed AND rollback failed → fs/git may be inconsistent, manual intervention needed before retry."
- `Hive::CommitOrRollback.attempt!` module helper — consolidates the dual-rescue rollback pattern shared by `Hive::Commands::Approve#attempt_rollback!` and `Hive::Commands::FindingToggle#rollback_review_change!`. Both call sites now reduce to caller-specific message-builder lambdas plus the helper. Pre-condition checks (e.g. approve's "source path now exists, can't roll back") stay in the caller; the helper owns the rescue + re-raise contract.
- Fenced-code-block awareness in `Hive::Findings::Document#parse_lines`. Triple-backtick (and triple-tilde) fence tracking means `## High` or `- [ ] foo` *inside* a fenced block (e.g. example output in justification) won't accidentally register as a heading or finding. Closes a latent bug that would have surfaced when the reviewer prompt template emits fenced examples.

### Changed (workflow-verbs round)

- `Hive::TaskAction` carve-outs for `:agent_working` (always emits `agent_running` action with `command: nil`) and `:execute_stale` (now emits `findings` command, not `develop` — running develop on a stale execute task would refuse on the non-terminal marker and loop). Closes the agent-loop bug where `hive status --json` advertised a runnable command for a state that was actively running or in recovery.
- `Hive::Commands::Approve#json_next_action` at the final stage now emits `{ kind: NO_OP, reason: "final_stage" }` instead of `kind: RUN` with `hive archive <slug>`. After advancing INTO 6-done, archive's job is done; emitting it again would loop the Done agent.
- Workflow-verb commands emitted by `TaskAction#command` ALWAYS include `--from <stage>` (was: only when `stage_collision` flag was true). The disambiguator is the idempotency lever; emitting it unconditionally means status-suggested commands and `hive run --json` `rerun_with` strings are retry-safe by default.
- After a successful `hive approve --to <stage>`, the `next_action.command` and text-mode `next:` hint name the verb whose target IS the new stage (e.g. `hive plan <slug> --from 3-plan` after advancing into 3-plan), not the verb that advances OUT of it. Calling that command hits StageAction's at-target branch and runs the new stage's agent, which is what you want next; the "advance out" verb would refuse on the non-terminal marker.
- `Hive::Commands::FindingToggle`'s `next_action.command` and text-mode `next:` hint now include `--from <stage>` for the same reason.

### Changed (round 3)

- `hive-findings` and `hive-approve` schemas both gained `rollback_failed` in the `error_kind` enum.
- Tempfile naming in `Hive::Findings::Document#write!` and `Hive::Lock.update_task_lock` now appends `SecureRandom.hex(4)` to the `Process.pid` suffix. Defends against PID reuse-after-crash leaving a stale tempfile that a new process with the same PID would collide with.
- `schemas/hive-findings.v1.json` — published JSON Schema (draft 2020-12) with `oneOf` over `ListPayload`, `TogglePayload`, and `ErrorPayload`. `test/unit/schema_files_test.rb` pins required-key sets and the `error_kind` enum against the producer's emission.
- `hive approve TARGET [--to STAGE] [--from STAGE] [--project NAME] [--force] [--json]` — agent-callable equivalent of shell `mv <task> <next-stage>/`. Resolves bare slugs across registered projects; validates terminal-marker on forward auto-advance; records a `hive/state` commit on each move; emits a `hive-approve` JSON document on success AND a structured error envelope on every failure path under `--json` (schema_version 1).
- `Hive::Stages` — single source of truth for the stage list (`DIRS`, `NAMES`, `SHORT_TO_FULL`, `next_dir`, `resolve`, `parse`). `GitOps`, `Status`, `Run`, and `Approve` all delegate to this module so adding a 7th stage is a one-file change.
- New typed exceptions: `Hive::AmbiguousSlug` (carries structured `candidates`), `Hive::DestinationCollision` (carries `path`), `Hive::FinalStageReached` (carries `stage`). Each surfaces extra fields in the JSON error envelope so callers don't parse stderr prose.
- `Hive::Schemas::NextActionKind::RUN` — new kind emitted by `hive approve --json` so an agent can chain to `hive run <new_folder>` deterministically. Closed-enum membership pinned in `test/unit/exit_codes_test.rb`.
- `Hive::Schemas::NextActionKind::APPROVE` — `hive run --json` now emits `kind: 'approve'` (was `kind: 'mv'`) for `:complete` and `:execute_complete` markers, with a `command: "hive approve <slug> --from <stage>"` field. `MV` stays in the closed enum (per the additive-only policy) but the canonical agent action is now `hive approve`. Back-compat `from` / `to` fields are kept on the next_action object.
- `schemas/hive-approve.v1.json` — published JSON Schema (draft 2020-12) for external consumers. Validates the success payload, the structured error envelope, and the closed `NextAction.kind` enum. `Hive::Schemas.schema_path("hive-approve")` resolves the absolute path. `test/unit/schema_files_test.rb` pins the schema file's required-key set against the producer's emission so drift fails at test time.
- `.hive-state/.gitignore` — `hive init` now bootstraps a gitignore at the .hive-state root that excludes `stages/*/*/.lock`, `stages/*/*/.lock.tmp.*`, `stages/*/*/*.markers-lock`, and `.commit-lock`. Per-task lock metadata (PIDs, process_start_time) is per-process and was previously committed in hive/state on every `hive run` and `hive approve`.
- Symlink hardening on `hive approve`: `resolve_target` realpaths the resolved folder before passing it to `Task.new`, so a slug-named symlink at `.hive-state/stages/<N>/<slug>` pointing to `/tmp/leaked` is rejected at the PATH_RE check instead of being moved as a symlink.
- TOCTOU robustness in `move_task!`: a non-hive process that `mkdir`s the destination between the pre-check and the rename surfaces as `Hive::DestinationCollision` (typed) instead of a bare `Errno::ENOTEMPTY` trace. Direct `File.rename` is wrapped in a rescue for `ENOTEMPTY` / `EEXIST` / `EISDIR`; cross-device moves fall back to `cp_r` + `rm_rf`.
- `Hive::InternalError` (exit 70 / SOFTWARE) — catch-all wrapper for non-`Hive::Error` exceptions in `Approve#call`. With `--json`, a structured envelope is still emitted (no Ruby trace on stderr); without `--json`, the user sees a friendly `hive: internal error: <Class>: <msg>` and a stable exit code instead of an unhandled trace. Closes the silent-failure path where Errno::ENOSPC, SystemCallError, or an unhandled Open3 failure escaped the rescue boundary.

### Changed (P3 hardening — round 3)

- `Approve#record_commit_or_rollback!` rescue narrowed from `StandardError` to `Hive::Error, SystemCallError`. The previous broad rescue was swallowing typed errors (e.g. `Hive::GitError` exit 70) and rewrapping them as generic exit 1, erasing the contract code. Typed errors now re-raise unchanged after rollback so wrappers see the documented exit code.
- `Approve#attempt_rollback!` (extracted) now wraps the rollback `FileUtils.mv` in its own rescue. If the rollback itself fails (cross-device, EACCES, source re-created), both the original commit failure AND the rollback failure surface in one combined message — operator has the full picture for manual recovery.
- `Approve#cross_device_move!` (extracted from `move_task!`) cleans up the partial destination if `cp_r` fails mid-flight (ENOSPC, EACCES on a child file, EIO). Previously a partial copy plus an intact source could leave the next retry hitting a phantom collision with no indication of where the real data lived.
- `Approve#cleanup_orphan_task_lock` now rescues only `Errno::ENOENT` (expected — concurrent process beat us to delete). Other I/O errors propagate so the rollback path runs.
- `Approve#source_has_tracked_files?` now checks `Open3` exit status. A failed `git ls-files` (corrupt index, missing repo) was previously interpreted as "no tracked files," silently skipping the source-side `git add` and leaving a tree-vs-index drift. Now raises `Hive::GitError`.
- `Hive::Stages.parse(dir)` validates `DIRS.include?(dir)` before splitting. `parse("99-foo")` returns nil instead of `[99, "foo"]` so a hand-constructed stage string can't silently slip past validation downstream.
- `Hive::Stages.next_dir(idx)` raises `ArgumentError` for non-integer or `idx < 1` instead of silently returning whatever `DIRS[idx]` gives. Off-by-one bugs surface at the call site rather than as an indistinguishable nil "final stage".
- `Hive::GitOps::STAGE_DIRS` and `Hive::Commands::Status::STAGE_ORDER` aliases removed; both classes now reference `Hive::Stages::DIRS` directly. Closes the half-migration smell flagged in review.

### Added — round 3

- `wiki/modules/stages.md` — wiki page for the new `Hive::Stages` module per the project's convention of one wiki page per code module.
- `test/unit/stages_test.rb` — pins `DIRS` / `NAMES` / `SHORT_TO_FULL` shapes, `resolve` / `next_dir` / `parse` semantics, and the new validation behavior (parse rejects unknown stages, next_dir raises on out-of-range).
- `test/integration/run_approve_test.rb` — rollback-on-commit-failure test (uses a real `pre-commit` hook that exits 1, asserts mv reverses + GitError exit code 70 surfaces) and a paired rollback-also-fails test for the manual-recovery message branch. Plus `--from` mismatch JSON error envelope test, full per-candidate key-set pin on `AmbiguousSlug`. The tautological `test_to_accepts_every_short_stage_name` was deleted (covered by the new unit tests in `test/unit/stages_test.rb`).
- `--from STAGE` on `hive approve`: asserts the task is at the named stage before advancing. Mismatch raises `WrongStage` (4). Idempotency lever for retry loops — a network blip mid-call no longer silently double-advances on the next attempt.
- `bin/hive` rewrites `<cmd> --help` / `<cmd> -h` into `help <cmd>` before Thor dispatch, so the convention agents try first works.
- Thor `enum:` constraint on `--to` and `--from`: invalid stage values fail at parse time before any code in `Approve` runs, and the valid set is listed in `hive help approve` output.

### Changed

- `hive approve` JSON schema: split combined `from_stage` / `to_stage` strings into `from_stage` (bare) + `from_stage_index` + `from_stage_dir` (combined), mirroring `hive-run`'s `stage` / `stage_index` shape. Added `ok`, `noop`, `direction`, `forced`, `from_marker`, `next_action` fields. Schema version stays at 1 (no consumers in the wild yet).
- `hive approve` git commit is now slug-scoped: `git add -A stages/<src>/<slug> stages/<dst>/<slug>` instead of staging the whole parent stage directories. Sibling-task changes in the same stage no longer get swept into the approve commit, fixing audit-trail corruption.
- `hive approve` is now atomic-with-rollback: `with_commit_lock` is acquired BEFORE the move so contention surfaces before any filesystem mutation; `with_task_lock` blocks concurrent `hive run` on the same task; if the commit fails (pre-commit hook abort, lock timeout mid-flight, etc.) the move is reversed and the original error is wrapped in `Hive::Error` so fs and git don't diverge.
- `hive approve` raises `Hive::FinalStageReached` (exit 4, `WRONG_STAGE`) instead of bare `Hive::Error` (exit 1) when asked to advance past `6-done`. Distinguishes "no further stage" from a recoverable destination collision (still exit 1) so retry loops can branch deterministically.
- `hive approve` raises `Hive::AmbiguousSlug` when a bare slug exists at multiple stages within one project (was: silent lowest-stage-wins). The previous heuristic was wrong for the partial-failure-recovery case where the lower stage is the stale leftover. Pass an absolute folder path or `--to` to disambiguate.
- `hive approve --to <current-stage>` is now a clean no-op (exit 0, `noop: true` in JSON) instead of triggering the destination-collision branch.
- `hive approve` text-mode output sends the `next: hive run …` hint to stderr instead of stdout, so a caller piping stdout through `jq` (without remembering `--json`) doesn't get prose mixed with data.
- `hive approve` deletes the per-process `.lock` file at the destination after the move so it isn't tracked in the slug-scoped commit.
- Initial public release of Hive — folder-as-agent pipeline driving a six-stage filesystem state machine.
- CLI commands: `hive init`, `hive new`, `hive run`, `hive status`, `hive approve`.
- Six pipeline stages: `1-inbox`, `2-brainstorm`, `3-plan`, `4-execute`, `5-pr`, `6-done`.
- Orphan-branch state model (`hive/state` checked out as a separate worktree at `<project>/.hive-state/`).
- Per-task `.lock` (with PID-reuse defence via `/proc/<pid>/stat` start time, macOS `ps -o lstart=` fallback) and per-project `.commit-lock` (flock).
- Atomic marker writes (tempfile + rename under a `.markers-lock` sidecar).
- Prompt-injection nonce wrapper (`<user_supplied_<hex16>>…</user_supplied_<hex16>>`) on every stage template.
- SHA-256 integrity checks on `plan.md` and `worktree.yml` around both the implementation and reviewer passes.
- PR body secret-scan in the `5-pr` stage (api-key / AWS / GitHub-token / PEM patterns).
- Runtime claude version check (`Hive::Agent.check_version!`) wired into every active-stage spawn, memoized per `bin` path.
- Wiki knowledge base under `wiki/` with index, architecture, state-model, decisions (ADRs), per-stage and per-module pages.
- CI: GitHub Actions running tests, RuboCop (37signals omakase), Brakeman, and `bundler-audit`.
- Dependabot configuration (bundler weekly, GitHub Actions weekly).
- `--json` output mode for `hive status` and `hive run`. Each emits a single JSON document on stdout with a `schema` + `schema_version` header (current: `hive-status` / `hive-run`, version 1).
- Documented exit-code contract: `Hive::ExitCodes` constants and per-`Hive::Error`-subclass codes mapped through `bin/hive` (0 success, 2 already-initialised, 3 task in `:error`, 4 wrong stage, 64 usage, 70 software, 75 retryable lock contention, 78 config).
- New `Hive::TaskInErrorState`, `Hive::WrongStage`, `Hive::AlreadyInitialized` exceptions for the new exit-code mappings — all three now actually raised by their corresponding call sites (run.rb on `:error` marker; inbox.rb when `hive run` is invoked on `1-inbox/`; init.rb on a second-init).
- `Hive::SCHEMA_VERSIONS` registry: single source of truth for the JSON contract version per schema (`hive-status`, `hive-run`).
- `Hive::Schemas::NextActionKind` closed enum (`EDIT`, `MV`, `RECOVER_STALE`, `NO_OP`, plus `ALL`) shared between the producer (`run.rb`) and the JSON regression tests.

### Changed

- `hive run` exits with code `3` (not `1`) when a stage records a `:error` marker — distinguishes a runner-level failure from an agent-recorded task failure.
- `hive run` on a `1-inbox/` task now raises `Hive::WrongStage` (exit 4) instead of warning + returning 0, so agent callers can branch on the wrong-stage condition.
- `hive init` on an already-initialised project raises `Hive::AlreadyInitialized` (exit 2) through the rescue path; behaviour is identical to the previous bare `exit 2` but the contract now flows through one channel.
- `with_captured_exit` test helper centralised in `test/test_helper.rb` (previously duplicated in **four** integration test files — the `init_test.rb` copy was missed in the first pass).
