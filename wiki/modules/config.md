---
title: Hive::Config
type: module
source: lib/hive/config.rb
created: 2026-04-25
updated: 2026-05-04
tags: [config, yaml, validation]
---

**TLDR**: Two YAML configs — global at `~/Dev/hive/config.yml` (registered projects) and per-project at `<project>/.hive-state/config.yml` (default branch, worktree root, budgets, timeouts, max review passes, **stage agents**, review-stage roles). `Config.load(project_root)` **recursively** deep-merges per-project values onto `Config::DEFAULTS`, then runs `validate!`. Arrays (notably `review.reviewers`) are replaced wholesale, never per-element merged.

## Defaults (`Config::DEFAULTS`)

```ruby
{
  "hive_state_path"   => ".hive-state",
  "worktree_root"     => nil,
  "max_review_passes" => 4,
  "default_branch"    => nil,
  "project_name"      => nil,
  # Bumped ~5x in plan 2026-05-04-001 (ADR-023). These are GENEROUS sanity
  # caps for runaway agents, not cost targets. The deprecated
  # `execute_review` key was DROPPED — 5-review owns reviewer budgets per
  # ADR-014. Old project configs that still set it survive deep-merge but
  # nothing reads it and fresh `hive init` no longer renders it.
  "budget_usd" => {
    "brainstorm" => 50, "plan" => 100,
    "execute_implementation" => 500, "pr" => 50,
    "review_ci" => 100, "review_triage" => 75,
    "review_fix" => 500, "review_browser" => 100
  },
  "timeout_sec" => {
    "brainstorm" => 1800, "plan" => 3600,
    "execute_implementation" => 14400, "pr" => 1800,
    "review_ci" => 3600, "review_triage" => 1800,
    "review_fix" => 14400, "review_browser" => 3600
  },
  # Stage-level agent for the three single-agent stages (ADR-023). 5-review
  # keeps its own per-role agent fields under review.{ci,triage,fix,
  # browser_test}.agent. Runtime fallback is `cfg.dig("<stage>", "agent")
  # || "claude"` (see Hive::Stages::Base.stage_profile in
  # [[modules/stages]]) so legacy configs keep working.
  "brainstorm" => { "agent" => "claude" },
  "plan"       => { "agent" => "claude" },
  "execute"    => { "agent" => "claude" },  # rendered template recommends `codex`
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
    "max_passes"        => 4,
    "max_wall_clock_sec" => 5400
  }
}
```

`worktree_root: nil` is intentional — the actual default is computed lazily by `Worktree#worktree_root` as `~/Dev/<project>.worktrees`. `review.reviewers` defaults to `[]`; the recommended set ships live (uncommented) in `templates/project_config.yml.erb` so a fresh `hive init` produces a populated reviewer list.

## Module functions

| Function | Returns / does |
|----------|----------------|
| `hive_home` | `ENV["HIVE_HOME"] || ~/Dev/hive` |
| `global_config_path` | `<hive_home>/config.yml` |
| `hive_state_dir(project_root, name = ".hive-state")` | `<project_root>/<name>` |
| `load(project_root)` | Reads `<project_root>/.hive-state/config.yml`, recursively deep-merges onto DEFAULTS, validates, returns Hash with `"project_root"` injected. Returns DEFAULTS-only hash if config absent. |
| `registered_projects` | Reads global config; returns `[{name, path, hive_state_path}, …]` (paths `expand_path`-ed). |
| `find_project(name)` | First entry from `registered_projects` matching `name` (or `nil`). |
| `register_project(name:, path:)` | Adds or replaces an entry in the global config; ensures `hive_home` exists; writes YAML. |
| `merge_defaults(data)` | Calls `deep_merge(deep_dup(DEFAULTS), data)` — **recursive** Hash-into-Hash merge. |
| `deep_merge(base, override)` | Recursive merge: Hash-vs-Hash recurses; everything else (scalar, Array, mismatched types) replaces. |
| `deep_dup(obj)` | Recursive Hash/Array deep-copy. |

## Recursive deep-merge

Closes doc-review F3 (P0). The previous implementation was a **single-level** `Hash#merge` that wiped sibling keys whenever a user override touched a 3+-deep nested path (e.g. `review: { ci: { command: "bin/ci" } }` would erase every other `review.ci.*` and `review.*` default).

