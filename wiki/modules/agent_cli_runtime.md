---
title: Agent CLI Runtime component
type: module
source: components/agent-cli-runtime, components/agent-cli-runtime/mirror, .github/workflows/agent-cli-runtime-release.yml
created: 2026-07-26
updated: 2026-11-02
tags: [agent, runtime, component, gem, cli]
---

**TLDR**: `agent-cli-runtime` gives Ruby applications one stable integration
layer for Claude Code, Codex CLI, Pi, Grok CLI, and OpenCode. Its versioned
profiles centralize provider-specific commands, local capability checks,
environment rules, usage extraction, and result normalization so consumers
can add, switch, and upgrade agent CLIs behind one request and result
vocabulary. It is the first independently versioned gem kept in the Hive
monorepo, with Hive as its primary consumer and orchestration policy owner.

Claude print-mode prompts use the existing `piped_stdin` transport, like Pi
and OpenCode. Hive supplies the complete prompt through its temporary stdin
file rather than one process argument, avoiding `E2BIG` for large review diffs.
The real-process regression sends 256 KiB and verifies byte-for-byte delivery.
Grok also uses `piped_stdin`, with `--prompt-file=/dev/stdin`: its Unix CLI
reads the managed stdin file instead of receiving a potentially oversized
`-p` argument. Grok does not interpret `--prompt-file -` as stdin.

## Public surface

The package lives at `components/agent-cli-runtime/`, loads with
`require "agent_cli_runtime"`, and exposes the `AgentCliRuntime` namespace.
Its built-in profiles are ordered `claude`, `codex`, `pi`, `grok`, `opencode`.
The appended profile leaves the order and behavior of the four legacy profiles
unchanged. Callers construct immutable requests and receive immutable compiled
invocations, capability evidence, probe results, and observable results.
Each profile also exposes an immutable `credential_environment_keys`
inventory. This is compatibility metadata for an orchestrator that needs to
remove ambient credentials when selecting a named subscription/session; it
contains names only and does not move credential values into the package.
The companion `configuration_environment_key`,
`default_configuration_directory`, and `configuration_directory` contract
describes the CLI-owned subscription/session directory. The extracted package
owns these provider-specific names; it does not provision API keys or choose an
authentication mode.
Hive uses that inventory to remove ambient API credentials from child launches
and select CLI subscription/session state. That is Hive policy, not a package
restriction for independent consumers.

`bin/hive` prefers `components/agent-cli-runtime/lib` when it is present in a
source checkout. This keeps dogfood and benchmark clones on the component
contract reviewed in the same commit, even when the operator also has an older
published `agent-cli-runtime` gem installed. Packaged Hive remains unchanged
because its gem does not include the monorepo component directory.

Compilation returns argv and optional stdin without executing a process.
Requested controls fail closed with `UnsupportedCapability` when a profile
cannot represent them. Provider profiles and extractors are public,
SemVer-governed behavior; orchestration policy stays injectable or outside the
package.

The prompt transport distinguishes stdin with an argv marker (`:stdin`, used
by Codex) from unmarked stdin (`:piped_stdin`, used by Claude, Pi, Grok and OpenCode).
These CLIs read the initial message from stdin, so implementation-sized
prompts never occupy one operating-system-limited argv element. This matters
before the total `ARG_MAX` ceiling: Linux rejects one argument at roughly 128
KiB, which a deeply reviewed plan can exceed on its own.

OpenCode adds a stricter, additive preparation surface because its safe
headless contract depends on an invocation-owned configuration overlay. An
`OpenCodePreparationRequest` identifies an exact `provider/model`, a selected
configuration source, named credential environment keys, a working directory,
declared extra roots, and a fresh absolute invocation root. `prepare!` performs
only bounded local version/help/auth/model-inventory inspections, writes
owner-private XDG config/data/cache/state homes, compiles deny-first permission
rules, and returns a `PreparedInvocation`. The value exposes discrete argv,
non-secret child-environment overrides, requested-route evidence, generated
paths, and idempotent `cleanup!`; it never starts `opencode run`. The process
owner forwards only the named credential keys, binds any compiled `stdin_data`
to the run process, and must invoke cleanup from its own lifecycle `ensure`.

