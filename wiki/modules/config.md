---
title: Hive::Config
type: module
source: lib/hive/config.rb
created: 2026-04-25
updated: 2026-09-06
tags: [config, yaml, validation, plan-review, opencode, daily-digest]
---

**TLDR**: Two YAML configs — global at `~/.config/hive/config.yml` (registered projects plus daemon, bot, daily digest, update, web, and Screenote base-url settings, including voice-transcription defaults; `HIVE_HOME/config.yml` when overridden, legacy `~/Dev/hive/config.yml` when migrated) and per-project at `<project>/.hive-state/config.yml` (default branch, default workflow, worktree root, budgets, timeouts, **stage agents**, project-owned `models`, project/top-level and per-stage `permissions`, project-global `claude.mode`/`claude.permission_mode` plus `claude.model`/`claude.effort` pins, an optional project-owned artifact capture provider, review-stage roles, daemon enrollment, experimental babysitter enrollment, ordinary patrol, and scheduled architecture patrol). Project config root keys are strict: `Config.load(project_root)` rejects unsupported keys before merging defaults, while registered workflow stage names remain the sanctioned dynamic extension for stage overrides. Architecture-patrol discovery, issue review output, and automatic mutation remain separate settings. Fresh init enables issue output with discovery as the default review surface; legacy or hand-written config that omits `issue_filing.enabled` remains effect-free. `Config.load(project_root)` captures frozen raw field provenance for implementation-owning `agent`/`model`/`effort` keys before it **recursively** deep-merges project values onto `Config::DEFAULTS`, then runs `validate!`. Arrays are replaced wholesale, never per-element merged. Screenote OAuth tokens live outside YAML in `screenote.json`, created by `hive connect screenote`.

The live project template includes a commented, copyable `models:` example.
Exact and coarse entries inherit model and effort independently, never select an
agent, and are absent by default so generated projects keep legacy behavior.
Arbitrary descriptor stage names remain descriptor-owned and are rejected from
the closed `models:` vocabulary.

Provider-account routing is a separate opt-in surface. Global `providers:`
declares named adapter/model/launch-binding/concurrency policy, while a project
stage's `routing.pool` references those names and freezes an explicit
[[modules/provider_routing]] policy. `Config.load` does not read or validate the
global provider registry unless an explicit pool exists, preserving the
unconfigured legacy path structurally. Candidate entries cannot override their
account adapter. Pins, route metadata, hard requirements, account/model
allowlists, binding uniqueness, and policy digests validate before dispatch.

## Strict project root keys

After YAML parsing confirms that `.hive-state/config.yml` is a mapping,
`Config.load` validates its raw top-level keys before patrol mode expansion,
default merging, provenance fields, or other synthetic values are added. The
supported static vocabulary is `Config::DEFAULTS.keys` plus explicitly
supported no-default sections such as `gh`. Hive also loads the built-in and
active project workflow descriptors and accepts their exact stage names as
top-level per-stage override keys. Arbitrary lookalikes are not extension
namespaces. Static-only configs do not scan workflow descriptors; when a
dynamic candidate is present, validation reuses the active project overlay or
loads it once from the already-parsed `hive_state_path`. Project loading reads
the same raw config data and validates it after installing the overlay, so it
does not call back through `Config.load` or perform a duplicate fingerprint
scan.

All unsupported root keys are reported together in deterministic order and the
error names the source config path. The loader raises
`UnsupportedProjectConfigError` (a `ConfigError`, exit 78) so task/workflow
discovery cannot mistake this shared validation result for a recoverable config
read failure and fall back to the built-in `coding` workflow.

There is one narrow upgrade compatibility alias. Older Hive versions silently
ignored a literal root-level `reviewers` key, so the loader temporarily promotes
that value in memory to `review.reviewers`, validates it there, and emits one
warning per process and source path telling the operator to run `hive migrate`.
This keeps an older project usable immediately after `hive update` without
silently discarding its intended reviewer selection. `hive migrate` performs
the durable, comment-preserving rewrite in the project's tracked Hive state.
If both the legacy and canonical locations exist, Hive exits 78 and requires
the operator to choose which value to keep; it never guesses. Invalid promoted
values such as `reviewers: null` still fail the normal
`review.reviewers` validation.

The canonical form is:

```yaml
review:
  reviewers:
    - name: codex-native-review
      kind: codex_review
      agent: codex
      output_basename: codex-native-review
      prompt_template: reviewer_codex_native_review.md.erb
```

This root allowlist applies only to project config loaded through
`Config.load`; global Hive config retains its separate vocabulary, including
`registered_projects`. Because every project command shares this boundary, the
same malformed project config fails consistently in `hive run`, `hive doctor`,
`hive new`, text/JSON `hive status`, and other consumers instead of reaching
command-specific fallback behavior. An invalid workflow path cannot pre-empt
an unsupported-root diagnostic; the legacy reviewers alias is normalized before
workflow-path resolution.

## Model-routing ownership and structure

`models:` is a strict, no-default section backed by
[[modules/model_routing]]. Leaving it out therefore leaves the loaded project
config shape unchanged. Project config may contain every registered public
key. The removed in-process PR digest is not a route; standalone PRDigest owns
that integration.

Structural validation rejects non-mapping roots, unknown or wrong-owner stage
keys, empty/non-mapping entries, fields other than `model` and `effort`,
blank/non-scalar models, and efforts outside the shared accepted vocabulary.
Each entry retains only authored fields, so model-only and effort-only
overrides stay distinguishable. This structural pass runs before the legacy
top-level-reviewers warning. Reachable-profile capability validation remains a
separate, pure routing-domain step after exact/coarse shadowing is known.

## Explicit provider-routing validation

Provider pools are discovered at the enclosing durable stage boundary,
including top-level `review.routing`; nested review-role routing remains a
separate configuration surface and cannot substitute for the route used by the
durable `6-review` attempt. Route metadata must fit both Hive's closed
vocabulary and the selected agent profile's hard tool and permission limits.
Impossible declarations therefore fail during configuration loading instead
of appearing eligible to the router and failing only after launch.

Named launch bindings are compared by effective identity. Credential-directory
bindings are expanded and canonicalized, including symlink resolution when the
target exists, so two symbolic aliases cannot silently share one billing
context while claiming separate account concurrency and fallback.

## Outcome-evidence roles and project capture provider

`artifacts.evidence` configures three fresh contexts without changing their
security ownership:

