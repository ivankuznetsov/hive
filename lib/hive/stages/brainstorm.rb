require "hive/stages/base"
require "hive/config"
require "hive/claude_launcher"
require "hive/markers"

module Hive
  module Stages
    module Brainstorm
      module_function

      def run!(task, cfg)
        case runtime_for(cfg)
        when :headless
          profile = Hive::Stages::Base.stage_profile(cfg, "brainstorm")
          if profile.name == :claude
            run_claude!(task, cfg_with_claude_mode(cfg, :headless), profile: profile)
          else
            run_headless!(task, cfg, profile: profile)
          end
        when :tmux_interactive
          run_claude!(task, cfg)
        end
      end

      def runtime_for(cfg)
        agent_name = (cfg.dig("brainstorm", "agent") || "claude").to_s
        return :headless unless agent_name == "claude"

        if !Hive::Config.explicit_claude_mode?(cfg) &&
           Hive::Config.explicit_brainstorm_runtime?(cfg)
          return legacy_runtime_for(cfg.dig("brainstorm", "runtime"))
        end

        case Hive::Config.claude_mode(cfg)
        when :headless then :headless
        when :tmux then :tmux_interactive
        end
      end

      def legacy_runtime_for(runtime)
        case runtime
        when "headless" then :headless
        when "tmux_interactive" then :tmux_interactive
        else
          raise Hive::ConfigError,
                "brainstorm.runtime must be one of #{Hive::Config::BRAINSTORM_RUNTIMES.inspect}; " \
                "got #{runtime.inspect}"
        end
      end

      def run_headless!(task, cfg, profile: nil)
        profile ||= Hive::Stages::Base.stage_profile(cfg, "brainstorm")
        artifact_before = artifact_snapshot(task.state_file)
        prompt = render_prompt(task, cfg, profile: profile)
        scope = Hive::Stages::Base.stage_permission_scope_or_mark!(
          cfg, "brainstorm", task, profile,
          default_allowed_tools: Hive::ClaudeLauncher::PLANNER_ALLOWED_TOOLS
        )
        # By default add_dirs is limited to the task folder. Brainstorm
        # operates on user-supplied idea text and should not have write
        # access to the project source code: a wide add-dir would let a
        # prompt-injected idea reach project files. A `scoped` brainstorm
        # with `dirs:` deliberately opts into a wider add-dir set
        # (scope.fetch(:add_dirs) appends those extras) — that is an
        # operator's explicit, config-level choice, not the default.
        # (Claude-on-tmux is now routed through `run_claude!`; this method
        # only covers codex / pi — both run with their own profile
        # permissions, not Claude's `--dangerously-skip-permissions`.)
        result = Hive::Stages::Base.spawn_agent(
          task,
          prompt: prompt,
          add_dirs: scope.fetch(:add_dirs),
          cwd: task.folder,
          max_budget_usd: cfg.dig("budget_usd", "brainstorm"),
          timeout_sec: cfg.dig("timeout_sec", "brainstorm"),
          log_label: "brainstorm",
          profile: profile,
          **Hive::Stages::Base.tool_scope_kwargs(scope),
          # Pin the status-detection mode regardless of which profile the
          # user picked: brainstorm's lifecycle contract is "agent writes
          # WAITING/COMPLETE marker to brainstorm.md", which only the
          # :state_file_marker mode honors. Codex's profile default is
          # :output_file_exists, which would never satisfy this stage.
          status_mode: :state_file_marker
        )
        result_for_spawn(task, result, artifact_before)
      end

      def run_claude!(task, cfg, profile: nil)
        profile ||= Hive::Stages::Base.stage_profile(cfg, "brainstorm")
        artifact_before = artifact_snapshot(task.state_file)
        prompt = render_prompt(task, cfg, profile: profile)
        scope = Hive::Stages::Base.stage_permission_scope_or_mark!(
          cfg, "brainstorm", task, profile,
          default_allowed_tools: Hive::ClaudeLauncher::PLANNER_ALLOWED_TOOLS
        )
        result = Hive::Stages::Base.spawn_claude_with_tmux_marker!(
          task,
          cfg,
          prompt: prompt,
          add_dirs: scope.fetch(:add_dirs),
          cwd: task.folder,
          max_budget_usd: cfg.dig("budget_usd", "brainstorm"),
          timeout_sec: cfg.dig("timeout_sec", "brainstorm"),
          log_label: "brainstorm",
          profile: profile,
          session_name: Hive::ClaudeLauncher.tmux_session_name("2-brainstorm", task), # coding-scoped: coding brainstorm stage tmux session
          status_mode: :state_file_marker,
          **Hive::Stages::Base.tool_scope_kwargs(scope)
        )
        result_for_spawn(task, result, artifact_before)
      end

      def result_for_spawn(task, result, artifact_before)
        marker = Hive::Markers.current(task.state_file)
        valid_artifact = artifact_valid?(task.state_file)
        artifact_changed = artifact_snapshot(task.state_file) != artifact_before
        spawn_status = result.is_a?(Hash) ? result[:status]&.to_sym : nil

        if valid_artifact &&
           (%i[waiting complete terminal_replay].include?(spawn_status) ||
            (artifact_changed && spawn_status == :error))
          return { commit: action_for(marker.name), status: marker.name }
        end

        # Preserve a specific marker written by the launcher/agent. It already
        # carries the current attempt projection and is stronger evidence than
        # a synthesized Brainstorm fallback.
        if marker.name == :error
          return { commit: action_for(marker.name), status: marker.name }
        end

        if valid_artifact
          stamp_spawn_error(task, result)
        elsif %i[waiting complete terminal_replay].include?(spawn_status)
          Hive::Markers.set(
            task.state_file, :error,
            reason: "brainstorm_artifact_invalid",
            message: "brainstorm.md is missing a valid Round or Requirements artifact"
          )
        else
          stamp_spawn_error(task, result)
        end

        marker = Hive::Markers.current(task.state_file)
        { commit: action_for(marker.name), status: marker.name }
      end

      # A Brainstorm success is a durable artifact, not merely a process exit
      # or terminal receipt. Keep the validation intentionally structural:
      # WAITING requires a numbered Round section; COMPLETE requires a
      # non-empty Requirements section. Marker-only and unrelated markdown are
      # never sufficient.
      def artifact_valid?(path)
        return false unless File.file?(path) && File.size(path).positive?

        body = File.read(path, encoding: "UTF-8").scrub
        marker = Hive::Markers.current(path)
        case marker.name
        when :waiting
          body.match?(/^##\s+Round\s+\d+\b/i)
        when :complete
          requirements = body.split(/^##\s+Requirements\b.*$/i, 2)[1]
          requirements && requirements.gsub(Hive::Markers::MARKER_RE, "").strip != ""
        else
          false
        end
      rescue SystemCallError, IOError
        false
      end

      def artifact_snapshot(path)
        return nil unless File.file?(path)

        File.read(path, mode: "rb")
      rescue SystemCallError, IOError
        nil
      end

      def stamp_spawn_error(task, result)
        result = {} unless result.is_a?(Hash)
        details = result[:failure_details].is_a?(Hash) ? result[:failure_details] : {}
        reason = result[:failure_origin].to_s
        reason = "brainstorm_agent_failed" if reason.empty?
        message = result[:error_message].to_s
        message = details[:diagnostic].to_s if message.empty?
        message = "brainstorm agent did not produce a valid artifact" if message.empty?
        attrs = {
          reason: reason,
          provider: details[:provider],
          subtype: details[:subtype],
          max_budget_usd: details[:configured_cap_usd],
          observed_cost_usd: details[:observed_cost_usd],
          remedy: details[:remedy],
          message: message.byteslice(0, 200).to_s.scrub
        }.compact
        Hive::Markers.set(task.state_file, :error, **attrs)
      end

      # Returns a new cfg Hash with `claude.mode` overridden, leaving the
      # caller's cfg untouched (the dispatcher passes its cfg by reference
      # to many stage helpers; mutating it would surprise unrelated
      # call-sites that read claude.mode later in the same run).
      def cfg_with_claude_mode(cfg, mode)
        desired = mode.to_s
        return cfg if cfg.dig("claude", "mode") == desired

        existing_claude = cfg["claude"].is_a?(Hash) ? cfg["claude"] : {}
        cfg.merge("claude" => existing_claude.merge("mode" => desired))
      end

      def render_prompt(task, cfg, profile:)
        idea_path = File.join(task.folder, "idea.md")
        idea_text = File.exist?(idea_path) ? File.read(idea_path) : ""
        skill = cfg.dig("brainstorm", "skill") ||
          Hive::Config::DEFAULTS.dig("brainstorm", "skill")
        Hive::Stages::Base.render(
          "brainstorm_prompt.md.erb",
          Hive::Stages::Base::TemplateBindings.new(
            project_name: File.basename(task.project_root),
            task_folder: task.folder,
            idea_text: idea_text,
            user_supplied_tag: Hive::Stages::Base.user_supplied_tag,
            skill_invocation: profile.format_skill_invocation(skill)
          )
        )
      end

      def action_for(marker_name)
        return "none" if marker_name == :none

        Hive::Stages::Base.marker_commit_action(marker_name)
      end
    end
  end
end
