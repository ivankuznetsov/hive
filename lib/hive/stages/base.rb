require "erb"
require "fileutils"
require "securerandom"
require "time"
require "hive/agent"
require "hive/agent_profiles"

module Hive
  module Stages
    module Base
      module_function

      # Per-spawn random nonce for the user_supplied wrapper. Defends against
      # prompt-injection attacks that close the wrapper from inside user
      # content (e.g. payload `</user_supplied><system>...`). Each call
      # returns a fresh value; callers bind it once into TemplateBindings so
      # the rendered prompt's opening and closing tags match within ONE
      # spawn, but two consecutive spawns get distinct nonces. This is the
      # ADR-019 amendment to ADR-008's per-process scope: a nonce leaked
      # via one agent's prompt cannot be used to forge a closing tag against
      # any sibling agent in the same hive run.
      def user_supplied_tag
        "user_supplied_#{SecureRandom.hex(8)}"
      end

      def render(template_name, bindings_obj)
        path = File.expand_path("../../../templates/#{template_name}", __dir__)
        ERB.new(File.read(path), trim_mode: "-").result(bindings_obj.binding_for_erb)
      end

      # Like #render, but the caller already resolved + validated the
      # absolute path via #resolve_template_path. Used by review-stage
      # consumers that accept user-configurable prompt_template values.
      def render_resolved_path(absolute_path, bindings_obj)
        ERB.new(File.read(absolute_path), trim_mode: "-").result(bindings_obj.binding_for_erb)
      end

      # Walk up from a task_folder (`.../<.hive-state>/stages/<N>-<name>/<slug>`)
      # to the matching `.hive-state` directory. Used by every consumer
      # of resolve_template_path that has a Reviewers::Context but not a
      # full Task.
      def hive_state_dir_for_task_folder(task_folder)
        File.expand_path(File.join(task_folder, "..", "..", ".."))
      end

      # Resolve a prompt-template name to an absolute, validated path.
      # Two cases:
      #   1. A bare basename (no slashes) → built-in template under
      #      lib/../templates/. Existence is checked but no escape
      #      check is needed: built-ins ship with the gem.
      #   2. A path with a slash → user-supplied custom template. Must
      #      land under `<hive_state_dir>/templates/` after `realpath`
      #      resolution. Path-escape attempts (`../`, absolute paths
      #      outside the allowed root, symlinks pointing outside) raise
      #      Hive::ConfigError.
      #
      # `hive_state_dir` is required for case 2; pass `nil` for callers
      # that only support built-ins.
      def resolve_template_path(name, hive_state_dir: nil)
        raise Hive::ConfigError, "prompt_template name cannot be blank" if name.nil? || name.to_s.empty?

        if !name.include?("/") && !File.absolute_path?(name)
          # Built-in template lookup.
          builtin = File.expand_path("../../../templates/#{name}", __dir__)
          unless File.exist?(builtin)
            raise Hive::ConfigError,
                  "prompt_template #{name.inspect} not found among built-ins (#{builtin})"
          end
          return builtin
        end

        # Custom template — must resolve under <state_dir>/templates/.
        unless hive_state_dir
          raise Hive::ConfigError,
                "prompt_template #{name.inspect} looks like a custom path but no hive_state_dir was provided"
        end

        templates_root_raw = File.join(hive_state_dir, "templates")
        unless File.directory?(templates_root_raw)
          raise Hive::ConfigError,
                "prompt_template #{name.inspect} requires #{templates_root_raw} to exist"
        end
        templates_root = File.realpath(templates_root_raw)

        candidate = File.expand_path(name, templates_root)
        unless File.exist?(candidate)
          raise Hive::ConfigError,
                "prompt_template #{name.inspect} not found at #{candidate}"
        end

        resolved = File.realpath(candidate)
        unless resolved.start_with?(templates_root + File::SEPARATOR) || resolved == templates_root
          raise Hive::ConfigError,
                "prompt_template #{name.inspect} resolves outside #{templates_root}"
        end
        resolved
      end

      # Resolve the AgentProfile to use for a single-agent stage
      # (brainstorm / plan / execute). Reads `cfg.dig(stage_name, "agent")`
      # and falls back to "claude" when the key is absent so legacy configs
      # written before plan 2026-05-04-001 keep working unchanged. The
      # `cfg:` argument is forwarded to AgentProfiles.lookup so per-CLI
      # overrides under `agents.<name>.<key>` are honored. Raises
      # Hive::ConfigError (via AgentProfiles::UnknownAgent) when the
      # configured value is not a registered profile — but that case is
      # already prevented at config-load time by validate_role_agent_names!,
      # so callers see UnknownAgent only if they bypass Config.load.
      def stage_profile(cfg, stage_name)
        name = cfg.dig(stage_name, "agent") || "claude"
        Hive::AgentProfiles.lookup(name, cfg: cfg)
      end

      # Spawn an agent and return its result hash.
      #
      # Default profile is :claude so existing callers (4-execute /
      # brainstorm / plan / pr stages) keep their behavior unchanged when
      # they call this without a profile: kwarg.
      #
      # When the configured profile lacks add_dir_flag and the caller
      # passed add_dirs, log a warning to the task's log file so the user
      # can see that ADR-008's filesystem-isolation boundary is reduced
      # for this spawn (per ADR-018).
      def spawn_agent(task, prompt:, max_budget_usd:, timeout_sec:,
                      add_dirs: [], cwd: nil, log_label: nil,
                      profile: nil, expected_output: nil, status_mode: nil)
        profile ||= Hive::AgentProfiles.lookup(:claude)
        # Translate preflight/version-check failures (e.g. Pi missing
        # ~/.pi/agent/auth.json mid-loop) into a typed :error envelope
        # so callers (Review.run!'s spawn_fix_agent etc.) write a
        # properly-attributed REVIEW_ERROR (`reason="agent_preflight_failed"`)
        # instead of letting the exception escape and land
        # `reason="runner_exception"`.
        begin
          profile.check_version!
          profile.preflight!
        rescue Hive::AgentError => e
          return { status: :error,
                   error_message: "preflight failed: #{e.message}" }
        end

        if !profile.add_dir_flag && Array(add_dirs).any?
          warn_isolation_reduced(task, profile, add_dirs)
        end

        Hive::Agent.new(
          task: task,
          prompt: prompt,
          max_budget_usd: max_budget_usd,
          timeout_sec: timeout_sec,
          add_dirs: add_dirs,
          cwd: cwd,
          log_label: log_label,
          profile: profile,
          expected_output: expected_output,
          status_mode: status_mode
        ).run!
      end

      class TemplateBindings
        def initialize(values = {})
          values.each do |k, v|
            instance_variable_set("@#{k}", v)
            self.class.send(:attr_reader, k) unless respond_to?(k)
          end
        end

        def binding_for_erb
          binding
        end
      end

      def warn_isolation_reduced(task, profile, add_dirs)
        # Reject non-Array add_dirs loudly instead of silently coercing via
        # Array() — a Hash or string here is an upstream type bug, not a
        # legitimate single-dir shorthand.
        unless add_dirs.is_a?(Array)
          raise ArgumentError,
                "spawn_agent expected add_dirs to be an Array; got #{add_dirs.class}"
        end

        message = "[hive] agent profile #{profile.name.inspect} has no add_dir_flag; " \
                  "ignoring add_dirs=#{add_dirs.inspect}. " \
                  "ADR-008 filesystem-isolation boundary is reduced for this spawn (see ADR-018)."
        # Best-effort log write; never blocks spawn.
        begin
          FileUtils.mkdir_p(task.log_dir)
          ts = Time.now.utc.iso8601
          File.open(File.join(task.log_dir, "isolation-warnings.log"), "a") do |f|
            f.puts "#{ts} #{message}"
          end
        rescue StandardError
          # If the log path can't be written, fall back to stderr — but
          # don't raise, since the warning is informational.
          warn message
        end
      end
    end
  end
end