```yaml
artifacts:
  agent: claude
  evidence:
    max_recaptures: 2
    inference:
      permissions: read-only
      # agent: codex
      # model: gpt-5.6-sol
      # effort: high
    producer:
      agent: codex
    reviewer:
      permissions: read-only
      # agent: codex
      capabilities:
        proof_kinds: [screenshot, video, terminal, document]
        temporal_video: true
```

Each role inherits `artifacts.agent` unless it names its own `agent`, and may
independently select `model` and `effort` through the normal model-routing
boundary. `max_recaptures` is an integer from 0 through 2 and counts targeted
recaptures after the initial package. Inference and reviewer permissions are
fixed to `read-only`; config cannot widen them. Producer writes are always
controller-scoped to the active evidence root, so there is no producer
`permissions` escape hatch. The reviewer capability object is closed:
`proof_kinds` is a unique nonempty subset of `screenshot`, `video`, `terminal`,
and `document`, while `temporal_video` is boolean. A generated requirement that
the configured reviewer or producer cannot safely handle becomes an explicit
semantic blocker before capture begins.

These roles control the authoritative outcome-evidence package described in
[[stages/artifacts]]. `artifacts.capture.provider` remains the optional runtime
used to create project-owned media bytes; a capture manifest is not completion
authority by itself.

Hive checkouts need no declaration: the complete locked Hivebox web layout
selects the built-in recorder. A conventional project can declare one
project-owned executable:

```yaml
artifacts:
  agent: claude
  capture:
    provider:
      name: rails
      command: [bin/hive-capture]
      timeout_sec: 120
```

`provider` defaults to `nil`. When present it is a closed mapping: `name` must
match `[a-z][a-z0-9_-]{0,63}`, `command` is 1–32 non-empty argv strings whose
first item is a traversal-free project-relative executable path (the capture
boundary also requires that executable to be tracked at the immutable HEAD),
the complete argv is at most 16 KiB, and `timeout_sec` is an integer from 1
through 600. Unknown fields, a shell command string, oversized argv,
absolute/traversing executables, or malformed values fail during `Config.load`,
before capture starts. The provider request/result ABI and publication checks
are documented in [[commands/web]].

This declaration is additive. Projects that omit it retain their prior config
shape: compatible Hivebox trees continue on the built-in recorder, while
incompatible conventional trees receive the precise unsupported-provider
diagnostic until they opt in. Retained v1 capture manifests remain readable;
new successful capture emits the provider-neutral v2 manifest.

## Plan-review policy and routes

`plan_review` is a closed, production-enabled configuration subtree for the
built-in coding plan boundary. It does not extend workflow descriptors or
activate critique for other workflows. Defaults are:

```yaml
plan_review:
  enabled: true
  classifier_version: 1
  minimum_level: skip
  coding: {minimum_level: skip}
  skip: {max_files: 5, max_bytes: 262144}
  protected_paths:
    - .github/workflows/**
    - config/**
    - db/migrate/**
    - packaging/**
    - Gemfile
    - Gemfile.lock
    - hive.gemspec
    - install.sh
  attempts: {max_transient: 2, timeout_sec: 1800}
  coverage: {required: [whole_document, adversarial], optional: []}
  adapter: ce_doc_review
  reviewers:
    primary: plan_review
    adversarial: plan_review_adversarial
    verification: plan_review_verification
  routes:
    primary: {agent: codex, model: gpt-5.6-sol, family: openai, effort: high, route: native_codex}
    adversarial: {agent: grok, model: grok-4.6, family: grok, effort: high, route: native_grok_build}
    verification: {agent: codex, model: gpt-5.6-sol, family: openai, effort: high, route: native_codex}
    fallbacks: []
    # Optional operational recovery route, used only after the captured
    # planner produces a transient revision failure:
    # planner_revision_fallback: {agent: codex, model: gpt-5.6-sol, family: openai, effort: high, route: native_codex}
  approval_policies: []
```

Minimum levels accept only `skip`, `standard`, or `mandatory`; inherited and
per-run inputs are raise-only. File/byte/retry/timeout limits are bounded,
protected globs must be safe relative patterns, coverage names are unique
lowercase identifiers, and required/optional coverage cannot overlap. Every
route is a closed provider/model/family/effort/route receipt and every reviewer
name must exist in the model-routing registry.

`routes.planner_revision_fallback` is optional. It is an operational liveness
control rather than a reviewer-policy input, so adding or changing it does not
rekey the current logical review or discard accepted findings and decisions.
The captured planner always receives the first revision attempt. After a
transient failure, later attempts use the configured fallback and retain it for
the rest of that review. Immutable attempt receipts record the captured
planner authority, effective fallback, failure, and selection reason. Reviewer
and verification route changes remain policy changes and still create a linked
review.

Ordinary project loads still reject `enabled: false`. A benchmark runtime that
must reproduce pre-plan-review generation may set the process-local
`HIVE_BENCH_ALLOW_DISABLED_PLAN_REVIEW=1` grant and explicitly serialize
`enabled: false`. Without both values the project fails closed. The benchmark
runner owns this grant; it is not a general production opt-out and does not
change the default above.

Approval-policy rows are also closed. Their unique ID/version, action, risk,
relative paths, validity interval, and revocation flag must validate before the
project loads. `action` is exactly `approve_finding`, and `risk` is one of
`low`, `medium`, `high`, or `critical`; unknown non-empty values fail config
loading rather than producing a policy that can never match. Runtime matching is exact and emits a consumption receipt; it
cannot lower a mandatory review. See [[modules/plan_review]].

## Condition authority

```yaml
conditions:
  authority: markers
  stages:
    4-execute: shadow
```

The top-level authority is the default, with per-stage overrides. Increment 1
permits explicit `conditions` authority only for `4-execute`; trying it on any
other stage is a config error. Hive never promotes this field automatically.
See [[modules/conditions]] and the
[rollout runbook](../../docs/condition-rollout.md).

## Implementation identity provenance

`Config.load` records whether `agent`, `model`, and `effort` were actually authored under `execute`, `open_pr`, `review.fix`, and `review.ci` before defaults are merged. `Hive::ImplementationIdentity::Resolver` consumes that frozen map, so absence means automatic inheritance and an authored value equal to a former default still counts as an override. Fresh templates omit downstream identity fields and show commented override examples. There is no inheritance sentinel or configurable utility-model map.

