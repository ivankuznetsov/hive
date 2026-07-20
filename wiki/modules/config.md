---
title: Hive::Config
type: module
source: lib/hive/config.rb
created: 2026-04-25
updated: 2026-07-20
tags: [config, yaml, validation]
---

**TLDR**: Two YAML configs — global at `~/.config/hive/config.yml` (registered projects plus daemon, bot, digest, update, web, and Screenote base-url settings, including voice-transcription defaults; `HIVE_HOME/config.yml` when overridden, legacy `~/Dev/hive/config.yml` when migrated) and per-project at `<project>/.hive-state/config.yml` (default branch, default workflow, worktree root, budgets, timeouts, **stage agents**, project/top-level and per-stage `permissions`, project-global `claude.mode`/`claude.permission_mode` plus `claude.model`/`claude.effort` pins, review-stage roles, daemon enrollment, experimental babysitter enrollment, ordinary patrol, and scheduled architecture patrol). Architecture-patrol discovery, issue review output, and automatic mutation remain separate settings. Fresh init enables issue output with discovery as the default review surface; legacy or hand-written config that omits `issue_filing.enabled` remains effect-free. `Config.load(project_root)` captures frozen raw field provenance for implementation-owning `agent`/`model`/`effort` keys before it **recursively** deep-merges project values onto `Config::DEFAULTS`, then runs `validate!`. Arrays are replaced wholesale, never per-element merged. Screenote OAuth tokens live outside YAML in `screenote.json`, created by `hive connect screenote`.

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
    "review_fix" => 500, "review_browser" => 100, "patrol" => 100, "digest" => 50
  },
  "timeout_sec" => {
    "brainstorm" => 1800, "plan" => 3600,
    "execute_implementation" => 14400, "open_pr" => 1800,
    "artifacts" => 3600, "finalize" => 1800,
    "review_ci" => 3600, "review_triage" => 1800,
    "review_fix" => 14400, "review_browser" => 3600, "patrol" => 3600, "digest" => 1800
  },
  # Stage-level agent defaults remain for independently owned stages.
  # Implementation-owned downstream stages intentionally omit active
  # agent/model/effort defaults so the persisted execute owner applies.
  "brainstorm" => { "agent" => "claude", "runtime" => "headless" }, # runtime is legacy read-back-compat
  "plan"       => { "agent" => "claude" },
  "execute"    => { "agent" => "claude" },  # rendered template recommends `codex`
  "open_pr"    => {},
  "artifacts"  => { "agent" => "claude" },
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
    "max_prs_per_cycle" => 3,
    "max_tokens_per_cycle" => 200_000,
    "max_tokens_per_day" => 600_000,
    "max_tokens_per_agent" => 50_000,
    "max_agent_spawns_per_cycle" => 3,
    "max_agent_spawns_per_day" => 8,
    "max_architecture_unmetered_spawns_per_day" => 96,
    "max_budget_usd_per_agent" => 25,
    "architecture_budget_multiplier" => 2,
    "fix_budget_multiplier" => 2,
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
  "digest" => { "enabled" => false, "agent" => nil, "max_catchup_days" => 7 },
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

