require "fileutils"
require "open3"
require "time"

require "hive/agent_profiles"
require "hive/markers"
require "hive/stages/brainstorm"
require "hive/stop_hook_installer"
require "hive/tmux_runner"

module Hive
  module Stages
    module BrainstormTmux
      READY_WAIT_TIMEOUT_SEC = 5
      DONE_POLL_INTERVAL_SEC = 0.5
      TERMINAL_MARKERS = %i[waiting complete error].freeze

      module_function

      def run!(task, cfg)
        reset_signal_files(task)
        profile = Hive::AgentProfiles.lookup(:claude, cfg: cfg)
        prompt = Hive::Stages::Brainstorm.render_prompt(task, cfg, profile: profile)
        Hive::Markers.set(task.state_file, :agent_working,
                          pid: Process.pid,
                          started: Time.now.utc.iso8601)

        runner = build_runner(task)
        settings_path = nil
        begin
          settings_path = Hive::StopHookInstaller.install(stage_dir: task.folder)
          runner.start_detached(command: wrapper_command(task, profile))
          wait_until_session_exists!(runner)
          runner.send_prompt(prompt)
          marker = wait_for_terminal_marker(task, runner, timeout_sec(cfg))
          { commit: Hive::Stages::Brainstorm.action_for(marker.name), status: marker.name }
        ensure
          runner.kill_session if runner
          cleanup_scratch(settings_path)
          cleanup_done(task)
        end
      end

      def session_name_for(task)
        "hive-2-brainstorm-#{task.slug}"[0, 250]
      end

      def build_runner(task)
        Hive::TmuxRunner.new(
          name: session_name_for(task),
          cwd: task.folder,
          env: {
            "ANTHROPIC_API_KEY" => "",
            "CLAUDE_API_KEY" => "",
            "HIVE_TASK_STAGE_DIR" => task.folder
          },
          socket_name: ENV["HIVE_TMUX_SOCKET"]
        )
      end

      def wrapper_command(task, profile)
        [
          "bash",
          File.expand_path("../scripts/interactive_claude_wrapper.sh", __dir__),
          "--cwd", task.folder,
          "--add-dir", task.folder,
          "--bin", profile.bin
        ]
      end

      def wait_until_session_exists!(runner)
        deadline = Time.now + READY_WAIT_TIMEOUT_SEC
        until runner.session_exists?
          raise Hive::AgentError, "tmux session #{runner.name} did not start" if Time.now >= deadline

          sleep 0.1
        end
      end

      def wait_for_terminal_marker(task, _runner, timeout)
        deadline = Time.now + timeout
        loop do
          if File.exist?(done_path(task))
            marker = Hive::Markers.current(task.state_file)
            return marker if terminal_marker?(marker)

            cleanup_done(task)
          end

          if Time.now >= deadline
            Hive::Markers.set(task.state_file, :error, reason: "timeout", timeout_sec: timeout)
            return Hive::Markers.current(task.state_file)
          end

          sleep [ poll_interval, deadline - Time.now ].min
        end
      end

      def terminal_marker?(marker)
        TERMINAL_MARKERS.include?(marker.name)
      end

      def timeout_sec(cfg)
        Integer(cfg.dig("timeout_sec", "brainstorm"))
      end

      def poll_interval
        Float(ENV.fetch("HIVE_BRAINSTORM_TMUX_POLL_INTERVAL_SEC", DONE_POLL_INTERVAL_SEC.to_s))
      end

      def reset_signal_files(task)
        cleanup_done(task)
        result = result_path(task)
        File.delete(result) if File.exist?(result)
      end

      def cleanup_done(task)
        path = done_path(task)
        File.delete(path) if File.exist?(path)
      end

      def cleanup_scratch(settings_path)
        return unless settings_path

        File.delete(settings_path) if File.exist?(settings_path)
        dir = File.dirname(settings_path)
        Dir.rmdir(dir) if Dir.exist?(dir) && Dir.empty?(dir)
      rescue Errno::ENOENT, Errno::ENOTEMPTY
        nil
      end

      def done_path(task)
        File.join(task.folder, ".done")
      end

      def result_path(task)
        File.join(task.folder, "result.json")
      end
    end
  end
end