The built-in downstream policy is `open_pr=medium`, `review.fix=high`, and `review.ci=high`. PR opening keeps the execute provider and maps Claude to `sonnet`, Codex to `gpt-5.6-terra`, and pi/grok to their provider-native default without a pin. Both review repair paths retain the exact execute model. Authored fields override individually; an authored cross-provider agent with no model uses that provider's concrete default rather than pairing it with another provider's model. Independent `review.reviewers`, `review.triage`, and `review.browser_test` configuration is unchanged.

## Defaults (`Config::DEFAULTS`)

```ruby
{
  "hive_state_path"   => ".hive-state",
  "worktree_root"     => nil,
  "default_branch"    => nil,
  "default_workflow"  => "coding",
  "dependency_gate_stage" => "8-finalize",
  "project_name"      => nil,
  "permissions"       => "yolo",
  "claude"            => { "mode" => "tmux", "permission_mode" => "bypassPermissions",
                           "model" => "default", "effort" => "default" },
  # Bumped ~5x in plan 2026-05-04-001 (ADR-023). These are GENEROUS sanity
  # caps for runaway agents, not cost targets. The deprecated
  # `execute_review` key was DROPPED — 6-review owns reviewer budgets per
  # ADR-014. Old project configs that still set it survive deep-merge but
  # nothing reads it and fresh `hive init` no longer renders it.
  "budget_usd" => {
    "brainstorm" => 50, "plan" => 100,
    "execute_implementation" => 500, "open_pr" => 50, "artifacts" => 100,
    "finalize" => 50,
    "review_ci" => 100, "review_triage" => 75,
    "review_fix" => 500, "review_browser" => 100, "patrol" => 100
  },
  "timeout_sec" => {
    "brainstorm" => 1800, "plan" => 3600,
    "execute_implementation" => 14400, "open_pr" => 1800,
    "artifacts" => 3600, "finalize" => 1800,
    "review_ci" => 3600, "review_triage" => 1800,
    "review_fix" => 14400, "review_browser" => 3600, "patrol" => 3600
  },
  # Stage-level agent defaults remain for independently owned stages.
  # Implementation-owned downstream stages intentionally omit active
  # agent/model/effort defaults so the persisted execute owner applies.
  "brainstorm" => { "agent" => "claude", "runtime" => "headless" }, # runtime is legacy read-back-compat
  "plan"       => { "agent" => "claude" },
  "execute"    => { "agent" => "claude" },  # rendered template recommends `codex`
  "open_pr"    => {},
  "artifacts"  => {
    "agent" => "claude",
    "evidence" => {
      "max_recaptures" => 2,
      "inference" => { "permissions" => "read-only" },
      "producer" => { "agent" => "codex" },
      "reviewer" => {
        "permissions" => "read-only",
        "capabilities" => {
          "proof_kinds" => %w[screenshot video terminal document],
          "temporal_video" => true
        }
      }
    },
    "capture" => { "provider" => nil }
  },
  "finalize"   => { "agent" => "claude" },
  "agents" => {
    "claude" => { "bin" => "claude", "env_override" => "HIVE_CLAUDE_BIN", "min_version" => "2.1.118" },
    "codex"  => { "bin" => "codex",  "env_override" => "HIVE_CODEX_BIN",  "min_version" => "0.125.0" },
    "pi"     => { "bin" => "pi",     "env_override" => "HIVE_PI_BIN",     "min_version" => "0.70.2" },
    "grok"   => { "bin" => "grok",   "env_override" => "HIVE_GROK_BIN",   "min_version" => "0.2.90" }
  },
  "review" => {
    "ci"           => { "command" => nil, "max_attempts" => 3,
                        "prompt_template" => "ci_fix_prompt.md.erb" },
    "reviewers"    => [],
    "adhoc"        => { "reviewers" => nil, "fix" => false },
    "triage"       => { "enabled" => true, "agent" => "claude", "bias" => "courageous",
                        "prompt_template" => nil, "custom_prompt" => nil },
    "fix"          => { "prompt_template" => "fix_prompt.md.erb" },
    "browser_test" => { "enabled" => false, "agent" => "claude",
                        "prompt_template" => "browser_test_prompt.md.erb", "max_attempts" => 2 },
    "max_passes"        => 2,
    "max_wall_clock_sec" => 14400
  },
  "web" => {
    "bind" => "127.0.0.1",
    "port" => 4567,
    "origin" => "http://127.0.0.1:4567",
    "local_loopback" => true,
    "github" => { "owner" => nil, "client_id" => "Ov23liYChIkP5PU4bvo1" }, # nil owner => first-login claimable
    "session_secret_file" => nil
  },
  "babysitter" => {
    "enabled" => false,
    "interval" => "10m",
    "max_concurrent_prs" => 2,
    "labels_ignore" => %w[wip do-not-merge draft],
    "dry_run" => false,
    "budget_minutes" => 30,
    "budget_usd" => 50
  },
  "patrol" => {
    "mode" => "medium",
    "enabled" => false,
    "trigger" => "continuous",
    "poll_interval_sec" => 600,
    "agent" => "claude",
    "min_confidence_to_fix" => "medium",
    "min_alpha_to_fix" => 70,
    "max_findings_per_feature" => 3,
    "max_features_per_cycle" => 12,
    "max_fixes_per_feature_per_cycle" => 1,
    "max_fix_attempts_per_cycle" => 6,
    "max_rework_cycles" => 2,
    "max_prs_per_cycle" => 3,
    "scheduled_discovery_launches_per_engine_per_day" => 4,
    "draft_prs" => false,
    "review_prs" => true,
    "include" => [],
    "exclude" => [ "node_modules", "dist", "build", "vendor", ".git" ],
    "commands" => { "format" => nil, "lint" => nil, "typecheck" => nil, "test" => nil },
    "review" => {
      "max_context_files" => 4,
      "max_owned_files" => 4,
      "reviewers" => [ { "name" => "codex-native-review", "kind" => "codex_review", "agent" => "codex", ... } ]
    }
  },
  "daemon" => {
    "enabled" => false,
    "autostart" => false,
    "auto_retry" => { "enabled" => true },
    ...
  },
  "screenote" => { "base_url" => "https://screenote.ai" },
  "bot" => {
    "enabled" => false,
    "pairing_enabled" => false,
    "chat_id_allowlist" => [],
    "idea_attachment_max_bytes" => 20 * 1024 * 1024,
    "idea_attachment_max_count" => 10,
    "idea_draft_ttl_sec" => 900,
    "transcription" => {
      "enabled" => true,
      "endpoint" => "https://api.openai.com/v1/audio/transcriptions",
      "model" => "whisper-1",
      "api_key_env" => "HIVE_WHISPER_API_KEY",
      "max_retries" => 3,
      "retry_backoff_sec" => 2,
      "timeout_sec" => 120,
      "no_speech_threshold" => 0.6,
      "supported_languages" => %w[en ru]
    }
  }
}
```

