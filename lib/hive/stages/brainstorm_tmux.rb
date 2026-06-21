require "hive/claude_launcher"
require "hive/stages/brainstorm"

module Hive
  module Stages
    module BrainstormTmux
      READY_WAIT_TIMEOUT_SEC = Hive::ClaudeLauncher::READY_WAIT_TIMEOUT_SEC
      DONE_POLL_INTERVAL_SEC = Hive::ClaudeLauncher::DONE_POLL_INTERVAL_SEC
      SENTINEL_POLL_INTERVAL_SEC = Hive::ClaudeLauncher::SENTINEL_POLL_INTERVAL_SEC
      SENTINEL_CAPTURE_BYTES = Hive::ClaudeLauncher::SENTINEL_CAPTURE_BYTES
      CLAUDE_READY_WAIT_TIMEOUT_SEC = Hive::ClaudeLauncher::CLAUDE_READY_WAIT_TIMEOUT_SEC
      CLAUDE_READY_POLL_INTERVAL_SEC = Hive::ClaudeLauncher::CLAUDE_READY_POLL_INTERVAL_SEC
      MIN_TMUX_VERSION = Hive::ClaudeLauncher::MIN_TMUX_VERSION
      TERMINAL_MARKERS = Hive::ClaudeLauncher::TERMINAL_MARKERS

      module_function

      def run!(task, cfg)
        profile = Hive::AgentProfiles.lookup(:claude, cfg: cfg)
        prompt = Hive::Stages::Brainstorm.render_prompt(task, cfg, profile: profile)
        scope = Hive::Stages::Base.stage_permission_scope_or_mark!(
          cfg, "brainstorm", task, profile,
          default_allowed_tools: Hive::ClaudeLauncher::PLANNER_ALLOWED_TOOLS
        )
        Hive::ClaudeLauncher.launch!(
          task: task,
          cfg: cfg,
          prompt: prompt,
          add_dirs: scope.fetch(:add_dirs),
          cwd: task.folder,
          max_budget_usd: cfg.dig("budget_usd", "brainstorm"),
          timeout_sec: cfg.dig("timeout_sec", "brainstorm"),
          log_label: "brainstorm",
          session_name: session_name_for(task),
          status_mode: :state_file_marker,
          profile: profile,
          permission_mode: scope.fetch(:permission_mode),
          allowed_tools: scope.fetch(:allowed_tools),
          disallowed_tools: scope.fetch(:disallowed_tools)
        )
        marker = Hive::Markers.current(task.state_file)
        { commit: Hive::Stages::Brainstorm.action_for(marker.name), status: marker.name }
      end

      def session_name_for(task)
        Hive::ClaudeLauncher.tmux_session_name("2-brainstorm", task) # coding-scoped: coding brainstorm stage tmux session
      end

      def preflight_tmux!(tmux_bin: Hive::ClaudeLauncher.tmux_bin)
        Hive::ClaudeLauncher.preflight_tmux!(tmux_bin: tmux_bin)
      end

      def tmux_status(tmux_bin: Hive::ClaudeLauncher.tmux_bin)
        Hive::ClaudeLauncher.tmux_status(tmux_bin: tmux_bin)
      end

      def parse_tmux_version(output)
        Hive::ClaudeLauncher.parse_tmux_version(output)
      end

      def version_tuple(version)
        Hive::ClaudeLauncher.version_tuple(version)
      end

      def tmux_bin
        Hive::ClaudeLauncher.tmux_bin
      end

      def wait_until_session_exists!(runner)
        Hive::ClaudeLauncher.wait_until_session_exists!(runner)
      end

      def prepare_claude_session!(runner)
        Hive::ClaudeLauncher.prepare_claude_session!(runner)
      end

      def claude_trust_prompt?(pane)
        Hive::ClaudeLauncher.claude_trust_prompt?(pane)
      end

      def claude_ready_prompt?(pane)
        Hive::ClaudeLauncher.claude_ready_prompt?(pane)
      end

      def wait_for_terminal_marker(task, runner, timeout)
        Hive::ClaudeLauncher.wait_for_terminal_marker(task, runner, timeout)
      end

      def marker_from_sentinel_tail(task, runner)
        Hive::ClaudeLauncher.marker_from_sentinel_tail(task, runner)
      end

      def record_claude_pid(task, runner)
        Hive::ClaudeLauncher.record_claude_pid(task, runner)
      end

      def sweep_orphan_processes(task)
        Hive::ClaudeLauncher.sweep_orphan_processes(task)
      end

      def orphan_sweep_pattern(task)
        Hive::ClaudeLauncher.orphan_sweep_pattern(task)
      end

      def poll_interval
        Hive::ClaudeLauncher.poll_interval
      end

      def sentinel_poll_interval
        Hive::ClaudeLauncher.sentinel_poll_interval
      end

      def ready_wait_timeout
        Hive::ClaudeLauncher.ready_wait_timeout
      end

      def claude_ready_wait_timeout
        Hive::ClaudeLauncher.claude_ready_wait_timeout
      end

      def session_ready_wait_timeout
        Hive::ClaudeLauncher.session_ready_wait_timeout
      end

      def pid_ready_wait_timeout
        Hive::ClaudeLauncher.pid_ready_wait_timeout
      end

      def reset_signal_files(task)
        Hive::ClaudeLauncher.reset_signal_files(task)
      end

      def cleanup_done(task)
        Hive::ClaudeLauncher.cleanup_done(task)
      end

      def cleanup_scratch(settings_path)
        Hive::ClaudeLauncher.cleanup_scratch(settings_path)
      end

      def done_path(task)
        Hive::ClaudeLauncher.done_path(task)
      end

      def result_path(task)
        Hive::ClaudeLauncher.result_path(task)
      end
    end
  end
end