That prepared-overlay API remains available to independent component
consumers, but Hive no longer selects it. Hive compiles `opencode run`
directly against the operator's native config, plugins, project discovery,
session store, and login, then supplies only its workflow permission document
through `OPENCODE_PERMISSION`. Run/export parsing and normalization remain
shared with the component.

The OpenCode route-aware probe requires `1.18.16+`, all pinned run/export
flags, a selected authentication source, and an exact `provider/model` plus
requested variant while remote model fetching and ambient project
configuration are disabled. The probe accepts the caller's already-resolved
executable on `ProbeRequest.executable` and otherwise falls back to declared
environment overrides; either way it validates and reports exactly the
executable the compiled invocation runs. ProbeRequest environment overrides are
restricted to the OpenCode overlay keys (`OPENCODE_OVERLAY_ENVIRONMENT_KEYS`);
any other key is rejected with `ArgumentError`. The probe child environment
also copies only overlay-contract keys into the scrubbed base rather than
blanket-merging the request environment, and applies the denylist scrub last
after every caller-controlled channel, so Ruby and Bundler injection
variables such as `RUBYOPT` stay removed even when a request is constructed
outside the validated overlay contract. Credential keys are bound by the
same rule: `ProbeRequest` and `OpenCodePreparationRequest` reject any
credential key in `SCRUBBED_RUNTIME_ENVIRONMENT_KEYS` (`RUBYOPT`, `RUBYLIB`,
`GEM_HOME`, `GEM_PATH`, `BUNDLE_BIN_PATH`, `BUNDLE_GEMFILE`) with
`ArgumentError`, so a poisoned ambient value cannot be selected back into a
scrubbed child. An exact route declared by the selected overlay is
authoritative and skips the large verbose CLI inventory; an undeclared route
must still exist in that bounded local inventory. Generic `probe(profile)` and
`prepare!(profile)` remain compatible for legacy profiles. OpenCode's ordinary
`nil`, `read-only`, and `workspace-write` compilation paths fail closed unless
the prepared overlay supplies its explicit typed policy and trusted `--auto`
argument.

Prepared overlays reserve every XDG/config/disable key, remove selected
per-agent permission blocks, forward credentials only when they match the
requested provider, and emit worktree-relative edit patterns. Nested read-only
exceptions are re-applied after writable rules because OpenCode uses the last
matching permission. Workspace-write requests may also carry explicit
deny-first Bash patterns; absent patterns keep shell denied, and the patterns
remain application permissions rather than an OS sandbox. Probe children start from an explicitly cleared
environment, and cleanup refuses a replaced invocation root without masking a
completed Hive result.

OpenCode also uses the profile's additive strict result-parser hook. A caller
passes captured stdout/stderr plus typed exit, signal, timeout, or cancellation
evidence. A successful run must contain one consistent session, a recognized
terminal `step_finish`, and text for that terminal message identity. The caller
then executes the separately compiled non-model `export SESSION --sanitize`
inspection under the same overlay. Normalization correlates the exported
assistant record, records requested and actual nested routes separately, and
uses its token/cache/reasoning/cost fields without converting absence to zero.
Timeout, cancellation, authentication failure, configuration failure, generic
CLI failure, malformed output, and completion remain distinct outcomes.
Nonzero OpenCode runs that carry an upstream idle-timeout/504 diagnostic are
normalized as `timed_out` rather than generic `cli_failure`; Hive projects that
use marker-owned stages record the ordinary transient `timeout` reason while
preserving any partial artifact bytes for scheduler-owned retry.
OpenCode's profile-specific provider-error extractor reads only dedicated
`error` events and their nested `error.data.message` payload. A structured
upstream rate-limit refusal therefore reaches Hive as a typed `rate_limited`
signal and writes the normal cooldown-retry marker, while identical prose in
ordinary model output cannot forge a retryable provider wall.
Claude's extractor also recognizes its exact message-free rejected
`rate_limit_event` for the known `five_hour` and `seven_day` account windows.
It synthesizes bounded quota text and a typed `provider_limit`, so review,
triage, and other output-file spawns retain normal `limits_reached` recovery
instead of degrading to an exit-code error. Non-rejected and unknown window
types remain unclassified.
When OpenCode exits zero with an empty terminal assistant message after writing
a current terminal stage artifact, Hive trusts that controller-scoped artifact;
the strict malformed transcript remains a failure whenever the artifact itself
is incomplete.
Unknown additive event payloads are discarded after binding any supplied
session identity; only bounded, redacted type summaries survive. Exact
truncation evidence is carried separately from final-message bytes. Legacy
profile extraction and observation are unchanged.