`default_workflow` is the middle tier in task workflow selection: `<task>/meta.yml workflow:` wins first, then `Config.load(project_root)["default_workflow"]`, then built-in `coding`. It is deliberately not registry-validated during config load; unknown names fail when `Hive::Task` resolves the workflow so the error is tied to the affected task path. `dependency_gate_stage` belongs to the depending project, defaults to `8-finalize`, and may be set only to `9-done`; dependency admission also verifies that the prerequisite's own workflow can actually reach the selected gate.

`worktree_root: nil` is intentional — the actual default is computed lazily by `Worktree#worktree_root` as `~/Dev/<project>.worktrees`. `permissions: "yolo"` preserves existing launch behavior unless a project or stage opts into a narrower Claude tool scope; `Config.permission_spec(cfg, stage)` returns the exact stage spec (`plan.permissions`, `review.ci.permissions`, reviewer-entry `permissions`, etc.) when present, otherwise the project default, with no field merge. `review.reviewers` defaults to `[]`; the recommended set ships live (uncommented) in `templates/project_config.yml.erb` so a fresh `hive init` produces a populated reviewer list. `review.adhoc.reviewers: nil` inherits `review.reviewers`, while an explicit `[]` means zero ad-hoc reviewers, and `review.adhoc.fix: false` keeps ad-hoc PR reviews review-only unless an operator opts into local fix commits with `true`. `daemon.auto_retry.enabled` is **inert**: automatic `ERROR` / `REVIEW_ERROR` retry is unconditional and governed by a single backoff ladder in `RecoveryCoordinator`. The key is still shape-validated so an existing config with a typo fails loudly rather than looking meaningful; to pause a project use `daemon.enabled: false`. `patrol.review.reviewers` defaults to the single native Codex reviewer (`name: codex-native-review`, `kind: codex_review`), which runs Codex's built-in `review` subcommand and needs no CE skill; fresh init can optionally add Codex or Claude CE `ce-code-review` entries for patrol PRs. `daemon.max_concurrent_patrol_scans` (default `1`, validated `>= 1`) is a **per-project** cap bounding daemon-scheduled `hive patrol PROJECT` scans on a **separate** in-flight budget from task dispatch: a long codex-backed scan never consumes a `daemon.max_concurrent_runs` task slot — scans are tagged `kind: :patrol_scan` in the dispatcher and excluded from the per-project/global task caps, counted only against this independent cap. `ConcurrencyController#can_dispatch_patrol_scan?` counts only the **given project's** running scans (`entry[:kind] == :patrol_scan && entry[:project] == project`), so the default `1` means one scan per project at a time and **different projects patrol in parallel** rather than being serialized/starved by a global count (see `→ :patrol_scan_cap`).

**Patrol is opt-in.** `resolve_patrol_mode!` derives scheduling and the daily
scheduled-discovery ceiling for each Patrol engine when
`mode:` is explicitly present. A config with no Patrol section, or one without
`mode:`, remains disabled. `medium` is the init prompt default, not a
config-resolution default. The modes are `ultrapatrol` (timer/30m), `high`
 (timer/2h), `medium` (timer/4h), `low` (new commits), and `off`; their daily
per-engine launch values are respectively 16, 8, 4, 2, and disabled for
ordinary scheduling. The legacy `max_agent_spawns_per_day` key is inert and
cannot distort either engine lane. Modes never change finding/PR
caps, diversity, confidence, or alpha gates. Patrol has no token budget or
token-based admission; usage totals remain telemetry. `hive migrate`, including
the automatic fleet migration run by `hive update`, deletes retired token,
per-cycle launch, architecture-specific launch, USD, and multiplier keys, then
requests one daemon restart after the fleet succeeds.
Standalone migration requests the normal best-effort restart immediately after
that independent config commit, before later project-specific preparation can
fail; fleet mode injects the coalescing restart request instead.

`patrol.max_features_per_cycle` defaults to 12, is validated as an integer at
least one, bounds each ordinary-patrol reviewer batch, and is likewise not
changed by `patrol.mode`; `max_fix_attempts_per_cycle` separately bounds fix
attempts. `patrol.max_rework_cycles` defaults to 2 and is a non-negative
integer. It bounds completed independent Patrol Fix review decisions: once the
cap is reached, `rework` is removed from the allowed prompt and strict report
parser rather than accepted and discarded after the model returns. Ordinary
component mapping defaults to four owned and four context files; its reviewer
initially receives only up to four owned files selected under a 32 KiB source
budget. Architecture mapping retains its wider six-owned and six-context
logical component, then applies the
same four-file/32 KiB initial review view. The first entrypoint is retained even
when it alone is larger.

**Architecture patrol is discovery-only.**
`Config::DEFAULTS["refactor_patrol"]["enabled"]`, `auto_fix.enabled`, and
`issue_filing.enabled` are false, so missing or older partial config grants no
new discovery, mutation, or remote-write authority. Fresh init recommends the
discovery engine and writes only that answer. Accepted findings enter the
shared Patrol Fix workflow. Existing projects opt in explicitly.
The block also owns an optional refactor identity (`agent`, `model`, `effort`)
that inherits the resolved execute identity field by field, plus optional
historical auto-fix identity overrides that can configure downstream Patrol
Fix identity. It
also owns confidence/run caps, language-neutral include/exclude rules,
`docs|format|lint|public_contract|typecheck|test` commands, actual patch caps,
and the categorical `fix`/`discuss`/`dismiss` route policy. The default
`max_theses_per_feature: 1` treats a finding as an exception, not a quota.
`max_theses_per_run` is
a strict global reviewer-output budget; slices not reached after it is exhausted
remain incomplete for resume. `max_review_seconds_per_run` defaults to 3600,
must be numeric and at least 1, and caps the whole discovery review pass rather
than resetting for every mapped feature. A fixed, non-configurable 12-slice
safety bound separately prevents empty reviews from producing unbounded agent
fan-out; it is not another allowance. A configured `commands.public_contract` is an
authoritative project-owned check for every automatic fix that changes a source
or known public-surface path, while built-in declaration guards remain in
force. Architecture mapping reads `refactor_patrol.review.max_owned_files` and
`max_context_files` ahead of ordinary patrol settings, so patrol defaults cannot
silently shrink an explicitly widened architecture slice. Ordinary patrol
explicitly selects its own review scope and therefore does not inherit these
architecture values. Merge intake snapshots every action-relevant value. Current config can
narrow or revoke that snapshot, but cannot broaden an already queued
occurrence. When the architecture scheduler cannot load a registered project's
config, it durably blocks due work as
`project_config_unavailable` during candidate enumeration or reservation
instead of silently dropping that project. See [[commands/refactor-patrol]].

