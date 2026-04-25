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
      "budget_usd" => {
        "brainstorm" => 10,
        "plan" => 20,
        "execute_implementation" => 100,
        "execute_review" => 50,
        "pr" => 10,
        "review_ci" => 25,
        "review_triage" => 15,
        "review_fix" => 100,
        "review_browser" => 25
      },
      "timeout_sec" => {
        "brainstorm" => 300,
        "plan" => 600,
        "execute_implementation" => 2700,
        "execute_review" => 600,
        "pr" => 300,
        "review_ci" => 600,
        "review_triage" => 300,
        "review_fix" => 2700,
        "review_browser" => 900
      },
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

    def registered_projects
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
    # the explicit semantic for `review.reviewers` per ADR-018, and it
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
      validate_reviewers!(cfg, source_path)
      validate_role_agent_names!(cfg, source_path)
    end

    def validate_reviewers!(cfg, source_path)
      reviewers = cfg.dig("review", "reviewers")
      return if reviewers.nil? # only present after merge if defaults still hold

      unless reviewers.is_a?(Array)
        raise ConfigError,
              "review.reviewers in #{source_path} must be an Array of reviewer entries; got #{reviewers.class}"
      end

      seen_names = {}
      seen_basenames = {}
      reviewers.each_with_index do |entry, idx|
        unless entry.is_a?(Hash)
          raise ConfigError,
                "review.reviewers[#{idx}] in #{source_path} must be a Hash; got #{entry.class}"
        end

        name = entry["name"]
        if name && (prev = seen_names[name])
          raise ConfigError,
                "review.reviewers in #{source_path} has duplicate name #{name.inspect} " \
                "at indices [#{prev}, #{idx}]"
        end
        seen_names[name] = idx if name

        basename = entry["output_basename"]
        if basename && (prev = seen_basenames[basename])
          raise ConfigError,
                "review.reviewers in #{source_path} has duplicate output_basename #{basename.inspect} " \
                "at indices [#{prev}, #{idx}] (would cause concurrent file-write collisions)"
        end
        seen_basenames[basename] = idx if basename

        # Each agent reviewer entry must reference a registered profile.
        agent = entry["agent"]
        if agent && !Hive::AgentProfiles.registered?(agent)
          raise ConfigError,
                "review.reviewers[#{idx}].agent #{agent.inspect} in #{source_path} " \
                "is not a registered AgentProfile (registered: #{Hive::AgentProfiles.registered_names.inspect})"
        end
      end
    end

    def validate_role_agent_names!(cfg, source_path)
      ROLE_AGENT_PATHS.each do |path|
        agent = cfg.dig(*path)
        next if agent.nil?
        next if Hive::AgentProfiles.registered?(agent)

        raise ConfigError,
              "#{path.join('.')} #{agent.inspect} in #{source_path} " \
              "is not a registered AgentProfile (registered: #{Hive::AgentProfiles.registered_names.inspect})"
      end
    end
  end
end