`worktree_root: nil` is intentional — the actual default is computed lazily by `Worktree#worktree_root` as `~/Dev/<project>.worktrees`. `permissions: "yolo"` preserves existing launch behavior unless a project or stage opts into a narrower Claude tool scope; `Config.permission_spec(cfg, stage)` returns the exact stage spec (`plan.permissions`, `review.ci.permissions`, reviewer-entry `permissions`, etc.) when present, otherwise the project default, with no field merge. `review.reviewers` defaults to `[]`; the recommended set ships live (uncommented) in `templates/project_config.yml.erb` so a fresh `hive init` produces a populated reviewer list. `review.adhoc.reviewers: nil` inherits `review.reviewers`, while an explicit `[]` means zero ad-hoc reviewers, and `review.adhoc.fix: false` keeps ad-hoc PR reviews review-only unless an operator opts into local fix commits with `true`. `daemon.auto_retry.enabled` defaults to `true` and can be set to `false` to disable the recoverable terminal-error healer while leaving ordinary daemon dispatch enabled. `patrol.review.reviewers` defaults to the single native Codex reviewer (`name: codex-native-review`, `kind: codex_review`), which runs Codex's built-in `review` subcommand and needs no CE skill; fresh init can optionally add Codex or Claude CE `ce-code-review` entries for patrol PRs. `daemon.max_concurrent_patrol_scans` (default `1`, validated `>= 1`) is a **per-project** cap bounding daemon-scheduled `hive patrol PROJECT` scans on a **separate** in-flight budget from task dispatch: a long codex-backed scan never consumes a `daemon.max_concurrent_runs` task slot — scans are tagged `kind: :patrol_scan` in the dispatcher and excluded from the per-project/global task caps, counted only against this independent cap. `ConcurrencyController#can_dispatch_patrol_scan?` counts only the **given project's** running scans (`entry[:kind] == :patrol_scan && entry[:project] == project`), so the default `1` means one scan per project at a time and **different projects patrol in parallel** rather than being serialized/starved by a global count (see `→ :patrol_scan_cap`).

**Patrol is opt-in.** `resolve_patrol_mode!` runs on the raw YAML before `merge_defaults` and only derives/injects mode knobs when `mode:` is **explicitly present** in the raw config (`return unless nested_key?(data, "patrol", "mode")`). A config with **no patrol section** — or a patrol section that omits `mode:` — injects nothing and falls through to `DEFAULTS["patrol"]["enabled"] = false`, so patrol stays **disabled**. `medium` is the default offered by the `hive init` *prompt*, never a config-resolution default. The explicit modes are `ultrapatrol` (`timer`/30m, 800k tokens and 10 launches per cycle, 2.4m/36 per UTC day, 100k tokens and 100 budget-equivalent units per agent), `high` (`timer`/2h, 400k/6 per cycle, 1.2m/18 per day, 75k/50 per agent), `medium` (`timer`/4h, 200k/3 per cycle, 600k/8 per day, 50k/25 per agent), `low` (`new_commits`, 100k/1 per cycle, 200k/2 per day, 40k/10 per agent), and `off` (`enabled: false`). `fix_budget_multiplier` defaults to `2` and widens only an ordinary fix agent's streamed per-agent limit; cycle/day token and launch totals stay shared. `architecture_budget_multiplier` defaults to `2`, widening architecture stages' per-cycle token/launch limits and per-agent token limit while leaving the native budget-equivalent guard and shared project/day token ceiling unchanged; architecture fixes do not compound both multipliers. Metered architecture launches are accounted separately and never consume the mode's ordinary daily launch quota. `max_architecture_unmetered_spawns_per_day` defaults to `96` and is the independent durable backstop when an architecture provider repeatedly omits token counts. The `max_budget_usd_per_agent` name follows agent CLI terminology; with subscription-backed agents it is not a separate payment. The mode never changes finding/PR caps, per-feature diversity, confidence, or alpha gates. Explicit granular knobs always win over a set mode and survive the deep-merge.

`patrol.max_features_per_cycle` defaults to 12, is validated as an integer at
least one, bounds each ordinary-patrol reviewer batch, and is likewise not
changed by `patrol.mode`. The runtime batch is further capped by the tighter
remaining cycle or shared UTC-day launch headroom: normal runs reserve as many
launches as possible up to `max_fix_attempts_per_cycle` while retaining one
review, and dry runs may spend the whole remaining envelope on review. Ordinary
component mapping defaults to four owned and four context files; its reviewer
initially receives only up to four owned files selected under a 32 KiB source
budget. Architecture mapping retains its wider six-owned and six-context
logical component for deterministic leverage measurement, then applies the
same four-file/32 KiB initial review view. The first entrypoint is retained even
when it alone is larger.