## Digest config

Hive's broad activity record uses a new global `daily_digest:` namespace. The
old top-level `digest:` PRDigest-adapter block remains rejected, so an upgraded
configuration can never silently acquire new behavior.

Defaults are deliberately effect-free:

```yaml
daily_digest:
  enabled: false
  time_zone: null
  coverage_started_at: null
  initial_membership: null
  first_interval: null
  materialization_interval_sec: 300
  freshness_budget_sec: 900
  telegram:
    enabled: false
    hour: 9
```

`hive setup`, `hive migrate`, and `hive migrate --all` call the idempotent
`DailyDigest::Migration`. Under the global config lock it detects or validates
an IANA zone, captures the exact UTC coverage-start instant and normalized
registered-project membership, and persists the first interval atomically. It
preserves an existing initialized block and never flips `enabled`. Detection
failure leaves the feature disabled with exact remediation; unrelated daemon
automation and standalone per-project `hive migrate` work continue.

When `enabled: true`, all four identity fields (`time_zone`,
`coverage_started_at`, `initial_membership`, and `first_interval`) are required.
The zone must exist in TZInfo, intervals must validate, cadence/freshness values
must be positive integers, and the Telegram hour must be `0..23`. A disabled
upgraded configuration may temporarily omit initialization fields so the daemon
can omit only digest schedulers and continue other work.

`daily_digest.enabled: false` stops refresh, catch-up, close, recovery, and
scheduled delivery without deleting persisted records, frontiers, tombstones,
or delivery receipts; pure CLI/Web reads remain available. Telegram requires
both the parent feature and `daily_digest.telegram.enabled: true`. It uses the
existing bot token environment and `Config.telegram_chat_id!`; the first
positive ID in `bot.chat_id_allowlist` is the sole private recap destination.
See [[modules/daily-digest]] and [[commands/digest]].

Registered-project mutations append all membership evidence indefinitely and
maintain a persisted `project_membership_event_ids` lookup alongside the
history. This makes duplicate suppression constant-time without discarding
history. Digest coverage parses and sorts that history once per refresh rather
than once for every interval.

## Screenote config

`Hive::Config.load_global_screenote` reads the global `screenote:` block,
deep-merges it over `Config::DEFAULTS["screenote"]`, applies
`HIVE_SCREENOTE_BASE_URL`, validates the shape, and returns a hash with
`base_url`. `screenote.base_url` defaults to `https://screenote.ai` and may be
overridden for self-hosted or staging Screenote deployments.

`screenote.api_token` and `HIVE_SCREENOTE_API_TOKEN` are intentionally removed.
If a YAML config still sets `screenote.api_token`, validation raises the
migration error "Screenote now connects via OAuth — run `hive connect
screenote`." OAuth material is stored separately by
`Hive::Screenote::CredentialStore` in `~/.config/hive/screenote.json` (or
`HIVE_HOME/screenote.json`) with mode `0600`; the file contains the access token,
expiry, client id, issuer, MCP resource URL, base URL, and default
`project_id`. See [[commands/screenote]] and [[stages/artifacts]].

## Module functions

Installable-module selections are project-local runtime configuration, stored
under `<hive_state_path>/modules/` rather than as shared user configuration.
Each active pointer references an immutable normalized generation and a
digest-addressed configuration snapshot containing effective settings, hook
states, bindings, and redacted grants. Runtime events, decisions, attempts,
artifacts, watermarks, and patrol stores live outside those generations.

During the 0.x compatibility period, `patrol.*` and `refactor_patrol.*` remain
accepted projections into the canonical first-party module settings. The
adapters retain one authoritative state store and warn with exact replacements;
they do not create a second writable copy of patrol checkpoints or ledgers.

| Function | Returns / does |
|----------|----------------|
| `hive_home` | `ENV["HIVE_HOME"] || Hive::Paths.config_home` (XDG default `~/.config/hive`; legacy `~/Dev/hive/config.yml` is migrated) |
| `global_config_path` | `<hive_home>/config.yml` |
| `hive_state_dir(project_root, name = ".hive-state")` | `<project_root>/<name>` |
| `load(project_root)` | Reads `<project_root>/.hive-state/config.yml`, treating only an initial `ENOENT` as absent and rewrapping traversal, symlink-loop, read, and YAML parse failures as path-bearing `ConfigError`s; validates raw project root keys against static keys plus registered workflow stage names; then recursively deep-merges onto DEFAULTS, validates values, and returns a Hash with `"project_root"` injected. |
| `registered_projects` | Reads the authoritative global config; returns `[{name, project_id, path, real_path, hive_state_path, repository_identity}, …]` (runtime paths `expand_path`-ed). `real_path` is the immutable canonical anchor captured at enrollment and is not recomputed by this projection. The repository identity is a normalized canonical `origin` captured at enrollment when available. The ordinary reader retains the existing one-off move of a legacy registry into XDG config storage. |
| `find_project(name)` | First entry from `registered_projects` matching `name` (or `nil`). |
| `register_project(name:, path:, repository_identity: :detect)` | Adds or replaces an entry under `config.yml.lock`; stores private `real_path` for relink detection and the transport-independent canonical `origin` identity when detectable. Before writing, canonicalizes the proposed `.hive-state` root through its nearest existing ancestor and rejects a distinct registered project identity that would share the same state root; a same-name replacement is excluded from its own conflict check. Enrollment still succeeds without an origin, but an explicit cross-project dependency targeting that project later fails closed until identity is configured and re-enrolled. When an activated runtime database exists, the complete authoritative registry is projected to `projects` after the YAML mutation; omitted rows become inactive rather than remaining schedulable. Pre-activation enrollment never creates or migrates SQLite. |
| `unregister_project(name)` | Index-based delete (not `Array#-`, which would clear duplicate-content rows); `to_s`-symmetric name match so an Integer `name:` in YAML still resolves; rewrites under `config.yml.lock`, then refreshes the activated SQL projection. |
| `prune_missing_projects!(dry_run:)` | Drops rows whose `path` is not a directory, whose stored valid `real_path` no longer matches the current target, OR whose shape is invalid (non-Hash, missing `path`); reads and, unless `dry_run`, rewrites under `config.yml.lock`. |
| `load_global_config(path)` | Reads + `YAML.safe_load`; rewraps `Psych::SyntaxError` AND `Errno::EACCES`/`EISDIR` as `ConfigError` (exit 78) so `chmod 000` on the file surfaces as bad-config, not internal-error. |
| `telegram_chat_id!` | Returns the first positive allowlisted Telegram chat or raises a configuration error; used as the sole private destination by Hive's answer digest and opt-in daily recap. |
| `load_global_web` | Reads global config, deep-merges the `web` section onto web defaults, fills `session_secret_file` with `<state_home>/.web.session_secret` when omitted, validates bind/port/origin/GitHub fields, and returns the merged web config for [[commands/web]]. |
| `global_web_defaults` | Returns a deep copy of `DEFAULTS["web"]` with the state-home session-secret path injected. |
| `update_global_config!` | Locks sibling `config.yml.lock`, yields the mutable global config Hash, then writes via tempfile + `fsync` + atomic rename. Use for read-modify-write registry/global-config changes. |
| `write_global_config!(data)` | Direct locked atomic write for the global config; restores existing mode bits after tempfile creation so umask cannot narrow them, leaves a sticky sibling lock file, and rewraps lock/write filesystem errors as `ConfigError`. |
| `merge_defaults(data)` | Calls `deep_merge(deep_dup(DEFAULTS), data)` — **recursive** Hash-into-Hash merge. |
| `stage_resource_limit(cfg, field, stage_name, descriptor_default:, fallback:)` | Resolves an explicitly authored, non-null project limit before the descriptor default, then a merged config/default fallback. `Config.load` stores private raw-key provenance so `DEFAULTS` entries cannot masquerade as project overrides; synthetic config hashes retain present-key precedence. |
| `claude_mode(cfg)` | Returns `:tmux` or `:headless` after validating `claude.mode`. |
| `claude_cli_flags(cfg)` | Returns the Claude-only argv fragment for model/effort pins: `["--model", model]` unless `model` is blank/`inherit`; `["--effort", effort]` only for explicit non-default effort values. Shared by headless `Hive::Agent` and tmux `Hive::ClaudeLauncher`. |
| `claude_permission_mode(cfg)` | Returns the configured Claude Code permission mode, defaulting to `bypassPermissions`. Valid values mirror Claude Code: `acceptEdits`, `auto`, `bypassPermissions`, `default`, `dontAsk`, `plan`. |
| `permission_spec(cfg, stage)` | Returns a stage's complete `permissions:` spec when declared; otherwise returns the project default. Dotted review paths are supported. |
| `deep_merge(base, override)` | Recursive merge: Hash-vs-Hash recurses; everything else (scalar, Array, mismatched types) replaces. |
| `deep_dup(obj)` | Recursive Hash/Array deep-copy. |

