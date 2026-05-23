require "yaml"
require "fileutils"
require "hive/agent_profiles"
require "hive/paths"

module Hive
  module Config
    DEFAULTS = {
      "hive_state_path" => ".hive-state",
      "worktree_root" => nil,
      "default_branch" => nil,
      "project_name" => nil,
      # Budget and timeout caps are GENEROUS sanity caps for runaway agents,
      # not cost targets. Most tasks finish well within them; a stuck loop
      # still gets cut off. Bumped ~5x from the original conservative values
      # in plan 2026-05-04-001 (per ADR-023). The deprecated `execute_review`
      # key was dropped here — 6-review owns reviewer budgets per ADR-014, so
      # nothing reads it. Existing project configs that still set it survive
      # via deep-merge but the key is no longer rendered for fresh projects.
      "budget_usd" => {
        "brainstorm" => 50,
        "plan" => 100,
        "execute_implementation" => 500,
        "open_pr" => 50,
        "artifacts" => 100,
        "finalize" => 50,
        "review_ci" => 100,
        "review_triage" => 75,
        "review_fix" => 500,
        "review_browser" => 100
      },
      "timeout_sec" => {
        "brainstorm" => 1800,
        "plan" => 3600,
        "execute_implementation" => 14400,
        "open_pr" => 1800,
        "artifacts" => 3600,
        "finalize" => 1800,
        "review_ci" => 3600,
        "review_triage" => 1800,
        "review_fix" => 14400,
        "review_browser" => 3600
      },
      # Stage-level agent for single-agent stages. The review
      # stage has its own per-role agent fields under "review.{ci,triage,
      # fix,browser_test}.agent". Runtime fallback in stage code stays
      # `cfg.dig("<stage>", "agent") || "claude"` so legacy configs without
      # these keys keep behaving as today (ADR-023). The recommended-default
      # for execute is `codex` only at the rendered-template level, not in
      # DEFAULTS itself, to avoid silently flipping the implementer for old
      # projects on next load.
      # The `skill` field per stage names the slash-command the agent
      # is told to invoke inside its prompt. Per-project overrides via
      # `<stage>.skill` in config.yml pick a different skill without
      # touching templates/. When the field is absent, stage runners use
      # `stage_skill` below so agent-specific defaults can follow each
      # CLI's installed skill names.
      "brainstorm" => {
        "agent" => "claude",
        "skill" => "/compound-engineering:ce-brainstorm",
        "runtime" => "headless"
      },
      "plan" => {
        "agent" => "claude",
        "skill_by_agent" => {
          "claude" => "/plan",
          "codex" => "/llm-wiki:wiki-plan",
          "pi" => "/llm-wiki:wiki-plan",
          "default" => "/llm-wiki:wiki-plan"
        }
      },
      "execute" => { "agent" => "claude" },
      "open_pr" => { "agent" => "claude" },
      "artifacts" => { "agent" => "claude" },
      "finalize" => { "agent" => "claude" },
      # Per-CLI agent profiles. Each project may override `bin`,
      # `env_override`, or `min_version` to pin to a different binary or
      # version. Adding a new top-level profile is not yet supported here
      # — register custom profiles in Ruby via Hive::AgentProfiles.register.
      "agents" => {
        "claude" => {
          "bin" => "claude",
          "env_override" => "HIVE_CLAUDE_BIN",
          "min_version" => "2.1.118"
        },
        "codex" => {
          "bin" => "codex",
          "env_override" => "HIVE_CODEX_BIN",
          "min_version" => "0.125.0"
        },
        "pi" => {
          "bin" => "pi",
          "env_override" => "HIVE_PI_BIN",
          "min_version" => "0.70.2"
        }
      },
      # Configuration for the 6-review stage's autonomous loop. Each role
      # (ci, reviewers, triage, fix, browser_test) takes an `agent` profile
      # name (must resolve via Hive::AgentProfiles.lookup) and an optional
      # `prompt_template` path under templates/.
      #
      # `reviewers` is an Array; the deep-merge rule REPLACES it wholesale
      # when a project sets it (the alternative — per-element merge — has
      # ambiguous semantics for ordered lists). Hive's recommended set ships
      # in templates/project_config.yml.erb (live, not commented), so a
      # fresh `hive init` produces a populated config.
      "review" => {
        "ci" => {
          "command" => nil,
          "max_attempts" => 3,
          "agent" => "claude",
          "prompt_template" => "ci_fix_prompt.md.erb"
        },
        "reviewers" => [],
        "triage" => {
          "enabled" => true,
          "agent" => "claude",
          "bias" => "courageous",
          "prompt_template" => nil,
          "custom_prompt" => nil
        },
        "fix" => {
          "agent" => "claude",
          "prompt_template" => "fix_prompt.md.erb"
        },
        "browser_test" => {
          "enabled" => false,
          "agent" => "claude",
          "prompt_template" => "browser_test_prompt.md.erb",
          "max_attempts" => 2
        },
        "github_publish" => {
          "enabled" => true,
          "max_attempts" => 2
        },
        "max_passes" => 2,
        "max_wall_clock_sec" => 5400
      },
      # Hive daemon settings (ADR-024). The daemon polls
      # `hive status --json`, dispatches workflow verbs on tasks the
      # classifier marks safe, and stops only at human-input gates.
      #
      # Per-project `daemon.enabled` is rendered into a project's
      # `.hive-state/config.yml` by `hive init` (TTY prompt, default Y).
      # The `Config::DEFAULTS["daemon"]["enabled"]` value is the LEGACY
      # FALLBACK for projects whose YAML doesn't carry the `daemon:`
      # key at all — same "do not silently flip legacy projects"
      # pattern ADR-023 used for stage agents. Default `false` here
      # means existing projects need an explicit one-line config edit
      # before the daemon will touch them.
      "daemon" => {
        "enabled" => false,
        "autostart" => false,
        "poll_interval_sec" => 30,
        "edit_debounce_sec" => 30,
        "pr_merge_poll_interval_sec" => 300,
        "max_concurrent_runs" => 5,
        "max_concurrent_per_project" => 5,
        "max_runs_per_day_per_project" => 50,
        "transient_retry_backoff_sec" => 60,
        "shutdown_grace_sec" => 600,
        "log_max_bytes" => 10_485_760,
        "log_max_files" => 5
      },
      # Global Telegram bot settings. The bot is an operator surface
      # across every registered project, so runtime code loads these
      # from the global config via load_global_bot. The token lives
      # only in HIVE_TELEGRAM_BOT_TOKEN and is never persisted.
      "bot" => {
        "enabled" => false,
        "chat_id_allowlist" => [],
        "poll_interval_sec" => 30,
        "long_poll_timeout_sec" => 25,
        "notification_dedupe_window_sec" => 300,
        "conversation_ttl_sec" => 3600,
        "codex_budget_usd" => 1,
        "codex_timeout_sec" => 120,
        "shutdown_grace_sec" => 60,
        "pid_file" => "~/Dev/hive/.bot.pid",
        "log_file" => "~/Dev/hive/logs/bot.log",
        "log_max_bytes" => 10_485_760,
        "log_max_files" => 5,
        "last_seen_state_file" => "~/Dev/hive/.bot.last_seen_update_id"
      },
      # Auto-rebase pre-step for `hive run` (plan
      # docs/plans/2026-05-14-001-feat-hive-auto-rebase-stale-worktree-plan.md).
      # Detects drift behind origin/<default_branch>, fetches, attempts
      # rebase, dispatches the project's execute-stage agent to resolve
      # conflicts. Fail-soft: any failure aborts the rebase and the
      # stage runner proceeds against the (stale) base. The hardcoded
      # max-conflict-resolutions cap (5) lives on
      # `Hive::Rebase::MAX_CONFLICT_RESOLUTIONS`, not config — projects
      # with persistently high-conflict branches should investigate the
      # underlying drift, not raise the cap.
      "rebase" => {
        "enabled" => true,
        "conflict_resolution_timeout_sec" => 2700
      }
    }.freeze

    # Roles that take an `agent` profile-name field. Used by validation to
    # check each role's value resolves to a registered AgentProfile.
    ROLE_AGENT_PATHS = [
      %w[brainstorm agent],
      %w[plan agent],
      %w[execute agent],
      %w[open_pr agent],
      %w[artifacts agent],
      %w[finalize agent],
      %w[review ci agent],
      %w[review triage agent],
      %w[review fix agent],
      %w[review browser_test agent]
    ].freeze

    # `/plan` was Hive's original wiki-first planning alias. It remains the
    # Claude default because Claude supports user-level slash commands. Codex
    # and Pi receive llm-wiki's canonical skill name unless a project chooses
    # a non-legacy override.
    LEGACY_WIKI_PLAN_ALIAS = "/plan"

    module_function

    def hive_home
      Hive::Paths.config_home
    end

    def global_config_path
      File.join(hive_home, "config.yml")
    end

    def hive_state_dir(project_root, hive_state_name = ".hive-state")
      File.join(project_root, hive_state_name)
    end

    def load(project_root)
      project_root = File.expand_path(project_root)
      candidate = File.join(project_root, ".hive-state", "config.yml")
      data = if File.exist?(candidate)
               parsed = YAML.safe_load(File.read(candidate)) || {}
               raise ConfigError, "config.yml at #{candidate} must be a hash" unless parsed.is_a?(Hash)

               parsed
      else
               {}
      end
      merged = merge_defaults(data).merge("project_root" => project_root)
      validate!(merged, candidate)
      merged
    end

    def stage_skill(cfg, stage)
      stage_cfg = cfg.fetch(stage, {})
      agent_name = (stage_cfg["agent"] || DEFAULTS.dig(stage, "agent") || "claude").to_s
      configured_skill = stage_cfg["skill"]

      return configured_skill if configured_skill && !legacy_wiki_plan_alias_for_non_claude?(stage, agent_name, configured_skill)

      skills_by_agent = {}
      default_skills_by_agent = DEFAULTS.dig(stage, "skill_by_agent")
      skills_by_agent.merge!(default_skills_by_agent) if default_skills_by_agent.is_a?(Hash)
      configured_skills_by_agent = stage_cfg["skill_by_agent"]
      skills_by_agent.merge!(configured_skills_by_agent) if configured_skills_by_agent.is_a?(Hash)

      if !skills_by_agent.empty?
        skills_by_agent[agent_name] || skills_by_agent["default"] || configured_skill
      else
        configured_skill || DEFAULTS.dig(stage, "skill")
      end
    end

    def legacy_wiki_plan_alias_for_non_claude?(stage, agent_name, skill)
      stage == "plan" &&
        agent_name != "claude" &&
        skill.to_s == LEGACY_WIKI_PLAN_ALIAS
    end

    # Surface a misconfigured HIVE_HOME loudly on READ paths only.
    # When ENV["HIVE_HOME"] is explicitly set to a path that doesn't exist
    # (e.g., a user typo), `registered_projects` returning [] silently hid
    # the typo and made `hive status --json | jq .ok` falsely report `true`
    # under nonexistent-HIVE_HOME smoke runs. Fire only when explicitly set
    # AND missing — leave the default unset path lazy-creatable by
    # `register_project` (which does its own mkdir_p), and accept the
    # legitimate "directory exists but config.yml not yet written" first-run
    # state.
    def validate_hive_home!
      env = ENV["HIVE_HOME"]
      return if env.nil? || env.empty?
      return if File.directory?(env)

      raise ConfigError, "HIVE_HOME is set to a path that does not exist: #{env}"
    end

    def registered_projects
      Hive::Paths.ensure_migrated!
      validate_hive_home!
      path = global_config_path
      return [] unless File.exist?(path)

      data = load_global_config(path)
      raise ConfigError, "global config at #{path} must be a hash" unless data.is_a?(Hash)

      # Tolerate hand-edit accidents: a non-Hash row, a row missing
      # `name`, or a row whose `path` isn't a String would previously
      # raise here and brick every command (status / forget / prune /
      # the TUI) until the operator hand-fixed config.yml. Treat such
      # rows as invisible at the loader level so the rest of the
      # surface stays usable; `hive prune` operates on the raw entries
      # below the loader and is the cleanup verb for this case.
      Array(data["registered_projects"]).each_with_object([]) do |entry, out|
        next unless valid_registry_entry?(entry)

        abs_path = File.expand_path(entry["path"])
        out << {
          "name" => entry["name"],
          "path" => abs_path,
          "hive_state_path" => entry["hive_state_path"] || File.join(abs_path, ".hive-state")
        }
      end
    end

    # Shape gate shared by the loader and `prune`'s predicate so the
    # two surfaces agree on what counts as a valid registry row.
    # Without this, the loader would silently skip a corrupted entry
    # while prune would also fail to drop it (its old predicate only
    # matched `!File.directory?` on rows that already had a String
    # path), and the entry would persist forever.
    def valid_registry_entry?(entry)
      entry.is_a?(Hash) && entry["name"].is_a?(String) && entry["path"].is_a?(String)
    end

    # YAML.safe_load can raise more than `Psych::SyntaxError`:
    # `Psych::DisallowedClass` (e.g. `!ruby/object:Object` in a hand-edited
    # config) and `Psych::AliasesNotEnabled` (anchor + alias) are also
    # "operator wrote bad YAML" cases that used to leak as InternalError
    # (exit 70) despite the documented exit 78 contract. Rescue
    # `Psych::Exception` so every malformed-YAML shape funnels through the
    # same `error_kind: "config"` envelope the TUI's narrow rescue catches.
    #
    # EACCES specifically is the most user-facing of the IO group:
    # `chmod 000 ~/Dev/hive/config.yml` (or running as a different
    # user) used to surface as `internal error: Errno::EACCES: ...`
    # at exit 70. The root cause is configuration access, not a Hive
    # bug — exit 78 is the right shape.
    def load_global_config(path)
      YAML.safe_load(File.read(path)) || {}
    rescue Psych::Exception => e
      raise ConfigError, "global config at #{path} is not valid YAML: #{e.message}"
    rescue Errno::EACCES, Errno::EISDIR => e
      raise ConfigError, "global config at #{path} is not readable: #{e.message}"
    end

    # Atomic + EACCES-aware writer for ~/Dev/hive/config.yml. Mirrors
    # the shape of `Hive::Markers.write_atomic` so a future flock
    # upgrade (Issue #31) can swap in here without rewriting every
    # call site. Permission errors on write surface as ConfigError
    # (exit 78), matching the read-side classification.
    def write_global_config!(data)
      File.write(global_config_path, data.to_yaml)
    rescue Errno::EACCES, Errno::EROFS, Errno::ENOSPC => e
      raise ConfigError, "global config at #{global_config_path} could not be written: #{e.message}"
    end

    def find_project(name)
      registered_projects.find { |p| p["name"] == name }
    end

    # Load and validate the global `daemon` block from
    # `~/Dev/hive/config.yml`. Returns the merged Hash (operator
    # overrides on top of `Config::DEFAULTS["daemon"]`). Used by
    # `hive daemon start` / `reload` so operator knobs in the global
    # config (max_concurrent_runs, poll_interval_sec, log_*, etc.)
    # actually take effect at runtime.
    #
    # Returns the bare DEFAULTS["daemon"] when no global config is
    # present (first-run scenario, no projects registered yet).
    def load_global_daemon
      Hive::Paths.ensure_migrated!
      validate_hive_home!
      path = global_config_path
      data = File.exist?(path) ? load_global_config(path) : {}
      raise ConfigError, "global config at #{path} must be a hash" unless data.is_a?(Hash)

      override = data["daemon"] || {}
      unless override.is_a?(Hash)
        raise ConfigError,
              "daemon in #{describe_source(path)} must be a Hash; got #{override.class}"
      end

      merged = deep_merge(deep_dup(DEFAULTS["daemon"]), override)
      # Re-use the existing validator by wrapping the daemon block in a
      # cfg-shaped hash. validate_daemon! is idempotent and operates on
      # cfg["daemon"].
      validate_daemon!({ "daemon" => merged }, path)
      merged
    end

    # Load and validate the global `bot` block from the XDG config path.
    # `require_runtime: true` is used by `hive bot start` so the opt-in
    # credentials fail loudly there without making read-only commands like
    # `hive status` require a Telegram token.
    def load_global_bot(require_runtime: false)
      Hive::Paths.ensure_migrated!
      validate_hive_home!
      path = global_config_path
      data = File.exist?(path) ? load_global_config(path) : {}
      raise ConfigError, "global config at #{path} must be a hash" unless data.is_a?(Hash)

      override = data["bot"] || {}
      unless override.is_a?(Hash)
        raise ConfigError,
              "bot in #{describe_source(path)} must be a Hash; got #{override.class}"
      end

      merged = deep_merge(global_bot_defaults, override)
      validate_bot_config!({ "bot" => merged }, path)
      validate_bot_runtime!(merged, path) if require_runtime
      merged
    end

    def telegram_bot_token!
      token = ENV["HIVE_TELEGRAM_BOT_TOKEN"].to_s
      return token unless token.strip.empty?

      raise ConfigError, "HIVE_TELEGRAM_BOT_TOKEN must be set to start hive bot"
    end

    def global_bot_defaults
      defaults = deep_dup(DEFAULTS["bot"])
      defaults["pid_file"] = File.join(Hive::Paths.state_home, ".bot.pid")
      defaults["log_file"] = File.join(Hive::Paths.state_home, "logs", "bot.log")
      defaults["last_seen_state_file"] = File.join(Hive::Paths.state_home, ".bot.last_seen_update_id")
      defaults
    end

    def register_project(name:, path:)
      Hive::Paths.ensure_migrated!
      FileUtils.mkdir_p(hive_home)
      data = if File.exist?(global_config_path)
               load_global_config(global_config_path)
      else
               {}
      end
      data["registered_projects"] ||= []
      abs_path = File.expand_path(path)
      hive_state_path = File.join(abs_path, ".hive-state")
      entry = { "name" => name, "path" => abs_path, "hive_state_path" => hive_state_path }
      existing = data["registered_projects"].find { |p| p["name"] == name }
      if existing
        existing.replace(entry)
      else
        data["registered_projects"] << entry
      end
      write_global_config!(data)
      entry
    end

    # Inverse of register_project: remove the entry whose name matches.
    # Returns the removed Hash entry, or nil if no entry matched. Does
    # not touch the project's `.hive-state` directory on disk — the
    # registry and the on-disk state are independent, and a deregister
    # may target a project whose path is gone (the common case) or one
    # the user simply no longer wants tracked.
    #
    # Validates $HIVE_HOME first so a typoed env var surfaces as
    # ConfigError (exit 78) rather than masquerading as `unknown_project`
    # / exit 64 — without this, an operator with a bad HIVE_HOME saw
    # "no entry named foo" and would chase a non-existent registry typo
    # instead of fixing the env var.
    #
    # Index-based delete (not Array#- subtraction): two registry rows
    # with the same name and content are equal under `Hash#==`, so
    # `entries - [removed]` would clear BOTH. delete_at on the matched
    # index removes exactly the row the operator named.
    def unregister_project(name:)
      Hive::Paths.ensure_migrated!
      validate_hive_home!
      return nil unless File.exist?(global_config_path)

      data = load_global_config(global_config_path)
      raise ConfigError, "global config at #{global_config_path} must be a hash" unless data.is_a?(Hash)

      # Stringify both sides of the name match. CLI passes argv as a
      # String; TUI X-key dispatches against the snapshot's project.name
      # (also a String). Hand-edited registry entries can carry an
      # Integer "name" (e.g. `name: 42` in YAML), which would never
      # match `Integer == "42"` and silently exit `unknown_project`.
      # `to_s.==.to_s` makes the lookup symmetric across both surfaces.
      key = name.to_s
      entries = Array(data["registered_projects"])
      idx = entries.index { |p| p.is_a?(Hash) && p["name"].to_s == key }
      return nil if idx.nil?

      removed = entries[idx]
      remaining = entries.dup
      remaining.delete_at(idx)
      data["registered_projects"] = remaining
      write_global_config!(data)
      removed
    end

    # Drop every registry entry whose `path` no longer points at a
    # directory on disk OR whose row shape is invalid (non-Hash / missing
    # / non-String name or path). Used by `hive prune` and the TUI's
    # stale-project drop key. The filesystem check is `File.directory?`
    # (not `exist?`) so a stray leftover file at the registered path
    # doesn't masquerade as live. Pass `dry_run: true` to compute the
    # would-be-removed list without rewriting global_config_path.
    #
    # Returns a Hash:
    #   {
    #     removed: Array<Hash>,    # entries dropped (or that would be)
    #     kept_count: Integer      # entries remaining after the drop
    #   }
    #
    # Computing kept_count from the in-memory `entries` array (rather
    # than re-reading via `registered_projects.size`) closes the
    # consistency window where a concurrent register/forget between the
    # two reads produced inconsistent counts.
    def prune_missing_projects!(dry_run: false)
      Hive::Paths.ensure_migrated!
      validate_hive_home!
      return { removed: [], kept_count: 0 } unless File.exist?(global_config_path)

      data = load_global_config(global_config_path)
      raise ConfigError, "global config at #{global_config_path} must be a hash" unless data.is_a?(Hash)

      entries = Array(data["registered_projects"])
      removed, kept = entries.partition { |entry| droppable_registry_entry?(entry) }
      result = { removed: removed, kept_count: kept.size }
      return result if removed.empty?

      unless dry_run
        data["registered_projects"] = kept
        write_global_config!(data)
      end
      result
    end

    # Predicate for prune: drops invalid rows AND rows whose path is
    # gone. The shape branch and the directory-existence branch are
    # both true for "this row should not be in the registry", so
    # corrupted rows surface in the prune output (and `removed_count`)
    # exactly like missing-path rows.
    #
    # `File.expand_path` mirrors `registered_projects` (which expands
    # before exposing the row to the rest of the surface). Without it,
    # a hand-edited row like `path: ~/project` would be dropped as stale
    # because `File.directory?` does not expand `~`.
    def droppable_registry_entry?(entry)
      return true unless valid_registry_entry?(entry)

      !File.directory?(File.expand_path(entry["path"]))
    end

    # Recursive deep-merge: descends into nested Hashes so a partial
    # override like `review: { ci: { command: "bin/ci" } }` keeps every
    # other default at `review.ci.*` and at every other `review.*` key
    # intact. Arrays replace wholesale (no per-element merge) — this is
    # the explicit semantic for ordered lists like `review.reviewers`,
    # where per-element merge would have ambiguous semantics, and it
    # generalises to any Array-typed setting. Scalars override directly.
    #
    # Closes doc-review F3 (P0): the previous implementation was a
    # single-level Hash#merge that would wipe sibling keys whenever a
    # user override touched a 3+-deep nested path.
    def merge_defaults(data)
      deep_merge(deep_dup(DEFAULTS), data)
    end

    def deep_merge(base, override)
      return override unless base.is_a?(Hash) && override.is_a?(Hash)

      out = {}
      base.each { |k, v| out[k] = v }
      override.each do |k, v|
        out[k] = base.key?(k) ? deep_merge(base[k], v) : v
      end
      out
    end

    def deep_dup(obj)
      case obj
      when Hash then obj.each_with_object({}) { |(k, v), h| h[k] = deep_dup(v) }
      when Array then obj.map { |v| deep_dup(v) }
      else obj
      end
    end

    # Validate the merged config. Raises Hive::ConfigError on any issue
    # so callers see a single error class for "config is bad" regardless
    # of which field is at fault. Validation runs after merge so a
    # default value cannot be the cause of a failure — only user input
    # ever fails validation.
    def validate!(cfg, source_path)
      validate_hash_shaped_keys!(cfg, source_path)
      validate_stage_skill_by_agent!(cfg, source_path)
      validate_reviewers!(cfg, source_path)
      validate_role_agent_names!(cfg, source_path)
      validate_brainstorm_runtime!(cfg, source_path)
      validate_review_attempts!(cfg, source_path)
      validate_daemon!(cfg, source_path)
      validate_bot_config!(cfg, source_path)
      validate_rebase!(cfg, source_path)
    end

    # Top-level keys that MUST be Hashes when present. A scalar override
    # (e.g. YAML `brainstorm: claude` instead of `brainstorm: { agent: claude }`)
    # would otherwise survive deep_merge — `deep_merge(default_hash, "claude")`
    # returns the override unchanged, since override is not a Hash — and
    # crash later as TypeError/NoMethodError when stage code calls
    # `cfg.dig("brainstorm", "agent")`. Surface the shape mismatch loudly at
    # load time with a typed ConfigError instead.
    HASH_SHAPED_KEYS = %w[
      brainstorm
      plan
      execute
      budget_usd
      timeout_sec
      review
      agents
      daemon
      bot
      rebase
    ].freeze

    def validate_hash_shaped_keys!(cfg, source_path)
      HASH_SHAPED_KEYS.each do |key|
        next unless cfg.key?(key)

        value = cfg[key]
        next if value.is_a?(Hash)

        raise ConfigError,
              "#{key} in #{describe_source(source_path)} must be a Hash; " \
              "got #{value.inspect} (#{value.class}). Either remove the key " \
              "(defaults will apply) or supply `#{key}: { ... }` with the right shape."
      end
    end

    def validate_stage_skill_by_agent!(cfg, source_path)
      %w[brainstorm plan].each do |stage|
        value = cfg.dig(stage, "skill_by_agent")
        next if value.nil?

        unless value.is_a?(Hash)
          raise ConfigError,
                "#{stage}.skill_by_agent in #{describe_source(source_path)} must be a Hash; " \
                "got #{value.inspect} (#{value.class})"
        end

        value.each do |agent, skill|
          unless skill.is_a?(String) || skill.is_a?(Symbol)
            raise ConfigError,
                  "#{stage}.skill_by_agent.#{agent} in #{describe_source(source_path)} must be a String; " \
                  "got #{skill.inspect} (#{skill.class})"
          end
        end
      end
    end

    # Numeric review-loop knobs that must be positive integers.
    #
    # Path        | Why must be ≥ 1
    # ------------|----------------
    # review.ci.max_attempts            | 0 → CiFix runs once and bails before spawning fix
    # review.browser_test.max_attempts  | 0 → BrowserTest writes browser-blocked.md without spawning
    # review.max_passes                 | 0 → pass loop exits before Phase 2 runs
    # review.max_wall_clock_sec         | 0 → wall_clock_exceeded? trips on first check
    POSITIVE_INTEGER_KEYS = [
      [ %w[review ci max_attempts], "review.ci.max_attempts" ],
      [ %w[review browser_test max_attempts], "review.browser_test.max_attempts" ],
      [ %w[review max_passes], "review.max_passes" ],
      [ %w[review max_wall_clock_sec], "review.max_wall_clock_sec" ]
    ].freeze

    def validate_review_attempts!(cfg, source_path)
      POSITIVE_INTEGER_KEYS.each do |path, label|
        value = cfg.dig(*path)
        next if value.nil?

        unless value.is_a?(Integer) && value.positive?
          raise ConfigError,
                "#{label} in #{describe_source(source_path)} must be a positive integer (>= 1); " \
                "got #{value.inspect} (#{value.class})"
        end
      end
    end

    def validate_reviewers!(cfg, source_path)
      reviewers = cfg.dig("review", "reviewers")
      # Defaults provide []; the only path to nil is a YAML user typing
      # `reviewers:` with no value. Fail loudly instead of silently
      # accepting (downstream code would NoMethodError on .each).
      if reviewers.nil?
        raise ConfigError,
              "review.reviewers in #{describe_source(source_path)} is nil; " \
              "either remove the key (defaults provide []) or supply an Array of reviewer entries"
      end

      unless reviewers.is_a?(Array)
        raise ConfigError,
              "review.reviewers in #{describe_source(source_path)} must be an Array of reviewer entries; got #{reviewers.class}"
      end

      seen_names = {}
      seen_basenames = {}
      reviewers.each_with_index do |entry, idx|
        unless entry.is_a?(Hash)
          raise ConfigError,
                "review.reviewers[#{idx}] in #{describe_source(source_path)} must be a Hash; got #{entry.class}"
        end

        # Required fields: presence + non-empty. Missing or blank values
        # would otherwise NoMethodError or yield broken filenames mid-spawn
        # (closes ce-code-review AC-6). Mirrors the framing used by the
        # output_basename / agent checks below.
        %w[name skill prompt_template].each do |field|
          value = entry[field]
          missing = value.nil? || (value.is_a?(String) && value.strip.empty?)
          next unless missing

          raise ConfigError,
                "review.reviewers[#{idx}].#{field} in #{describe_source(source_path)} is missing"
        end

        name = entry["name"]
        if name && (prev = seen_names[name])
          raise ConfigError,
                "review.reviewers in #{describe_source(source_path)} has duplicate name #{name.inspect} " \
                "at indices [#{prev}, #{idx}]"
        end
        seen_names[name] = idx if name

        # output_basename uniqueness — empty / whitespace-only strings are
        # treated as absent (would yield `reviews/-01.md` which is broken,
        # so reject them explicitly rather than letting the uniqueness
        # check silently allow two empty values to collide on disk).
        basename = entry["output_basename"]
        normalized_basename = basename.is_a?(String) ? basename.strip : basename
        if basename.is_a?(String) && normalized_basename.empty?
          raise ConfigError,
                "review.reviewers[#{idx}].output_basename in #{describe_source(source_path)} must not be empty " \
                "(would produce reviews/-NN.md filenames)"
        end

        # ce-review round-3 P1 #2 — reject path-traversal characters in
        # output_basename. The basename interpolates directly into
        # `reviews/<basename>-NN.md`; without this check, a value like
        # `../escape` produces `reviews/../escape-NN.md`. The retry-
        # loop cleanup in lib/hive/reviewers/agent.rb calls
        # `File.delete(output_path)` on that resolved path, which could
        # then delete files outside the task's `reviews/` directory.
        # Reject `/`, `\`, ASCII NUL, and the path-segment tokens `.`
        # and `..`. After rejection, the basename is guaranteed to be a
        # single safe filename component.
        if normalized_basename.is_a?(String)
          if normalized_basename =~ %r{[/\\\0]} ||
             normalized_basename == "." ||
             normalized_basename == ".."
            raise ConfigError,
                  "review.reviewers[#{idx}].output_basename #{basename.inspect} in #{describe_source(source_path)} " \
                  "must be a single filename component without path separators (/, \\, null) " \
                  "and may not be '.' or '..'"
          end
        end

        if normalized_basename && (prev = seen_basenames[normalized_basename])
          raise ConfigError,
                "review.reviewers in #{describe_source(source_path)} has duplicate output_basename #{basename.inspect} " \
                "at indices [#{prev}, #{idx}] (would cause concurrent file-write collisions)"
        end
        seen_basenames[normalized_basename] = idx if normalized_basename

        # ce-review P2 #6 — reject an output_basename whose per-pass
        # file (`<basename>-NN.md`) would collide with the orchestrator's
        # reserved-prefix namespace (`escalations-`, `ci-blocked`,
        # `browser-`, `fix-guardrail-`, `fix-success-`, `errors-`).
        # Without this check, a reviewer configured with
        # `output_basename: "errors"` silently has its per-pass file
        # classified as orchestrator-owned by `reviewer_file?`, hidden
        # from triage's `discover_reviewer_files`, and overwritten by
        # the U2 errors sink when other reviewers fail in the same pass.
        if normalized_basename
          require "hive/stages/review"
          probe = "#{normalized_basename}-99.md"
          if !Hive::Stages::Review.reviewer_file?(probe)
            reserved = Hive::Stages::Review::ORCHESTRATOR_OWNED_PREFIXES
                       .map { |p| p.chomp("-") }
                       .join(", ")
            raise ConfigError,
                  "review.reviewers[#{idx}].output_basename #{basename.inspect} in #{describe_source(source_path)} " \
                  "starts with a reserved orchestrator-owned prefix; choose a different name " \
                  "(reserved prefixes: #{reserved})"
          end
        end

        # ce-review P3 #8 — validate optional `max_attempts` at config
        # load time. The adapter falls back to the default on coercion
        # failure (defensive), but a load-time error catches typos
        # before the loop spawns its first reviewer.
        if entry.key?("max_attempts")
          max = entry["max_attempts"]
          unless max.is_a?(Integer) && max.positive?
            raise ConfigError,
                  "review.reviewers[#{idx}].max_attempts in #{describe_source(source_path)} " \
                  "must be a positive Integer; got #{max.inspect}"
          end
        end

        validate_agent_name!(
          entry["agent"],
          "review.reviewers[#{idx}].agent",
          source_path
        )
      end
    end

    def validate_role_agent_names!(cfg, source_path)
      ROLE_AGENT_PATHS.each do |path|
        agent = cfg.dig(*path)
        validate_agent_name!(agent, path.join("."), source_path)
      end
    end

    BRAINSTORM_RUNTIMES = %w[headless tmux_interactive].freeze

    def validate_brainstorm_runtime!(cfg, source_path)
      runtime = cfg.dig("brainstorm", "runtime")
      return if runtime.nil?
      return if BRAINSTORM_RUNTIMES.include?(runtime)

      raise ConfigError,
            "brainstorm.runtime in #{describe_source(source_path)} must be one of " \
            "#{BRAINSTORM_RUNTIMES.inspect}; got #{runtime.inspect} (#{runtime.class})"
    end

    # Shared check used by both validate_reviewers! and
    # validate_role_agent_names!: ensure `agent_name` resolves via
    # Hive::AgentProfiles.lookup. Nil values pass through (the field is
    # optional). Each error message lists the registered profile names so
    # an agent reading the failure output learns the valid set.
    def validate_agent_name!(agent_name, label, source_path)
      return if agent_name.nil?

      # AgentProfiles.registered?(name) calls `name.to_sym`, which crashes
      # on Integer / Hash / Array / Boolean with NoMethodError. Guard with
      # a String check first so a user typo like `execute: { agent: 42 }`
      # surfaces as a typed ConfigError instead of an opaque NoMethodError.
      unless agent_name.is_a?(String) || agent_name.is_a?(Symbol)
        raise ConfigError,
              "#{label} in #{describe_source(source_path)} must be a String " \
              "(an agent profile name like \"claude\" or \"codex\"); " \
              "got #{agent_name.inspect} (#{agent_name.class})"
      end

      return if Hive::AgentProfiles.registered?(agent_name)

      raise ConfigError,
            "#{label} #{agent_name.inspect} in #{describe_source(source_path)} " \
            "is not a registered AgentProfile (registered: #{Hive::AgentProfiles.registered_names.inspect})"
    end

    # Stable description of where a config came from, for error messages.
    # When the candidate file does not exist (defaults-only path), point
    # the user at the right path with an explicit "(defaults; no file
    # present)" note instead of pointing them at a phantom file.
    def describe_source(path)
      return path if File.exist?(path)

      "#{path} (defaults; no file present)"
    end

    # Numeric daemon knobs that must be positive integers. Lower bounds
    # encode behavioural floors:
    #   poll_interval_sec >= 5         — anything tighter starves CPU on
    #                                    `hive status` subprocesses
    #   edit_debounce_sec >= 0         — 0 means "no debounce, dispatch
    #                                    on first mtime move"; valid choice
    #   pr_merge_poll_interval_sec >= 60 — `gh pr view` is rate-limited
    #                                      under heavy load
    #   max_concurrent_*  >= 1         — caps below 1 disable dispatch
    #   max_runs_per_day_per_project >= 1
    #   transient_retry_backoff_sec >= 1
    #   shutdown_grace_sec >= 0        — 0 means "no grace, immediate
    #                                    SIGTERM on stop"; valid choice
    #   log_max_bytes >= 1024          — anything smaller breaks Logger
    #   log_max_files >= 1
    DAEMON_NUMERIC_BOUNDS = [
      [ "poll_interval_sec", 5 ],
      [ "edit_debounce_sec", 0 ],
      [ "pr_merge_poll_interval_sec", 60 ],
      [ "max_concurrent_runs", 1 ],
      [ "max_concurrent_per_project", 1 ],
      [ "max_runs_per_day_per_project", 1 ],
      [ "transient_retry_backoff_sec", 1 ],
      [ "shutdown_grace_sec", 0 ],
      [ "log_max_bytes", 1024 ],
      [ "log_max_files", 1 ]
    ].freeze

    def validate_daemon!(cfg, source_path)
      daemon = cfg["daemon"]
      return if daemon.nil?

      enabled = daemon["enabled"]
      unless enabled.nil? || enabled == true || enabled == false
        raise ConfigError,
              "daemon.enabled in #{describe_source(source_path)} must be a boolean " \
              "(true / false); got #{enabled.inspect} (#{enabled.class})"
      end

      autostart = daemon["autostart"]
      unless autostart.nil? || autostart == true || autostart == false
        raise ConfigError,
              "daemon.autostart in #{describe_source(source_path)} must be a boolean " \
              "(true / false); got #{autostart.inspect} (#{autostart.class})"
      end

      DAEMON_NUMERIC_BOUNDS.each do |key, min|
        value = daemon[key]
        next if value.nil?

        unless value.is_a?(Integer) && value >= min
          raise ConfigError,
                "daemon.#{key} in #{describe_source(source_path)} must be an integer " \
                ">= #{min}; got #{value.inspect} (#{value.class})"
        end
      end
    end

    BOT_NUMERIC_BOUNDS = [
      [ "poll_interval_sec", 5, nil ],
      [ "long_poll_timeout_sec", 5, 50 ],
      [ "notification_dedupe_window_sec", 0, nil ],
      [ "conversation_ttl_sec", 60, nil ],
      [ "codex_budget_usd", 0, nil ],
      [ "codex_timeout_sec", 10, nil ],
      [ "shutdown_grace_sec", 0, nil ],
      [ "log_max_bytes", 1024, nil ],
      [ "log_max_files", 1, nil ]
    ].freeze

    BOT_PATH_KEYS = %w[
      pid_file
      log_file
      last_seen_state_file
    ].freeze

    def validate_bot_config!(cfg, source_path)
      bot = cfg["bot"]
      return if bot.nil?

      enabled = bot["enabled"]
      unless enabled.nil? || enabled == true || enabled == false
        raise ConfigError,
              "bot.enabled in #{describe_source(source_path)} must be a boolean " \
              "(true / false); got #{enabled.inspect} (#{enabled.class})"
      end

      validate_bot_allowlist!(bot, source_path)
      validate_bot_numbers!(bot, source_path)
      validate_bot_paths!(bot, source_path)
    end

    def validate_bot_runtime!(bot, source_path)
      telegram_bot_token!
      allowlist = bot["chat_id_allowlist"]
      return if allowlist.is_a?(Array) && !allowlist.empty?

      raise ConfigError,
            "bot.chat_id_allowlist in #{describe_source(source_path)} must contain at least one chat_id " \
            "before hive bot can start"
    end

    def validate_bot_allowlist!(bot, source_path)
      allowlist = bot["chat_id_allowlist"]
      unless allowlist.is_a?(Array)
        raise ConfigError,
              "bot.chat_id_allowlist in #{describe_source(source_path)} must be an Array of Integers; " \
              "got #{allowlist.inspect} (#{allowlist.class})"
      end

      allowlist.each_with_index do |entry, idx|
        next if entry.is_a?(Integer)

        raise ConfigError,
              "bot.chat_id_allowlist[#{idx}] in #{describe_source(source_path)} must be an Integer; " \
              "got #{entry.inspect} (#{entry.class})"
      end
    end

    def validate_bot_numbers!(bot, source_path)
      BOT_NUMERIC_BOUNDS.each do |key, min, max|
        value = bot[key]
        next if value.nil?

        unless value.is_a?(Integer) && value >= min && (max.nil? || value <= max)
          bound = max ? "between #{min} and #{max}" : ">= #{min}"
          raise ConfigError,
                "bot.#{key} in #{describe_source(source_path)} must be an integer #{bound}; " \
                "got #{value.inspect} (#{value.class})"
        end
      end
    end

    def validate_bot_paths!(bot, source_path)
      BOT_PATH_KEYS.each do |key|
        value = bot[key]
        next if value.nil?

        unless value.is_a?(String) && !value.strip.empty?
          raise ConfigError,
                "bot.#{key} in #{describe_source(source_path)} must be a non-empty String path; " \
                "got #{value.inspect} (#{value.class})"
        end
        if unsafe_path_segment?(value)
          raise ConfigError,
                "bot.#{key} in #{describe_source(source_path)} must not contain '..' path segments; " \
                "got #{value.inspect}"
        end
        bot[key] = File.expand_path(value)
      end
    end

    def unsafe_path_segment?(value)
      File.expand_path(value).split(File::SEPARATOR).include?("..") ||
        value.split(/[\\\/]/).include?("..")
    end

    # Validate `rebase:` block from auto-rebase plan
    # (docs/plans/2026-05-14-001-feat-hive-auto-rebase-stale-worktree-plan.md U5).
    # Two keys today: `enabled` (boolean) and `conflict_resolution_timeout_sec`
    # (integer >= 60 — lower bound prevents operationally-useless tiny
    # timeouts that would mark every conflict-resolution as failed).
    def validate_rebase!(cfg, source_path)
      rebase = cfg["rebase"]
      return if rebase.nil?

      enabled = rebase["enabled"]
      unless enabled.nil? || enabled == true || enabled == false
        raise ConfigError,
              "rebase.enabled in #{describe_source(source_path)} must be a boolean " \
              "(true / false); got #{enabled.inspect} (#{enabled.class})"
      end

      timeout = rebase["conflict_resolution_timeout_sec"]
      return if timeout.nil?

      unless timeout.is_a?(Integer) && timeout >= 60
        raise ConfigError,
              "rebase.conflict_resolution_timeout_sec in #{describe_source(source_path)} " \
              "must be an integer >= 60; got #{timeout.inspect} (#{timeout.class})"
      end
    end
  end
end