The public facade includes `compile`, `prepare!`, `require_capability!`,
`extract_usage`, `extract_provider_error`, `observe`, `probe`, and `probe_all`.
It accepts built-in names or custom `Profile` objects, preserves
`UnknownProvider` as a typed caller error, exposes custom CLI capabilities in
static probe evidence, and rejects custom names that collide with the standard
capability vocabulary. Missing usage stays `nil`; terminal events without
counters do not become measured zero-token events. Pi's zero-exit
`stopReason: "error"` refusals and `stopReason: "length"` incomplete turns are
normalized separately: the latter carries `kind: model_output_limit`, so Hive
reports model-output exhaustion instead of blaming a missing artifact.
Observable results also carry an optional immutable `provider_signal` supplied
by a trusted caller. The component does not classify that signal or own
provider-health policy.

For compatibility with Hive's trusted legacy headless launches,
`permission_mode: nil` still selects a legacy provider's bypass flag. OpenCode
requires a prepared explicit policy. Independent
consumers should pass `read-only` or `workspace-write` when they require those
restrictions; unsupported enforcement fails closed. Version probes execute
with their supplied environment, reject output containing multiple distinct
version tokens, and terminate the full process group with a TERM/KILL and
bounded-reader cleanup path on timeout. Grok environment authentication ignores
unused file-path overrides, while file-backed authentication still validates
absolute paths.

The `agent-runtime probe [PROVIDER|--all] [--json]` executable checks only
locally observable executable installation, version output, authentication
configuration presence, and declared capabilities. Its JSON envelope has
`schema_version: 1` and a `probes` array. Exit 0 means every requested local
prerequisite is ready, 1 means at least one is unavailable, and 64 means invalid
usage. `configured` never claims credential validity, provider health, or
account quota.

## Ownership boundary

The package does not spawn or supervise agents, select workflows, retry work,
interpret stages or markers, accept artifacts, decide success, own provider
budgets, or contain Hive defaults and skills. It can load and run without
`hive-cli` or Hive constants. Direct standard-library gem dependencies are
declared in its gemspec.

Hive requires `agent-cli-runtime ~> 0.2.0` and resolves the monorepo component
path during development. This keeps installed Hive on the independently
published OpenCode-capable line while allowing compatible 0.2.x patches;
component publication and Hive dependency cutover remain separate operations.
OpenCode's prepared invocation keeps its configuration, data, cache, state,
and temporary roots private, while Hive forwards the operator-selected
`GEM_HOME` and `GEM_PATH` alongside the existing base process environment. A
systemd daemon commonly has no explicit `GEM_PATH`; in that case Hive supplies
the effective `Gem.path` of its own Ruby process. Those paths are runtime
inputs, like `PATH`: dropping them can make a
repository's checked-in Ruby binstubs fail to load `bundler/setup` even though
the exact same binstubs work for the operator. Ruby code-injection options such
as `RUBYOPT` remain outside the forwarded environment.
`Hive::AgentRuntime`
preserves its
public request, probe, error, and result names as a forwarding facade, while
`Hive::AgentProfile` wraps package profiles with only Hive-owned skill, model
routing, default-model, status, and policy metadata. The five source-built Hive
profiles reference the package's profile objects instead of copying provider
flags, probes, usage extractors, or configuration metadata.

Source Web declares the component as an explicit path gem so Rails boots
against the same reviewed ABI. Managed Web provisioning and server launches
replace that relative source with the installed component gem root through
`HIVE_AGENT_CLI_RUNTIME_ROOT`, parallel to the existing `HIVE_CLI_ROOT` seam.