**Architecture patrol separates discovery, review output, and mutation.**
`Config::DEFAULTS["refactor_patrol"]["enabled"]`, `auto_fix.enabled`, and
`issue_filing.enabled` are false, so missing or older partial config grants no
new discovery, mutation, or remote-write authority. Fresh init recommends the
full workflow, writes that answer explicitly to discovery, auto-fix, and issue
filing, and uses issues as the fallback review surface. Existing projects opt
in explicitly.
The block also owns the
review agent, confidence/run caps, language-neutral include/exclude rules,
`docs|format|lint|public_contract|typecheck|test` commands, actual patch
caps, leverage weights, the proposal-wide `min_leverage_score` floor
(default `0.25`), and the separate issue threshold. The default
`max_theses_per_feature: 1` treats a finding as an exception, not a quota; a
complete slice whose maximum possible leverage is below the floor skips its
agent launch. `max_theses_per_run` is
a strict global reviewer-output budget; slices not reached after it is exhausted
remain incomplete for resume. `max_review_seconds_per_run` defaults to 3600,
must be numeric and at least 1, and caps the whole discovery review pass rather
than resetting for every mapped feature. A configured `commands.public_contract` is an
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

`Hive::Digest.run` defaults to `Config.load_global_digest_config`, which
deep-merges the global config with `Config::DEFAULTS`, injects bot runtime
paths, validates the result, and returns the config-shaped hash the digest
pipeline needs. Direct callers can still pass `cfg:` explicitly. The relevant
keys are:

- `digest.agent`, then `patrol.agent`, then `"claude"` for the categorizer
  agent.
- `budget_usd.digest` and `timeout_sec.digest` for categorizer limits,
  defaulting inside `Hive::Digest::Categorizer` to `50` and `1800`.
- `bot.chat_id_allowlist[0]` for Telegram delivery.
- `bot.log_file` for the sender's bot logger path.

`load_global_digest_block` returns only the validated `digest` block for
`Hive::Commands::Daemon`, which wires `DigestScheduler`. Delivery resolves to
`bot.chat_id_allowlist[0]`. The digest is **opt-out**: when the operator has not
set `digest.enabled`, `load_global_digest_block` derives it from the bot config —
`true` when `bot.enabled == true` and `bot.chat_id_allowlist` has at least one
integer chat id, else `false` (the predicate is the private
`Config.telegram_digest_default?(data)` helper). An explicit `digest.enabled`
(true or false) is always honored; only the unset case is derived. Both
scheduler-config callers (`Commands::Daemon#start_daemon` and the dispatcher
SIGHUP reconfigure) load through `load_global_digest_block`, so the derived
value applies in both.

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

