---
title: Hive::Config
type: module
source: lib/hive/config.rb
created: 2026-04-25
updated: 2026-06-18
tags: [config, yaml, validation]
---

**TLDR**: Two YAML configs — global at `~/.config/hive/config.yml` (registered projects plus daemon, bot, digest, update, web, and screenote settings, including voice-transcription defaults; `HIVE_HOME/config.yml` when overridden, legacy `~/Dev/hive/config.yml` when migrated) and per-project at `<project>/.hive-state/config.yml` (default branch, worktree root, budgets, timeouts, **stage agents**, project-global `claude.mode`/`claude.permission_mode` plus `claude.model`/`claude.effort` pins, review-stage roles, daemon enrollment, experimental babysitter enrollment, patrol mode/enrollment and PR handoff). `Config.load(project_root)` resolves `patrol.mode` into scheduler knobs, **recursively** deep-merges per-project values onto `Config::DEFAULTS`, then runs `validate!`. Arrays (notably `review.reviewers`, `patrol.review.reviewers`, `bot.transcription.supported_languages`, and `babysitter.labels_ignore`) are replaced wholesale, never per-element merged. The daily shipped digest uses `digest.agent`, `digest.max_catchup_days`, `budget_usd.digest`, `timeout_sec.digest`, and `bot.chat_id_allowlist[0]`; `Hive::Digest.run` defaults through `Config.load_global_digest_config`. Artifacts-stage screenote uploads use `Config.load_global_screenote`, with env overrides for the base URL and token.

## Defaults (`Config::DEFAULTS`)