## Recursive deep-merge

Closes doc-review F3 (P0). The previous implementation was a **single-level** `Hash#merge` that wiped sibling keys whenever a user override touched a 3+-deep nested path (e.g. `review: { ci: { command: "bin/ci" } }` would erase every other `review.ci.*` and `review.*` default).

Rules:

- **Hash + Hash** → recurse, key-by-key.
- **Array** (any depth) → replace wholesale. Per-element merge has ambiguous semantics for ordered lists (e.g. `review.reviewers` and `patrol.review.reviewers`), so all Array-typed settings replace wholesale. (Earlier wiki/code comments misattributed this to ADR-018, which is actually the per-CLI-isolation trust-model amendment — unrelated.)
- **Scalar / nil / type mismatch** → override wins.

`budget_usd` / `timeout_sec` need an extra provenance step for project-authored
workflow stages. A loaded config contains both authored keys and merged Hive
defaults, so generic agent/council runners call `stage_resource_limit` rather
than reading `cfg.dig` directly. Resolution order is explicit non-null project
key → descriptor default → merged Hive default/fallback.

## Validation (`Config.validate!`)

Project root-key validation is deliberately performed only in `Config.load`
against the raw project mapping. `Config.validate!` remains the shared
post-merge value validator because global config paths also call it with keys
such as `registered_projects`. It runs after merge so a default value can never
trigger a failure — only user input does. Both boundaries raise
`Hive::ConfigError` (the single class for all "config is bad" cases). Key checks
include:

1. **`validate_hash_shaped_keys!`** — every hash-shaped top-level key (`brainstorm`, `claude`, `models`, `plan`, `execute`, `conditions`, `open_pr`, `artifacts`, `finalize`, `budget_usd`, `timeout_sec`, `review`, `agents`, `daemon`, `web`, `screenote`, `babysitter`, `patrol`, `refactor_patrol`, `answer_digest`, `bot`, `rebase`) must be a Hash when present. Catches scalar/nil/integer overrides (e.g. YAML `brainstorm: claude`, `budget_usd: ~`, `timeout_sec: 600`) that would otherwise survive `deep_merge` and crash later as `TypeError`/`NoMethodError`.
2. **`validate_reviewers!` / `validate_review_adhoc!`** — `review.reviewers` must be an Array (nil fails with a hint to remove the key vs. set `[]`). Each entry must be a Hash. `name` and `output_basename` must be unique across the list (basename uniqueness prevents concurrent file-write collisions on `reviews/<basename>-NN.md`). Empty/whitespace `output_basename` is rejected (would yield `reviews/-01.md`). Each entry's `agent` is checked via `validate_agent_name!`. `review.adhoc.reviewers` is either nil or the same reviewer-entry Array shape, and `review.adhoc.fix` is boolean.
3. **`validate_review_fix_auto_commit!`** — `review.fix` and `review.fix.auto_commit` must stay Hash-shaped. `review.fix.auto_commit.sign_policy` is optional and must be one of `inherit`, `bypass`, or `fail`; `scope_check.enabled` must be boolean; `scope_check.allowed_paths` / `denied_paths` must be relative path-glob arrays without traversal, absolute paths, or null bytes.
4. **`validate_role_agent_names!`** — every stage/review role agent path is checked via `validate_agent_name!`.
5. **`validate_claude_mode!`** — `claude.mode` must be `tmux` or `headless`.
6. **`validate_claude_permission_mode!`** — `claude.permission_mode` must be one of `acceptEdits`, `auto`, `bypassPermissions`, `default`, `dontAsk`, or `plan`. Both the tmux launcher and the headless `-p` path resolve this value to the same Claude Code flags via `AgentProfile#permission_flags`: `bypassPermissions` → `--dangerously-skip-permissions`, any other mode → `--permission-mode <mode>`. Fresh init suggests `bypassPermissions` so dogfood runs do not pause on file-operation approval prompts, while `auto` keeps Claude Code auto-mode rules.
7. **`validate_permissions!`** — top-level, stage-level, review-role, and reviewer-entry `permissions:` specs are parsed by `Hive::PermissionScope` and must be `yolo`, `read-only`, or a valid `scoped` map. Shape errors, unknown presets/keys, malformed `Tool(specifier)` rules, unresolvable file-rule paths, unsupported file-tool path rules (use `Read(path)` / `Edit(path)`), and `bash:` plus `tools:` fail during config load; runner capability is checked later when the stage profile is known. Scoped rules run in Claude `dontAsk` mode. Task-relative `Read(path)` / `Edit(path)` rules are resolved to absolute permission patterns at spawn time, including Claude's POSIX drive form on Windows. Qualified `Edit` covers every built-in file-edit tool, so all file-edit denies are removed to prevent a bare deny from overriding the path grant. Claude merges these CLI rules with loaded managed/user/project/local permission settings, so the descriptor expresses the requested Hive scope rather than overriding trusted operator policy from those sources.
8. **`validate_babysitter!`** — `babysitter.enabled` and `babysitter.dry_run` must be booleans; `interval` must be integer seconds or a `\d+[smh]` string; `max_concurrent_prs`, `budget_minutes`, and `budget_usd` must be integers >= 1; `labels_ignore` must be an array of strings.
9. **`validate_patrol!`** — `patrol.mode` must be one of `ultrapatrol`, `high`, `medium`, `low`, or `off`; `patrol.enabled`, `patrol.draft_prs`, and `patrol.review_prs` must be booleans when present; `trigger` must be one of the patrol trigger enum values; confidence, 0–100 alpha, per-feature/run counts, interval, `scheduled_discovery_launches_per_engine_per_day >= 2`, and command shape are validated before the scheduler or `hive patrol` command can run. The selected mode always projects the closed 2/4/8/16 table; the projected key is not an independent override. `patrol.review.reviewers` uses the same reviewer-entry validation as `review.reviewers`, but it is a separate list used only by synthetic `Patrol: ...` review tasks.
10. **`validate_refactor_patrol!`** — validates discovery/auto-fix/issue booleans and nested shapes, agent names, confidence/run counts, the whole-run review deadline, include/exclude paths, all six commands including `docs` and `public_contract`, and semantic scope plus contract/dependency policy booleans. File count and diff size are publication evidence, not config or mutation gates; runtime mutation remains protected by root/path confinement, `.hive-state` and protected-path checks, secret scanning, dependency and public-contract guards, and applicable validation commands. Invalid side-effect policy fails at config load, not in a background action.
11. **`validate_daemon!`** — daemon numeric bounds, booleans, and nested hashes are checked before the daemon starts. The nested `daemon.auto_retry` block must be a hash, and `daemon.auto_retry.enabled` must be boolean when present.
12. **`validate_dependency_gate_stage!`** — `dependency_gate_stage` must be exactly `8-finalize` or `9-done`. Runtime admission then checks reachability against the prerequisite task's selected workflow rather than assuming the coding descriptor.
13. **`validate_model_routing_capabilities!`** — after structural role and
patrol validation, resolves exact/coarse routes for enabled, reachable built-in
calls and asks each already-selected profile to validate only its effective
model/effort controls. Fully shadowed coarse fields and disabled optional calls
do not fail. This pure barrier runs before legacy warnings or runtime effects.

Bot attachment capture settings are validated with the other bot numeric
keys: `bot.idea_attachment_max_bytes` defaults to 20 MiB and may not
exceed Telegram's hosted Bot API file-download cap,
`bot.idea_attachment_max_count` defaults to 10, and
`bot.idea_draft_ttl_sec` defaults to 900 seconds. Voice transcription
settings live under `bot.transcription`: the block must be a Hash;
`enabled` must be boolean when present; `endpoint`, `model`, and
`api_key_env` must be non-empty strings; `max_retries`,
`retry_backoff_sec`, and `timeout_sec` must be integers >= 0;
`no_speech_threshold` must be a number between 0 and 1; and
`supported_languages` must be an array of non-empty strings. An empty
language array is accepted and means "do not filter language". See
[[commands/bot]] and [[modules/bot]].

Global web settings are validated separately for [[commands/web]]:
`web.bind` must be a non-empty string, `web.port` must be an integer in
`1..65535`, `web.origin` must start with `http://` or `https://`,
`web.local_loopback` must be boolean,
`web.github` must be a hash, optional `web.github.owner` and
`web.github.client_id` must be non-empty strings when set, and
`web.session_secret_file` must be a non-empty string when set. A blank/missing
`web.github.owner` is valid and means the first successful owner-gated GitHub
device-flow login claims the instance by writing that owner under the global
config lock. This includes native Hive web reached through a non-loopback Host;
only the optional connection from verified literal-loopback access does not
claim. Pre-setting the owner keeps the older pinned-owner gate. GitHub sign-in
uses the OAuth device flow (see [[decisions]] ADR-036), so no client secret
exists anywhere; `web.github.client_id` defaults to the shared Hive web OAuth
app — public by design, since device flow is a public-client grant.
`web.local_loopback: true` is the local and managed-service default: when `hive web`
binds `localhost`, `::1`, or `127.0.0.0/8`, the CLI exports
`HIVE_WEB_LOCAL_LOOPBACK=1` and Rails skips GitHub login only for requests whose
actual socket peer (`REMOTE_ADDR`, not proxy-expanded `remote_ip`) is also
loopback and whose normalized Host is a literal loopback address. Any other
hostname is accepted without configuration but uses the GitHub owner gate,
even through a localhost reverse proxy. Proxies should preserve the incoming
Host; the trust check ignores `X-Forwarded-Host` and parses the literal
`HTTP_HOST` authority, including bracketed IPv6. A proxy or TCP forwarder that
lets an untrusted client send `Host: localhost` becomes part of the local trust
boundary and must authenticate or restrict clients. Setting
`web.local_loopback` to `false` forces the GitHub owner gate even on literal
loopback.