| Function | Returns / does |
|----------|----------------|
| `hive_home` | `ENV["HIVE_HOME"] || Hive::Paths.config_home` (XDG default `~/.config/hive`; legacy `~/Dev/hive/config.yml` is migrated) |
| `global_config_path` | `<hive_home>/config.yml` |
| `hive_state_dir(project_root, name = ".hive-state")` | `<project_root>/<name>` |
| `load(project_root)` | Reads `<project_root>/.hive-state/config.yml`, treating only an initial `ENOENT` as absent and rewrapping traversal, symlink-loop, read, and YAML parse failures as path-bearing `ConfigError`s; then recursively deep-merges onto DEFAULTS, validates, and returns a Hash with `"project_root"` injected. |
| `registered_projects` | Reads global config; returns `[{name, path, hive_state_path, repository_identity}, …]` (paths `expand_path`-ed). The identity is a normalized canonical `origin` captured at enrollment when available. |
| `find_project(name)` | First entry from `registered_projects` matching `name` (or `nil`). |
| `register_project(name:, path:, repository_identity: :detect)` | Adds or replaces an entry under `config.yml.lock`; stores private `real_path` for relink detection and the transport-independent canonical `origin` identity when detectable. Enrollment still succeeds without an origin, but an explicit cross-project dependency targeting that project later fails closed until identity is configured and re-enrolled. |
| `unregister_project(name)` | Index-based delete (not `Array#-`, which would clear duplicate-content rows); `to_s`-symmetric name match so an Integer `name:` in YAML still resolves; rewrites under `config.yml.lock`. |
| `prune_missing_projects!(dry_run:)` | Drops rows whose `path` is not a directory, whose stored valid `real_path` no longer matches the current target, OR whose shape is invalid (non-Hash, missing `path`); reads and, unless `dry_run`, rewrites under `config.yml.lock`. |
| `load_global_config(path)` | Reads + `YAML.safe_load`; rewraps `Psych::SyntaxError` AND `Errno::EACCES`/`EISDIR` as `ConfigError` (exit 78) so `chmod 000` on the file surfaces as bad-config, not internal-error. |
| `load_global_digest_block` | Reads global config, deep-merges the `digest` section over defaults, validates `enabled`, `agent`, and `max_catchup_days`, and returns the scheduler-facing digest block. |
| `load_global_digest_config` | Reads global config, deep-merges full defaults, injects bot runtime paths, validates the result, and returns the config hash used by `Hive::Digest.run`. |
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

Runs after merge so a default value can never trigger a failure — only user input does. Raises `Hive::ConfigError` (single class for all "config is bad" cases). Key checks include:

1. **`validate_hash_shaped_keys!`** — every hash-shaped top-level key (`brainstorm`, `claude`, `plan`, `execute`, `open_pr`, `artifacts`, `finalize`, `budget_usd`, `timeout_sec`, `review`, `agents`, `daemon`, `bot`, `web`, `babysitter`, `patrol`, `digest`, `rebase`) must be a Hash when present. Catches scalar/nil/integer overrides (e.g. YAML `brainstorm: claude`, `budget_usd: ~`, `timeout_sec: 600`) that would otherwise survive `deep_merge` and crash later as `TypeError`/`NoMethodError`.
2. **`validate_reviewers!` / `validate_review_adhoc!`** — `review.reviewers` must be an Array (nil fails with a hint to remove the key vs. set `[]`). Each entry must be a Hash. `name` and `output_basename` must be unique across the list (basename uniqueness prevents concurrent file-write collisions on `reviews/<basename>-NN.md`). Empty/whitespace `output_basename` is rejected (would yield `reviews/-01.md`). Each entry's `agent` is checked via `validate_agent_name!`. `review.adhoc.reviewers` is either nil or the same reviewer-entry Array shape, and `review.adhoc.fix` is boolean.
3. **`validate_review_fix_auto_commit!`** — `review.fix` and `review.fix.auto_commit` must stay Hash-shaped. `review.fix.auto_commit.sign_policy` is optional and must be one of `inherit`, `bypass`, or `fail`; `scope_check.enabled` must be boolean; `scope_check.allowed_paths` / `denied_paths` must be relative path-glob arrays without traversal, absolute paths, or null bytes.
4. **`validate_role_agent_names!`** — every stage/review role agent path is checked via `validate_agent_name!`.
5. **`validate_claude_mode!`** — `claude.mode` must be `tmux` or `headless`.
6. **`validate_claude_permission_mode!`** — `claude.permission_mode` must be one of `acceptEdits`, `auto`, `bypassPermissions`, `default`, `dontAsk`, or `plan`. Both the tmux launcher and the headless `-p` path resolve this value to the same Claude Code flags via `AgentProfile#permission_flags`: `bypassPermissions` → `--dangerously-skip-permissions`, any other mode → `--permission-mode <mode>`. Fresh init suggests `bypassPermissions` so dogfood runs do not pause on file-operation approval prompts, while `auto` keeps Claude Code auto-mode rules.
7. **`validate_permissions!`** — top-level, stage-level, review-role, and reviewer-entry `permissions:` specs are parsed by `Hive::PermissionScope` and must be `yolo`, `read-only`, or a valid `scoped` map. Shape errors, unknown presets/keys, malformed `Tool(specifier)` rules, unresolvable file-rule paths, unsupported file-tool path rules (use `Read(path)` / `Edit(path)`), and `bash:` plus `tools:` fail during config load; runner capability is checked later when the stage profile is known. Scoped rules run in Claude `dontAsk` mode. Task-relative `Read(path)` / `Edit(path)` rules are resolved to absolute permission patterns at spawn time, including Claude's POSIX drive form on Windows. Qualified `Edit` covers every built-in file-edit tool, so all file-edit denies are removed to prevent a bare deny from overriding the path grant. Claude merges these CLI rules with loaded managed/user/project/local permission settings, so the descriptor expresses the requested Hive scope rather than overriding trusted operator policy from those sources.
8. **`validate_babysitter!`** — `babysitter.enabled` and `babysitter.dry_run` must be booleans; `interval` must be integer seconds or a `\d+[smh]` string; `max_concurrent_prs`, `budget_minutes`, and `budget_usd` must be integers >= 1; `labels_ignore` must be an array of strings.
9. **`validate_patrol!`** — `patrol.mode` must be one of `ultrapatrol`, `high`, `medium`, `low`, or `off`; `patrol.enabled`, `patrol.draft_prs`, and `patrol.review_prs` must be booleans when present; `trigger` must be one of the patrol trigger enum values; confidence, 0–100 alpha, per-feature/run counts, interval, and command shape are validated before the scheduler or `hive patrol` command can run. `patrol.review.reviewers` uses the same reviewer-entry validation as `review.reviewers`, but it is a separate list used only by synthetic `Patrol: ...` review tasks.
10. **`validate_refactor_patrol!`** — validates discovery/auto-fix/issue booleans and nested shapes, agent names, confidence/run counts, the whole-run review deadline, include/exclude paths, all six commands including `docs` and `public_contract`, semantic scope and contract/dependency policy booleans, leverage weights, the proposal-wide leverage floor, and the issue threshold. File count and diff size are publication evidence, not config or mutation gates; runtime mutation remains protected by root/path confinement, `.hive-state` and protected-path checks, secret scanning, dependency and public-contract guards, and applicable validation commands. Invalid side-effect policy fails at config load, not in a background action.
11. **`validate_daemon!`** — daemon numeric bounds, booleans, and nested hashes are checked before the daemon starts. The nested `daemon.auto_retry` block must be a hash, and `daemon.auto_retry.enabled` must be boolean when present.
12. **`validate_dependency_gate_stage!`** — `dependency_gate_stage` must be exactly `8-finalize` or `9-done`. Runtime admission then checks reachability against the prerequisite task's selected workflow rather than assuming the coding descriptor.

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
`web.github.owner` is valid and means the first successful Hivebox GitHub
device-flow login claims the box by writing that owner under the global config
lock; a local Hive Web GitHub connection never claims it. Pre-setting the owner
keeps the older pinned-owner gate. GitHub sign-in
uses the OAuth device flow (see [[decisions]] ADR-036), so no client secret
exists anywhere; `web.github.client_id` defaults to the shared hivebox OAuth
app — public by design, since device flow is a public-client grant.
`web.local_loopback: true` is the local foreground default: when `hive web`
binds `localhost`, `::1`, or `127.0.0.0/8`, the CLI exports
`HIVEBOX_LOCAL_LOOPBACK=1` and Rails skips GitHub login only for requests whose
actual socket peer (`REMOTE_ADDR`, not proxy-expanded `remote_ip`) is also
loopback. This preserves local mode through Tailscale Serve and similar
localhost reverse proxies without trusting arbitrary forwarded headers. The
proxy must authenticate/restrict its clients because Rails trusts its loopback
socket connection; use `false` when that boundary cannot be guaranteed.
Setting it to `false` forces the normal GitHub owner gate even on a loopback
bind.