The published 0.2.0 candidate was built from canonical commit
`c8f62cacefb9d5982ab0e8d2328071763b3736c4`, published by the protected
component workflow, and independently fetched from RubyGems with SHA-256
`b813b54d0dded7ecab2a7aa569d997c7d4c24666b76ba675196cb30e10e08320`.
Fresh isolated installation, require, executable-version, and ready OpenCode
JSON probe checks matched the retained workflow artifact before Hive's cutover.

## Development and release

Package tests run directly from the subtree and through the root `rake test`
task. Candidate tooling builds one gem, records its source commit and dirty
state, checksums it, installs it into a private gem home, proves a clean require,
and exercises the executable. The repository keeps one internal conformance
suite at `test/support/conformance.rb` as the single owner of the ordered
provider inventory and the OpenCode capability contract; `bin/verify-candidate`,
the source contract tests, and its synthetic probe stub all consume it, and
`test/conformance_suite_test.rb` guards parity with shipped library behavior.
Root parity fixtures cover non-default
compilation, local probes, named capability evidence, provider usage variants,
and observable normalization/redaction across all five built-ins. The
installed OpenCode offline smoke considers every matching PATH executable and
prefers a native binary over an earlier package-manager launcher, including
script and multicall-binary shims; an explicit offline binary override remains
authoritative. This keeps read-only probe evidence from
triggering package-manager setup or refresh side effects. The
0.2.0 release promotes OpenCode to the public compatibility surface without
changing the component's caller-owned process-supervision boundary or
authorizing a Hive release.
`bin/release-preflight` remains
tag-bound and is not run against a fabricated tag during candidate work.

Only `components/agent-cli-runtime/vX.Y.Z` tags can trigger the component
workflow. The tag, package version, exact main commit, and clean checkout must
agree. Candidate and platform-install jobs have no publication identity; the
`agent-cli-runtime-release` environment grants OIDC only to the publish job,
which pushes the previously verified bytes without rebuilding. Hive root tags
use a separate workflow and release surface. Every component release job has a
15-minute execution timeout and the exact candidate is retained for 30 days to
survive reviewer delay. Repository operators must separately enforce a
component-tag ruleset, required reviewers on the release environment, and an
environment deployment policy restricted to matching component tags. See
`docs/RELEASING.md`.

