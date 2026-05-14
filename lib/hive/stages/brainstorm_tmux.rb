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
      SENTINEL_POLL_INTERVAL_SEC = 5
      SENTINEL_CAPTURE_BYTES = 8192
      MIN_TMUX_VERSION = "3.0"
      TERMINAL_MARKERS = %i[waiting complete error].freeze

      module_function

      def run!(task, cfg)
        reset_signal_files(task)
        profile = Hive::AgentProfiles.lookup(:claude, cfg: cfg)
        runner = build_runner(task)
        preflight!(profile, runner)

        prompt = Hive::Stages::Brainstorm.render_prompt(task, cfg, profile: profile)
        Hive::Markers.set(task.state_file, :agent_working,
                          pid: Process.pid,
                          started: Time.now.utc.iso8601)

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
          sweep_orphan_processes(task)
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
          tmux_bin: tmux_bin,
          socket_name: ENV["HIVE_TMUX_SOCKET"]
        )
      end

      def preflight!(profile, runner)
        preflight_tmux!
        profile.check_version!
        if runner.session_exists?
          raise Hive::AgentError,
                "tmux session #{runner.name} already exists; attach with `tmux attach -t #{runner.name}` " \
                "or kill it before retrying"
        end
      end

      def preflight_tmux!(tmux_bin: self.tmux_bin)
        out, err, status = Open3.capture3(tmux_bin, "-V")
        unless status.success?
          raise Hive::AgentError, "tmux not runnable: #{tmux_bin} #{err.strip}"
        end

        version = parse_tmux_version(out)
        unless version
          raise Hive::AgentError, "could not parse tmux -V output: #{out.inspect}"
        end

        if (version_tuple(version) <=> version_tuple(MIN_TMUX_VERSION)).negative?
          raise Hive::AgentError, "tmux #{version} below minimum #{MIN_TMUX_VERSION}"
        end

        version
      rescue Errno::ENOENT, Errno::EACCES => e
        raise Hive::AgentError, "tmux binary not runnable: #{tmux_bin} (#{e.class.name.split('::').last}: #{e.message})"
      end

      def tmux_status(tmux_bin: self.tmux_bin)
        version = preflight_tmux!(tmux_bin: tmux_bin)
        [ :present, "tmux #{version} found" ]
      rescue Hive::AgentError => e
        [ :missing, e.message ]
      end

      def parse_tmux_version(output)
        output[/tmux\s+(\d+(?:\.\d+)?)/, 1]
      end

      def version_tuple(version)
        version.split(".").map(&:to_i)
      end

      def tmux_bin
        ENV.fetch("HIVE_TMUX_BIN", "tmux")
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

      def wait_for_terminal_marker(task, runner, timeout)
        deadline = Time.now + timeout
        last_sentinel_check = Time.at(0)
        loop do
          if File.exist?(done_path(task))
            marker = Hive::Markers.current(task.state_file)
            return marker if terminal_marker?(marker)

            cleanup_done(task)
          end

          if Time.now - last_sentinel_check >= sentinel_poll_interval
            last_sentinel_check = Time.now
            marker = marker_from_sentinel_tail(task, runner)
            return marker if marker
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

      def marker_from_sentinel_tail(task, runner)
        marker = Hive::Markers.current(task.state_file)
        return nil unless terminal_marker?(marker)

        pane = runner.capture_pane_tail(bytes: SENTINEL_CAPTURE_BYTES)
        pane_marker_names(pane).include?(marker.name) ? marker : nil
      rescue Hive::TmuxError
        nil
      end

      def pane_marker_names(text)
        text.scan(Hive::Markers::MARKER_RE).map do
          Regexp.last_match[:name].downcase.to_sym
        end
      end

      def timeout_sec(cfg)
        Integer(cfg.dig("timeout_sec", "brainstorm"))
      end

      def poll_interval
        Float(ENV.fetch("HIVE_BRAINSTORM_TMUX_POLL_INTERVAL_SEC", DONE_POLL_INTERVAL_SEC.to_s))
      end

      def sentinel_poll_interval
        Float(ENV.fetch("HIVE_BRAINSTORM_TMUX_SENTINEL_INTERVAL_SEC", SENTINEL_POLL_INTERVAL_SEC.to_s))
      end

      def reset_signal_files(task)
        cleanup_done(task)
        result = result_path(task)
        File.delete(result) if File.exist?(result)
      end

      def sweep_orphan_processes(task)
        pattern = "--add-dir[[:space:]]+#{Regexp.escape(task.folder)}"
        Open3.capture3("pkill", "-f", pattern)
      rescue Errno::ENOENT
        nil
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
