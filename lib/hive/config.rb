require "yaml"
require "fileutils"
require "hive/agent_profiles"

module Hive
  module Config
    DEFAULTS = {
      "hive_state_path" => ".hive-state",
      "worktree_root" => nil,
      "max_review_passes" => 4,
      "default_branch" => nil,
      "project_name" => nil,
      # Budget and timeout caps are GENEROUS sanity caps for runaway agents,
      # not cost targets. Most tasks finish well within them; a stuck loop
      # still gets cut off. Bumped ~5x from the original conservative values
      # in plan 2026-05-04-001 (per ADR-023). The deprecated `execute_review`
      # key was dropped here — 5-review owns reviewer budgets per ADR-014, so
      # nothing reads it. Existing project configs that still set it survive
      # via deep-merge but the key is no longer rendered for fresh projects.
      "budget_usd" => {
        "brainstorm" => 50,
        "plan" => 100,
        "execute_implementation" => 500,
        "pr" => 50,
        "review_ci" => 100,
        "review_triage" => 75,
        "review_fix" => 500,
        "review_browser" => 100
      },
      "timeout_sec" => {
        "brainstorm" => 1800,
        "plan" => 3600,
        "execute_implementation" => 14400,
        "pr" => 1800,
        "review_ci" => 3600,
        "review_triage" => 1800,
        "review_fix" => 14400,
        "review_browser" => 3600
      },
      # Stage-level agent for the three single-agent stages. The 5-review
      # stage has its own per-role agent fields under "review.{ci,triage,
      # fix,browser_test}.agent". Runtime fallback in stage code stays
      # `cfg.dig("<stage>", "agent") || "claude"` so legacy configs without
      # these keys keep behaving as today (ADR-023). The recommended-default
      # for execute is `codex` only at the rendered-template level, not in
      # DEFAULTS itself, to avoid silently flipping the implementer for old
      # projects on next load.
      "brainstorm" => { "agent" => "claude" },
      "plan" => { "agent" => "claude" },
      "execute" => { "agent" => "claude" },
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
      # Configuration for the 5-review stage's autonomous loop. Each role
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
        "max_passes" => 4,
        "max_wall_clock_sec" => 5400
      }
    }.freeze

    # Roles that take an `agent` profile-name field. Used by validation to
    # check each role's value resolves to a registered AgentProfile.
    ROLE_AGENT_PATHS = [
      %w[brainstorm agent],
      %w[plan agent],
      %w[execute agent],
      %w[review ci agent],
      %w[review triage agent],
      %w[review fix agent],
      %w[review browser_test agent]
    ].freeze

    module_function

    def hive_home
      ENV["HIVE_HOME"] || File.expand_path("~/Dev/hive")
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
      validate_hive_home!
      path = global_config_path
      return [] unless File.exist?(path)

      data = YAML.safe_load(File.read(path)) || {}
      raise ConfigError, "global config at #{path} must be a hash" unless data.is_a?(Hash)

      Array(data["registered_projects"]).map do |entry|
        raise ConfigError, "registered_projects entries must be hashes" unless entry.is_a?(Hash)

        {
          "name" => entry.fetch("name"),
          "path" => File.expand_path(entry.fetch("path")),
          "hive_state_path" => entry["hive_state_path"] ||
            File.join(File.expand_path(entry.fetch("path")), ".hive-state")
        }
      end
    end

    def find_project(name)
      registered_projects.find { |p| p["name"] == name }
    end

    def register_project(name:, path:)
      FileUtils.mkdir_p(hive_home)
      data = if File.exist?(global_config_path)
               YAML.safe_load(File.read(global_config_path)) || {}
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
      File.write(global_config_path, data.to_yaml)
      entry
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
      validate_reviewers!(cfg, source_path)
      validate_role_agent_names!(cfg, source_path)
      validate_review_attempts!(cfg, source_path)
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

        if normalized_basename && (prev = seen_basenames[normalized_basename])
          raise ConfigError,
                "review.reviewers in #{describe_source(source_path)} has duplicate output_basename #{basename.inspect} " \
                "at indices [#{prev}, #{idx}] (would cause concurrent file-write collisions)"
        end
        seen_basenames[normalized_basename] = idx if normalized_basename

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
  end
end