```ruby
{
  "hive_state_path"   => ".hive-state",
  "worktree_root"     => nil,
  "default_branch"    => nil,
  "project_name"      => nil,
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
  # Stage-level agent for single-agent stages (ADR-023). 6-review
  # keeps its own per-role agent fields under review.{ci,triage,fix,
  # browser_test}.agent. Runtime fallback is `cfg.dig("<stage>", "agent")
  # || "claude"` (see Hive::Stages::Base.stage_profile in
  # [[modules/stages]]) so legacy configs keep working.
  "brainstorm" => { "agent" => "claude", "runtime" => "headless" }, # runtime is legacy read-back-compat
  "plan"       => { "agent" => "claude" },
  "execute"    => { "agent" => "claude" },  # rendered template recommends `codex`
  "open_pr"    => { "agent" => "claude" },
  "artifacts"  => { "agent" => "claude" },
  "finalize"   => { "agent" => "claude" },
  "agents" => {
    "claude" => { "bin" => "claude", "env_override" => "HIVE_CLAUDE_BIN", "min_version" => "2.1.118" },
    "codex"  => { "bin" => "codex",  "env_override" => "HIVE_CODEX_BIN",  "min_version" => "0.125.0" },
    "pi"     => { "bin" => "pi",     "env_override" => "HIVE_PI_BIN",     "min_version" => "0.70.2" }
  },
  "review" => {
    "ci"           => { "command" => nil, "max_attempts" => 3, "agent" => "claude",
                        "prompt_template" => "ci_fix_prompt.md.erb" },
    "reviewers"    => [],
    "triage"       => { "enabled" => true, "agent" => "claude", "bias" => "courageous",
                        "prompt_template" => nil, "custom_prompt" => nil },
    "fix"          => { "agent" => "claude", "prompt_template" => "fix_prompt.md.erb" },
    "browser_test" => { "enabled" => false, "agent" => "claude",
                        "prompt_template" => "browser_test_prompt.md.erb", "max_attempts" => 2 },
    "max_passes"        => 2,
    "max_wall_clock_sec" => 14400
  },
  "web" => {
    "bind" => "127.0.0.1",
    "port" => 4567,
    "origin" => "http://127.0.0.1:4567",
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
    "max_findings_per_feature" => 10,
    "max_prs_per_cycle" => 3,
    "draft_prs" => false,
    "review_prs" => true,
    "include" => [],
    "exclude" => [ "node_modules", "dist", "build", "vendor", ".git" ],
    "commands" => { "format" => nil, "lint" => nil, "typecheck" => nil, "test" => nil },
    "review" => {
      "max_context_files" => 24,
      "max_owned_files" => 12,
      "reviewers" => [ { "name" => "codex-native-review", "kind" => "codex_review", "agent" => "codex", ... } ]
    }
  },
  "digest" => { "enabled" => false, "agent" => nil, "max_catchup_days" => 7 },
  "screenote" => { "base_url" => nil, "api_token" => nil },
  "bot" => {
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

`worktree_root: nil` is intentional — the actual default is computed lazily by `Worktree#worktree_root` as `~/Dev/<project>.worktrees`. `review.reviewers` defaults to `[]`; the recommended set ships live (uncommented) in `templates/project_config.yml.erb` so a fresh `hive init` produces a populated reviewer list. `patrol.review.reviewers` defaults to the single native Codex reviewer (`name: codex-native-review`, `kind: codex_review`), which runs Codex's built-in `review` subcommand and needs no CE skill; fresh init can optionally add Codex or Claude CE `ce-code-review` entries for patrol PRs. `daemon.max_concurrent_patrol_scans` (default `1`, validated `>= 1`) is a **per-project** cap bounding daemon-scheduled `hive patrol PROJECT` scans on a **separate** in-flight budget from task dispatch: a long codex-backed scan never consumes a `daemon.max_concurrent_runs` task slot — scans are tagged `kind: :patrol_scan` in the dispatcher and excluded from the per-project/global task caps, counted only against this independent cap. `ConcurrencyController#can_dispatch_patrol_scan?` counts only the **given project's** running scans (`entry[:kind] == :patrol_scan && entry[:project] == project`), so the default `1` means one scan per project at a time and **different projects patrol in parallel** rather than being serialized/starved by a global count (see `→ :patrol_scan_cap`).

**Patrol is opt-in.** `resolve_patrol_mode!` runs on the raw YAML before `merge_defaults` and only derives/injects mode knobs when `mode:` is **explicitly present** in the raw config (`return unless nested_key?(data, "patrol", "mode")`). A config with **no patrol section** — or a patrol section that omits `mode:` — injects nothing and falls through to `DEFAULTS["patrol"]["enabled"] = false`, so patrol stays **disabled**. `medium` is the default offered by the `hive init` *prompt* (which writes the chosen mode — `medium` unless overridden — into `templates/project_config.yml.erb`), **never** a config-resolution default — the `DEFAULT_PATROL_MODE` constant (`"medium"`) exists solely for that prompt. `medium`'s steady `timer`/4h cadence is the default because `low`'s `new_commits` trigger fires on **every** commit, which is costlier on a high-velocity repo than a 4h timer; with the cheap native codex-review reviewer the per-cycle review cost is low, so cadence dominates and `medium` wins. The explicit modes are `ultrapatrol` (`trigger: timer`, `poll_interval_sec: 1800`, `enabled: true`), `high` (`timer`, `7200`, `true`), `medium` (`timer`, `14400`, `true`), `low` (`new_commits`, `enabled: true`, leaving the baseline `poll_interval_sec: 600` SHA-check cadence), and `off` (`enabled: false`). The mode never changes `max_findings_per_feature`, `max_prs_per_cycle`, or `min_confidence_to_fix`. Explicit granular knobs (e.g. an explicit `enabled: true` with no `mode:`) always win over a set mode and survive the deep-merge, so legacy configs that carry `enabled`, `trigger`, and `poll_interval_sec` keep those values until the owner replaces them with the single mode key.

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
`HIVE_SCREENOTE_BASE_URL` and `HIVE_SCREENOTE_API_TOKEN`, validates the shape,
and returns a hash with `base_url` and `api_token`.

The block is used only after the artifacts agent has completed: `7-artifacts`
reads `media/manifest.json`, uploads PNG/JPEG stills marked
`push_to_screenote: true`, and writes the returned `annotate_url` back into
`screenote_url`. Blank or missing token/base URL disables upload. The token is
never interpolated into `artifacts_prompt.md.erb` or shown to the agent.

## Module functions

| Function | Returns / does |
|----------|----------------|
| `hive_home` | `ENV["HIVE_HOME"] || Hive::Paths.config_home` (XDG default `~/.config/hive`; legacy `~/Dev/hive/config.yml` is migrated) |
| `global_config_path` | `<hive_home>/config.yml` |
| `hive_state_dir(project_root, name = ".hive-state")` | `<project_root>/<name>` |
| `load(project_root)` | Reads `<project_root>/.hive-state/config.yml`, recursively deep-merges onto DEFAULTS, validates, returns Hash with `"project_root"` injected. Returns DEFAULTS-only hash if config absent. |
| `registered_projects` | Reads global config; returns `[{name, path, hive_state_path}, …]` (paths `expand_path`-ed). |
| `find_project(name)` | First entry from `registered_projects` matching `name` (or `nil`). |
| `register_project(name:, path:)` | Adds or replaces an entry in the global config under `config.yml.lock`; stores private absolute-string `real_path` when the path can be resolved so prune can detect relinked symlinks; ensures `hive_home` exists; writes via `update_global_config!`. |
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
| `claude_mode(cfg)` | Returns `:tmux` or `:headless` after validating `claude.mode`. |
| `claude_cli_flags(cfg)` | Returns the Claude-only argv fragment for model/effort pins: `["--model", model]` unless `model` is blank/`inherit`; `["--effort", effort]` only for explicit non-default effort values. Shared by headless `Hive::Agent` and tmux `Hive::ClaudeLauncher`. |
| `claude_permission_mode(cfg)` | Returns the configured Claude Code permission mode, defaulting to `bypassPermissions`. Valid values mirror Claude Code: `acceptEdits`, `auto`, `bypassPermissions`, `default`, `dontAsk`, `plan`. |
| `deep_merge(base, override)` | Recursive merge: Hash-vs-Hash recurses; everything else (scalar, Array, mismatched types) replaces. |
| `deep_dup(obj)` | Recursive Hash/Array deep-copy. |

## Recursive deep-merge

Closes doc-review F3 (P0). The previous implementation was a **single-level** `Hash#merge` that wiped sibling keys whenever a user override touched a 3+-deep nested path (e.g. `review: { ci: { command: "bin/ci" } }` would erase every other `review.ci.*` and `review.*` default).

Rules:

- **Hash + Hash** → recurse, key-by-key.
- **Array** (any depth) → replace wholesale. Per-element merge has ambiguous semantics for ordered lists (e.g. `review.reviewers` and `patrol.review.reviewers`), so all Array-typed settings replace wholesale. (Earlier wiki/code comments misattributed this to ADR-018, which is actually the per-CLI-isolation trust-model amendment — unrelated.)
- **Scalar / nil / type mismatch** → override wins.

## Validation (`Config.validate!`)

Runs after merge so a default value can never trigger a failure — only user input does. Raises `Hive::ConfigError` (single class for all "config is bad" cases). Key checks include:

1. **`validate_hash_shaped_keys!`** — every hash-shaped top-level key (`brainstorm`, `claude`, `plan`, `execute`, `open_pr`, `artifacts`, `finalize`, `budget_usd`, `timeout_sec`, `review`, `agents`, `daemon`, `bot`, `web`, `babysitter`, `patrol`, `digest`, `rebase`) must be a Hash when present. Catches scalar/nil/integer overrides (e.g. YAML `brainstorm: claude`, `budget_usd: ~`, `timeout_sec: 600`) that would otherwise survive `deep_merge` and crash later as `TypeError`/`NoMethodError`.
2. **`validate_reviewers!`** — `review.reviewers` must be an Array (nil fails with a hint to remove the key vs. set `[]`). Each entry must be a Hash. `name` and `output_basename` must be unique across the list (basename uniqueness prevents concurrent file-write collisions on `reviews/<basename>-NN.md`). Empty/whitespace `output_basename` is rejected (would yield `reviews/-01.md`). Each entry's `agent` is checked via `validate_agent_name!`.
3. **`validate_review_fix_auto_commit!`** — `review.fix` and `review.fix.auto_commit` must stay Hash-shaped. `review.fix.auto_commit.sign_policy` is optional and must be one of `inherit`, `bypass`, or `fail`; `scope_check.enabled` must be boolean; `scope_check.allowed_paths` / `denied_paths` must be relative path-glob arrays without traversal, absolute paths, or null bytes.
4. **`validate_role_agent_names!`** — every stage/review role agent path is checked via `validate_agent_name!`.
5. **`validate_claude_mode!`** — `claude.mode` must be `tmux` or `headless`.
6. **`validate_claude_permission_mode!`** — `claude.permission_mode` must be one of `acceptEdits`, `auto`, `bypassPermissions`, `default`, `dontAsk`, or `plan`. Both the tmux launcher and the headless `-p` path resolve this value to the same Claude Code flags via `AgentProfile#permission_flags`: `bypassPermissions` → `--dangerously-skip-permissions`, any other mode → `--permission-mode <mode>`. Fresh init suggests `bypassPermissions` so dogfood runs do not pause on file-operation approval prompts, while `auto` keeps Claude Code auto-mode rules.
7. **`validate_babysitter!`** — `babysitter.enabled` and `babysitter.dry_run` must be booleans; `interval` must be integer seconds or a `\d+[smh]` string; `max_concurrent_prs`, `budget_minutes`, and `budget_usd` must be integers >= 1; `labels_ignore` must be an array of strings.
8. **`validate_patrol!`** — `patrol.mode` must be one of `ultrapatrol`, `high`, `medium`, `low`, or `off`; `patrol.enabled`, `patrol.draft_prs`, and `patrol.review_prs` must be booleans when present; `trigger` must be one of the patrol trigger enum values; confidence/severity/count/interval/command shape are validated before the scheduler or `hive patrol` command can run. `patrol.review.reviewers` uses the same reviewer-entry validation as `review.reviewers`, but it is a separate list used only by synthetic `Patrol: ...` review tasks.

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
`web.github` must be a hash, optional `web.github.owner` and
`web.github.client_id` must be non-empty strings when set, and
`web.session_secret_file` must be a non-empty string when set. A blank/missing
`web.github.owner` is valid and means the first successful hivebox GitHub
device-flow login claims the box by writing that owner under the global config
lock; pre-setting the owner keeps the older pinned-owner gate. GitHub sign-in
uses the OAuth device flow (see [[decisions]] ADR-036), so no client secret
exists anywhere; `web.github.client_id` defaults to the shared hivebox OAuth
app — public by design, since device flow is a public-client grant.

The `hive init` JSON summary envelope (`schemas/hive-init.v1.json`) carries the chosen value as a required `claude_permission_mode` string (same enum as the validator), alongside the existing `claude_mode` field — so an agent reading init output sees both the launch mode and the permission mode. See [[commands/init]].

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
cfg.dig("babysitter", "enabled")
cfg.dig("babysitter", "max_concurrent_prs")
cfg.dig("patrol", "review_prs")
cfg.dig("patrol", "review", "reviewers")
cfg.dig("digest", "agent")
cfg.dig("budget_usd", "digest")
cfg.dig("timeout_sec", "digest")
cfg.dig("bot", "chat_id_allowlist")
cfg["worktree_root"]
```

## `HIVE_HOME` override

Tests use `with_tmp_global_config` (`test/test_helper.rb:30`) to point `HIVE_HOME` at a tmp dir, ensuring no test ever writes the real global config.

## Tests

- `test/unit/config_test.rb` — defaults, recursive deep-merge, register/find round-trip, error on malformed YAML, normal and patrol reviewer/agent-name validation, babysitter/patrol/digest default and validation coverage, global digest config merge, and bot digest-chat validation.
- `test/unit/web/config_test.rb` — global web defaults and invalid web port rejection.

## Backlinks

- [[commands/init]] · [[commands/new]] · [[commands/run]] · [[commands/status]] · [[commands/babysit]] · [[commands/patrol]] · [[commands/web]] · [[commands/digest]]
- [[modules/agent]] · [[modules/digest]] · [[state-model]]