Rules:

- **Hash + Hash** → recurse, key-by-key.
- **Array** (any depth) → replace wholesale. Explicit semantic for `review.reviewers` per ADR-018 (see [[state-model]]); generalises to all Array-typed settings — per-element merge has ambiguous semantics for ordered lists.
- **Scalar / nil / type mismatch** → override wins.

## Validation (`Config.validate!`)

Runs after merge so a default value can never trigger a failure — only user input does. Raises `Hive::ConfigError` (single class for all "config is bad" cases). Three checks (in order):

1. **`validate_hash_shaped_keys!`** — every key in `HASH_SHAPED_KEYS = %w[brainstorm plan execute budget_usd timeout_sec review agents]` must be a Hash when present. Catches scalar/nil/integer overrides (e.g. YAML `brainstorm: claude`, `budget_usd: ~`, `timeout_sec: 600`) that would otherwise survive `deep_merge` — `deep_merge(default_hash, scalar)` returns the scalar unchanged — and crash later as `TypeError`/`NoMethodError` when stage code calls `cfg.dig("brainstorm", "agent")`. Error message hints either dropping the key (defaults apply) or supplying the right `{ ... }` shape. Closes ce-code-review F1 (P1).
2. **`validate_reviewers!`** — `review.reviewers` must be an Array (nil fails with a hint to remove the key vs. set `[]`). Each entry must be a Hash. `name` and `output_basename` must be unique across the list (basename uniqueness prevents concurrent file-write collisions on `reviews/<basename>-NN.md`). Empty/whitespace `output_basename` is rejected (would yield `reviews/-01.md`). Each entry's `agent` is checked via `validate_agent_name!`.
3. **`validate_role_agent_names!`** — every path in `ROLE_AGENT_PATHS` (`review.ci.agent`, `review.triage.agent`, `review.fix.agent`, `review.browser_test.agent`, `brainstorm.agent`, `plan.agent`, `execute.agent`) is checked via `validate_agent_name!`.

`validate_agent_name!` accepts `nil` (field is optional) and otherwise requires the value to resolve via `Hive::AgentProfiles.registered?`. Failure messages include the registered profile names so the agent reading the error learns the valid set.

`describe_source(path)` annotates error messages with `"(defaults; no file present)"` when the candidate config file does not exist, so the user is pointed at the right path even when the failure comes from an injected reviewers list rather than a real file.

## `agents.*` overrides are plumbed at spawn time

`agents.<name>.{bin, env_override, min_version}` in per-project config now actually take effect (LFG-5). `Hive::AgentProfiles.lookup(name, cfg: cfg)` overlays `cfg.dig("agents", name)` onto the registry profile via `AgentProfile#with_overrides`, returning a new frozen profile. Unknown override keys raise `Hive::ConfigError`. Every spawn site in `lib/hive/stages/review.rb`, `review/ci_fix.rb`, `review/triage.rb`, `review/browser_test.rb`, and `reviewers/agent.rb` threads `cfg` into the lookup. Legacy callers passing `cfg: nil` get the registry profile unchanged.

`timeout_sec.review_ci` (default 600) is enforced as a hard per-process kill in `Review::CiFix#run_ci_once` — TERM the pgid on expiry, 3s grace, then KILL — not just as an outer-loop budget check.

## Stage runners reach into config like this

```ruby
cfg.dig("budget_usd", "brainstorm")
cfg.dig("timeout_sec", "execute_implementation")
cfg.dig("review", "ci", "agent")
cfg.dig("review", "reviewers")
cfg["worktree_root"]
cfg["max_review_passes"]
```

## `HIVE_HOME` override

Tests use `with_tmp_global_config` (`test/test_helper.rb:30`) to point `HIVE_HOME` at a tmp dir, ensuring no test ever writes the real global config.

## Tests

- `test/unit/config_test.rb` — defaults, recursive deep-merge, register/find round-trip, error on malformed YAML, reviewer/agent-name validation.

## Backlinks

- [[commands/init]] · [[commands/new]] · [[commands/run]] · [[commands/status]]
- [[modules/agent]] · [[state-model]]