The current `hive init` JSON summary envelope (`schemas/hive-init.v2.json`) carries the chosen architecture-patrol discovery value as `refactor_patrol_enabled`, alongside the launch and permission-mode choices. The retained v1 schema is a compatibility artifact. See [[commands/init]].

`claude.model` / `claude.effort` pin hive-launched claude sessions:
`model: default` (the default) uses Claude Code's live alias for ITS
recommended model — no hardcoded name, no inheriting the operator's
interactive selection; `inherit` omits the flag; aliases/full names pass
through. `effort: default` omits `--effort` (Claude Code's own tier);
low/medium/high pass through. `Hive::Config.claude_cli_flags(cfg)` builds
the argv fragment used by both the tmux wrapper and headless `Hive::Agent`.

`validate_agent_name!` accepts `nil` (field is optional) and otherwise requires the value to resolve via `Hive::AgentProfiles.registered?`. Failure messages include the registered profile names so the agent reading the error learns the valid set.

`describe_source(path)` annotates error messages with `"(defaults; no file present)"` when the candidate config file does not exist, so the user is pointed at the right path even when the failure comes from an injected reviewers list rather than a real file.

## `agents.*` overrides are plumbed at spawn time

`agents.<name>.{bin, env_override, min_version}` in per-project config now actually take effect (LFG-5). `Hive::AgentProfiles.lookup(name, cfg: cfg)` overlays `cfg.dig("agents", name)` onto the registry profile via `AgentProfile#with_overrides`, returning a new frozen profile. Unknown override keys raise `Hive::ConfigError`. Every spawn site in `lib/hive/stages/review.rb`, `review/ci_fix.rb`, `review/triage.rb`, `review/browser_test.rb`, and `reviewers/agent.rb` threads `cfg` into the lookup. Legacy callers passing `cfg: nil` get the registry profile unchanged.

`timeout_sec.review_ci` (default 3600) is enforced as a hard per-process kill in `Review::CiFix#run_ci_once` — TERM the pgid on expiry, 3s grace, then KILL — not just as an outer-loop budget check.

## Stage runners reach into config like this

```ruby
cfg.dig("budget_usd", "brainstorm")
cfg.dig("timeout_sec", "execute_implementation")
cfg.dig("review", "ci", "agent")
cfg.dig("review", "reviewers")
cfg.dig("review", "adhoc", "reviewers")
cfg.dig("review", "adhoc", "fix")
cfg.dig("babysitter", "enabled")
cfg.dig("babysitter", "max_concurrent_prs")
cfg.dig("patrol", "review_prs")
cfg.dig("patrol", "review", "reviewers")
cfg.dig("digest", "agent")
cfg.dig("daemon", "auto_retry", "enabled")
cfg.dig("budget_usd", "digest")
cfg.dig("timeout_sec", "digest")
cfg.dig("bot", "chat_id_allowlist")
cfg["worktree_root"]
```

## `HIVE_HOME` override

Tests use `with_tmp_global_config` (`test/test_helper.rb:30`) to point `HIVE_HOME` at a tmp dir, ensuring no test ever writes the real global config.

## Tests

- `test/unit/config_test.rb` — defaults, recursive deep-merge, register/find round-trip, malformed YAML, reviewer/agent validation, ordinary patrol, architecture-patrol consent/policy validation, babysitter/digest defaults, global digest config merge, and bot digest-chat validation.
- `test/unit/web/config_test.rb` — global web defaults and invalid web port rejection.

## Backlinks

- [[commands/init]] · [[commands/new]] · [[commands/run]] · [[commands/status]] · [[commands/babysit]] · [[commands/patrol]] · [[commands/refactor-patrol]] · [[commands/web]] · [[commands/digest]]
- [[modules/agent]] · [[modules/digest]] · [[state-model]]