The public
[`ivankuznetsov/agent-cli-runtime`](https://github.com/ivankuznetsov/agent-cli-runtime)
repository is a read-only distribution projection, not a second development
home. Its scheduled or manually dispatched sync copies this component to the
mirror root and writes `.mirror-source.json` with the exact canonical component
commit. The mirror invokes the projector from the canonical checkout and
requires the complete canonical admin set before mutation. Mirror Git writes
use a repository-scoped deploy key because GitHub's generated token cannot
update workflow files; API reads and release creation retain the shorter-lived
generated token. A separate manual mirror workflow projects an already
approved, fully qualified component tag to an orphan `vX.Y.Z` source-snapshot
tag. It reuses the component release preflight, verifies the exact version is
already on RubyGems, compares the projected tree with an independently archived
canonical tree, requires a live immutable `refs/tags/v*` ruleset, verifies the
local tag as an installable gem, and builds the focused GitHub release notes
from that verified tag's `CHANGELOG.md`. A checked extractor rejects missing or
whitespace-only version sections before the immutable tag is pushed, and the
release step consumes that already validated file. This ordering also makes a
retry with an existing matching tag independent of mutable mirror `main`.
Neither mirror workflow can modify Hive, publish RubyGems
bytes, or choose a version; issues, pull requests, and release authority stay
here.

## Compatibility

For the retained uncertainty and historical evidence, see [Portable managed Grok execution is Linux-only (2026-07-26)](#portable-managed-grok-execution-is-linux-only-2026-07-26).

The 0.2.x line runs on Ruby 3.4 or newer and is tested on Linux and macOS.
Version 0.2.0 accounts for the additive OpenCode prepared-invocation,
route-probe, strict-parser, identity, and usage contracts. Removing or changing
an existing public field, flag mapping, event meaning, or executable contract
requires a minor release while pre-1.0. A published bad version is fixed
forward; yanking or ownership changes are separate operator decisions.

Related context: [[component-boundaries]], [[modules/agent_profile]], and
ADR-038 in [[decisions]].

## Known gaps

- [Typed budget and Brainstorm artifact repair](../stages/brainstorm.md#typed-budget-and-brainstorm-artifact-repair-need-live-dogfood-2026-07-25)

### Headless soak for brainstorm, execute, and review-fix (2026-10-14)

#### Source S05, lines 86–88: Claude headless-only follow-ups (2026-10-14)

The Claude tmux launch mode was removed (ADR-053 in [[decisions]]). Open items
found while updating docs:

#### Source S05, lines 93–95: Claude headless-only follow-ups (2026-10-14)

- **Headless soak for brainstorm, execute, and review-fix.** These stages ran
  mostly under tmux (the old default), so they have little production soak on
  the headless path. Watch the first real tasks after the change.

### Review token cost of independent Claude reviewers is unmeasured (2026-10-14)

#### Source S05, lines 89–92: Claude headless-only follow-ups (2026-10-14)

- **Review token cost of independent Claude reviewers is unmeasured.** Claude
  reviewers no longer share one session per pass, so prompt-cache reuse within a
  pass is lost. The plan expects review token use to rise slightly; no
  before/after measurement exists in-tree.

### Existing tasks still on a pre-upgrade tmux Claude (2026-10-14)

#### Source S05, lines 96–101: Claude headless-only follow-ups (2026-10-14)

- **Existing tasks still on a pre-upgrade tmux Claude.** Recovery relies on the
  operator letting Claude stages finish before upgrading, then killing leftover
  Hive Claude tmux sessions; the new code cannot see such a session. The step is
  recorded in the `## 0.8.0` section of `CHANGELOG.md`, staged ahead of the
  version bump; release prep keeps that section when it bumps to 0.8.0.

### OpenCode live validation (updated 2026-08-21)

#### Source S18, lines 358–368: OpenCode live validation (updated 2026-08-21)

OpenCode `1.18.16+` now has deterministic fixtures, a guarded installed-CLI
offline smoke, fake-CLI Hive execute and native Compound Engineering plan
integration, installed-candidate lifecycle proof, and independently
reconstructed mirror projection proof. The component release workflow makes
the real installed-CLI offline smoke mandatory instead of accepting a skip.
The authenticated atomic-edit smoke is intentionally gated
on an explicit backend/model, selected config, credential environment key, and
operator opt-in. Until that gate is supplied, real model transport and live
provider permission behavior remain unverified; an offline inventory check is
not equivalent to a model request.

### Invocation-token custody limitations

#### Source S18, lines 434–444: OpenCode live validation (updated 2026-08-21)

Invocation-token custody now cleans ordinary inherited descendants even after
`setsid` and reparenting, which is the leak observed during live Webmail
dogfood. It is lifecycle cleanup, not hostile-process containment: a command
that deliberately erases the custody environment or delegates a service to an
external manager without forwarding it can evade the inventory. The same
limit applies when a descendant becomes non-dumpable: an unreadable process
environment cannot prove ownership. Unreadable same-user rows are skipped
because unrelated service managers can legitimately have that property. A dedicated
cgroup/namespace owner that preserves OpenCode's required repository writes,
network, and cross-platform support remains a deeper isolation follow-up.

### Claude launch flags should be live-checked against current Claude Code.

#### Source S28, lines 785–785: Open questions about the codebase

11. **Claude launch flags should be live-checked against current Claude Code.** Config, init prompts/schema, and headless argv tests now cover `claude.permission_mode` plus the new `claude.model` / `claude.effort` pins. There is still no recorded live run proving every accepted permission mode, `--model default`, and explicit `--effort low|medium|high` still match the installed Claude CLI's current behavior.

### Portable managed Grok execution is Linux-only (2026-07-26)

#### Source S53, lines 1279–1288: Portable managed Grok execution is Linux-only (2026-07-26)

Bounded current-generation Honeycomb actors can now run through Codex or Grok
without granting either provider direct task writes. Codex relies on its named
filesystem permission profiles; Grok is confined by bubblewrap because its
native read-only tool rules do not prevent undeclared reads. The Grok adapter
therefore fails closed when `/usr/bin/bwrap` is unavailable. No macOS or Windows
equivalent is implemented yet, and future Codex/Grok CLI changes still require
the focused policy probes and live managed-workflow dogfood before those
platform/version combinations are treated as proven.

### Resolved

#### Tmux-session disappearance is unit-pinned but not live-smoked.

##### Source S28, lines 793–793: Open questions about the codebase

17. ~~**Tmux-session disappearance is unit-pinned but not live-smoked.**~~ — closed 2026-10-14. The Claude tmux launch runtime was deleted (Claude launches only as headless `claude -p`; see ADR-053 in [[decisions]]); no Claude stage runs in a tmux session, so the live smoke can no longer be performed. `daemon/stale_agent_healer.rb` still reads the legacy `tmux_session_terminated` reason for task records written before the upgrade. Original record: Commit `71db09c7` added `test/unit/claude_launcher_test.rb` coverage proving that `Hive::ClaudeLauncher.wait_for_terminal_marker` stamps `ERROR reason=tmux_session_terminated` when `runner.session_exists?` turns false before a marker arrives, and reports a pane-readability error if the tmux session check itself fails. Current recovery tests prove that this marker follows the same cooldown, coordinator admission, marker-id guard, and workflow-derived retry argv as every other `ERROR`; there is no TUI auto-healer or `3-plan`-specific clear/requeue branch. Branch `fix-claude-tmux-ready-detector-260629-50cc` documents the correct local-gem validation path for Claude tmux launcher-script packaging fixes in [[operating]], and source/tests show the gemspec includes `lib/hive/scripts/**/*.sh`; this refresh still found no in-tree artifact of a locally built `hive-cli` install replaying the affected Claude tmux task to `WAITING` or later. No in-tree artifact was found for the full live path: kill a real managed tmux session during a Claude-backed brainstorm/plan/execute/artifacts/finalize run, observe the marker through `hive status`, let the daemon submit it to the coordinator, and verify repeated cooled retries eventually advance after the external fault is repaired.

#### Claude/tmux orphan-sweep server skip is unit-pinned but not post-fix parallel live-smoked.

##### Source S28, lines 809–809: Open questions about the codebase

34. ~~**Claude/tmux orphan-sweep server skip is unit-pinned but not post-fix parallel live-smoked.**~~ — closed 2026-10-14. The Claude tmux launch runtime was deleted (Claude launches only as headless `claude -p`; see ADR-053 in [[decisions]]); `sweep_orphan_processes` was deleted with it. Original record: Commit `024b29b0` changes `Hive::ClaudeLauncher.sweep_orphan_processes` from a blanket `pkill -f` to `pgrep` plus per-PID `TERM`, skipping matched `tmux` commands because the tmux server can retain the first session's full `new-session ... --add-dir <task.folder>` argv. `test/unit/stages/brainstorm_tmux_sentinel_test.rb` covers the observed shape: one matched tmux server line plus one matched Claude line must kill only the Claude PID and log `skipped=1`. The 2026-06-11 refreshes did not find an in-tree artifact showing two real Claude/tmux-backed Hive tasks running in parallel after the fix, one finishing, and the sibling session surviving without `tmux_session_terminated`.

#### Tmux large-prompt settle is unit-pinned, not live-Claude-smoked.

##### Source S29, lines 917–918: 2026-06-16/17 refresh uncertainty

- ~~**Tmux large-prompt settle is unit-pinned, not live-Claude-smoked.**~~ — closed 2026-10-14. The Claude tmux launch runtime was deleted (Claude launches only as headless `claude -p`; see ADR-053 in [[decisions]]); `Hive::TmuxRunner` is gone and headless Claude receives the whole prompt on stdin. Original record: Commit `f25896a2` makes `Hive::TmuxRunner#send_prompt` wait for a stable pane tail before sending Enter. `test/unit/tmux_runner_test.rb` covers settle/deadline/failure paths with fake tmux, but this refresh did not find a live Claude/tmux run with a large review/triage prompt proving the prompt no longer sits staged in the input box.
