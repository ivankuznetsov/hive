---
title: Hive::Config
type: module
source: lib/hive/config.rb
created: 2026-04-25
updated: 2026-04-25
tags: [config, yaml]
---

**TLDR**: Two YAML configs — global at `~/Dev/hive/config.yml` (registered projects) and per-project at `<project>/.hive-state/config.yml` (default branch, worktree root, budgets, timeouts, max review passes). `Config.load(project_root)` deep-merges per-project values onto `Config::DEFAULTS`.

## Defaults (`Config::DEFAULTS`)

```ruby
{
  "hive_state_path"   => ".hive-state",
  "worktree_root"     => nil,
  "max_review_passes" => 4,
  "default_branch"    => nil,
  "project_name"      => nil,
  "budget_usd" => {
    "brainstorm" => 10, "plan" => 20,
    "execute_implementation" => 100, "execute_review" => 50, "pr" => 10
  },
  "timeout_sec" => {
    "brainstorm" => 300, "plan" => 600,
    "execute_implementation" => 2700, "execute_review" => 600, "pr" => 300
  }
}
```

`worktree_root: nil` is intentional — the actual default is computed lazily by `Worktree#worktree_root` as `~/Dev/<project>.worktrees`.

## Module functions

| Function | Returns / does |
|----------|----------------|
| `hive_home` | `ENV["HIVE_HOME"] || ~/Dev/hive` |
| `global_config_path` | `<hive_home>/config.yml` |
| `hive_state_dir(project_root, name = ".hive-state")` | `<project_root>/<name>` |
| `load(project_root)` | Reads `<project_root>/.hive-state/config.yml`, deep-merges onto DEFAULTS, returns Hash with `"project_root"` injected. Returns DEFAULTS-only hash if config absent. |
| `registered_projects` | Reads global config; returns `[{name, path, hive_state_path}, …]` (paths `expand_path`-ed). Empty array if file absent. |
| `find_project(name)` | First entry from `registered_projects` matching `name` (or `nil`). |
| `register_project(name:, path:)` | Adds or replaces an entry in the global config; ensures `hive_home` exists; writes YAML. |
| `merge_defaults(data)` | Deep-merge: top-level keys overwrite scalars; Hash-vs-Hash values merge one level deep (used for `budget_usd`/`timeout_sec` so partial overrides preserve untouched stages). |
| `deep_dup(obj)` | Recursive Hash/Array deep-copy. |

## Validation

`load` raises `ConfigError` if the YAML root is not a Hash. `registered_projects` raises `ConfigError` if the root or any entry isn't a Hash. Otherwise the data is permissive: unknown keys pass through, missing keys fall back to defaults.

## Stage runners reach into config like this

```ruby
cfg.dig("budget_usd", "brainstorm")
cfg.dig("timeout_sec", "execute_implementation")
cfg["worktree_root"]
cfg["max_review_passes"]
```

The two-level deep-merge means a project that overrides only `timeout_sec.execute_implementation: 5400` keeps the default budgets intact.

## `HIVE_HOME` override

Tests use `with_tmp_global_config` (`test/test_helper.rb:30`) to point `HIVE_HOME` at a tmp dir, ensuring no test ever writes the real global config.

## Tests

- `test/unit/config_test.rb` — defaults, deep-merge, register/find round-trip, error on malformed YAML.

## Backlinks

- [[commands/init]] · [[commands/new]] · [[commands/run]] · [[commands/status]]
- [[state-model]]