Shared Rails environment input is resolved centrally by
`Hive::Web::Environment`. The canonical keys are `HIVE_WEB_APP_DIR`,
`HIVE_WEB_ORIGIN`, `HIVE_WEB_STORAGE_DIR`, `HIVE_WEB_LOCAL_LOOPBACK`,
`HIVE_WEB_DIFF_TIMEOUT_SEC`, and `HIVE_WEB_CLONE_TIMEOUT_SEC`. Their six named
native-web `HIVEBOX_*` aliases remain accepted through the next major release:
blank is unset, canonical wins conflicts, and alias use produces a deduplicated
migration warning. Container-only Hivebox image/name/bind/port/data/repo,
session-secret, and supervisor variables are not aliases and never warn.

The current `hive init` JSON summary envelope (`schemas/hive-init.v2.json`) carries the chosen architecture-patrol discovery value as `refactor_patrol_enabled`, alongside the launch and permission-mode choices. The retained v1 schema is a compatibility artifact. See [[commands/init]].

`claude.model` / `claude.effort` pin hive-launched claude sessions:
`model: default` (the default) uses Claude Code's live alias for ITS
recommended model — no hardcoded name, no inheriting the operator's
interactive selection; `inherit` omits the flag; aliases/full names pass
through. `effort: default` omits `--effort` (Claude Code's own tier);
low/medium/high pass through. `Hive::Config.claude_cli_flags(cfg)` builds
the argv fragment used by the tmux wrapper, headless `Hive::Agent`, and
ordinary Patrol's shared review/fix launch envelope whenever no exact or
coarse `models:` route overrides it.

`validate_agent_name!` accepts `nil` (field is optional) and otherwise requires the value to resolve via `Hive::AgentProfiles.registered?`. Failure messages include the registered profile names so the agent reading the error learns the valid set.

`describe_source(path)` annotates error messages with `"(defaults; no file present)"` when the candidate config file does not exist, so the user is pointed at the right path even when the failure comes from an injected reviewers list rather than a real file.

## `agents.*` overrides are plumbed at spawn time

`agents.<name>.{bin, env_override, min_version}` in per-project config now actually take effect (LFG-5). `Hive::AgentProfiles.lookup(name, cfg: cfg)` overlays `cfg.dig("agents", name)` onto the registry profile via `AgentProfile#with_overrides`, returning a new frozen profile. Unknown override keys raise `Hive::ConfigError`. Every spawn site in `lib/hive/stages/review.rb`, `review/ci_fix.rb`, `review/triage.rb`, `review/browser_test.rb`, and `reviewers/agent.rb` threads `cfg` into the lookup. Legacy callers passing `cfg: nil` get the registry profile unchanged.

OpenCode adds only typed, non-secret overrides under `agents.opencode`:
`config_path`, an inline non-secret `config` object, `credential_env` names,
and explicit `plugins`.
Relative source paths resolve against `project_root`. Credential values, raw
argv, raw environment maps, unknown agent blocks, and unknown override keys
are rejected during config validation. Native OpenCode config, plugins,
project discovery, sessions, and login are used in place. A non-empty
`credential_env` explicitly selects environment authentication; Hive never
accepts or stages a credential file.

Every `ROLE_AGENT_PATHS` entry accepts `agent: opencode`, but none of
`DEFAULT_GLOBAL_AGENTS`, stage defaults, reviewer councils, or fallback lists
select it. Routed OpenCode roles normally require an exact
`models.<role>.model: provider/model`; when that field is absent, only an
explicit selected OpenCode config whose top-level `model` is exact may supply
the default. Skill-bearing OpenCode plan roles use `/ce-plan` by default and
must pass native skill/plugin readiness before spawn.

Patrol Fix can instead keep its complete repair identity under
`patrol.fix.{agent,model,effort}`. Discovery remains on `patrol.agent`. When the
two identities use different providers, use `models.patrol_review` for a
discovery-only route; `models.patrol` is deliberately coarse and therefore
applies to both review and fix identities.

`timeout_sec.review_ci` (default 3600) is enforced as a hard per-attempt deadline for both `Review::CiFix#run_ci_once` and `Review::RemoteCi` hosted-check settlement. Local subprocess expiry TERM/KILLs the pgid; hosted settlement expiry fails closed on the exact unsatisfied PR head. `review.github_checks.enabled` defaults true and is independent of `review.github_publish.enabled`: the former gates exact-head completion, while the latter only controls reviewer-comment mirroring.

## Stage runners reach into config like this

```ruby
cfg.dig("budget_usd", "brainstorm")
cfg.dig("timeout_sec", "execute_implementation")
cfg.dig("review", "ci", "agent")
cfg.dig("review", "reviewers")
cfg.dig("review", "adhoc", "reviewers")
cfg.dig("review", "adhoc", "fix")
cfg.dig("review", "github_checks", "enabled")
cfg.dig("plan_review", "routes", "adversarial")
cfg.dig("plan_review", "coverage", "required")
cfg.dig("babysitter", "enabled")
cfg.dig("babysitter", "max_concurrent_prs")
cfg.dig("patrol", "review_prs")
cfg.dig("patrol", "fix", "agent")
cfg.dig("patrol", "review", "reviewers")
cfg.dig("daemon", "auto_retry", "enabled")
cfg.dig("bot", "chat_id_allowlist")
cfg["worktree_root"]
```

## `HIVE_HOME` override

Tests use `with_tmp_global_config` (`test/test_helper.rb:30`) to point `HIVE_HOME` at a tmp dir, ensuring no test ever writes the real global config.

## Tests

- `test/unit/config_test.rb` — defaults, recursive deep-merge, register/find round-trip, malformed YAML, reviewer/agent validation, ordinary patrol, architecture-patrol consent/policy validation, removed PR-digest config rejection, and answer-digest/bot validation.
- `test/unit/web/config_test.rb` — global web defaults and invalid web port rejection.

## Backlinks

- [[commands/init]] · [[commands/new]] · [[commands/run]] · [[commands/status]] · [[commands/babysit]] · [[commands/patrol]] · [[commands/refactor-patrol]] · [[commands/web]]
- [[modules/agent]] · [[modules/plan_review]] · [[state-model]]
