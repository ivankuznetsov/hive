require "rbconfig"
require "json"
require "shellwords"
require "fileutils"
require_relative "artifact_paths"
require_relative "asciinema_driver"
require_relative "paths"
require_relative "sandbox_env"
require_relative "string_expander"
require_relative "tmux_driver"

module Hive
  module E2E
    # Wraps the lazy start/stop of a tmux session for tui_* steps and the
    # asciinema recorder that piggybacks on it. Lives separately from the
    # step dispatcher so the dispatcher stays a small switch over step kinds.
    class TmuxSessionLifecycle
      MANAGED_SUBPROCESS_LOG_NAME = "hive-tui-subprocess-pids.jsonl"
      PROCESS_TERM_GRACE_SECONDS = 1.0

      attr_reader :tmux, :asciinema, :tui_log_dir

      def initialize(scenario:, sandbox_dir:, run_home:, run_id:, scenario_dir:, context:)
        @scenario = scenario
        @sandbox_dir = sandbox_dir
        @run_home = run_home
        @run_id = run_id
        @scenario_dir = scenario_dir
        @context = context
        @tui_log_dir = File.join(@scenario_dir, ArtifactPaths::LIVE_TUI_LOG_DIRNAME)
        @tmux = nil
        @asciinema = nil
      end

      def start_session
        return @tmux if @tmux
        raise "tmux is required for TUI e2e scenarios" unless TmuxDriver.available?

        SandboxEnv.with(@sandbox_dir, @run_home) do |base_env|
          env = session_env(base_env)
          command = Shellwords.join([ RbConfig.ruby, "-I#{Paths.lib_dir}", Paths.hive_bin, "tui" ])
          @tmux = TmuxDriver.new(run_id: @run_id, session_name: "scenario-#{@scenario.name}",
                                 command: command, env: env,
                                 subprocess_log_path: File.join(@tui_log_dir, "hive-tui-subprocess.log"))
          @tmux.start
        end
        start_asciinema_if_available
        @tmux
      end

      # Best-effort capture of the current pane contents. Returns nil if
      # there is no live tmux session.
      def snapshot_pane
        return nil unless @tmux

        @tmux.capture_pane
      rescue StandardError
        nil
      end

      # Capture the diagnostics that require a live server before cleanup.
      # Callers can then terminate tmux and take stable filesystem snapshots
      # without losing the final pane or keystroke transcript.
      def failure_evidence
        return {} unless @tmux

        pane = snapshot_pane || "(capture-pane failed before tmux shutdown)\n"
        { tmux_keystrokes: @tmux.keystrokes, pane_after: pane }
      rescue StandardError => e
        { tmux_keystrokes: [], pane_after: "(tmux evidence failed: #{e.class}: #{e.message})\n" }
      end

      def stop_asciinema(delete:)
        return unless @asciinema

        @asciinema.stop
        if delete
          FileUtils.rm_f(@asciinema.cast_path)
        else
          FileUtils.mkdir_p(@scenario_dir)
          File.write(File.join(@scenario_dir, "cast-status.txt"), "#{@asciinema.integrity_status}\n")
        end
      ensure
        @asciinema = nil
      end

      def cleanup
        error = nil
        begin
          stop_managed_subprocesses
        rescue StandardError => e
          error = e
        ensure
          @tmux&.cleanup
        end
        raise error if error
      end

      def discard_preserved_cast
        FileUtils.rm_f(File.join(@scenario_dir, "cast.json"))
        FileUtils.rm_f(File.join(@scenario_dir, "cast-status.txt"))
      end

      private

      def stop_managed_subprocesses
        active_managed_process_groups.each { |pid| stop_process_group(pid) }
      end

      def active_managed_process_groups
        path = File.join(@tui_log_dir, MANAGED_SUBPROCESS_LOG_NAME)
        active = {}
        flags = File::RDONLY
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(path, flags) do |file|
          raise "managed TUI subprocess log must be a regular file" unless file.stat.file?

          file.flock(File::LOCK_SH)
          file.each_line do |line|
            record = JSON.parse(line)
            id = record.fetch("id").to_s
            pid = Integer(record.fetch("pid"))
            raise "invalid managed TUI subprocess pid #{pid}" unless pid.positive?

            case record.fetch("event")
            when "start" then active[id] = pid
            when "finish" then active.delete(id)
            else raise "invalid managed TUI subprocess event #{record.fetch('event').inspect}"
            end
          end
        end
        active.values.uniq
      rescue Errno::ENOENT
        []
      end

      def stop_process_group(pid)
        return unless process_group_alive?(pid)

        pgid = Process.getpgid(pid)
        raise "managed TUI subprocess #{pid} is not its process-group leader" unless pgid == pid

        Process.kill("TERM", -pid)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + PROCESS_TERM_GRACE_SECONDS
        while process_group_alive?(pid) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          sleep 0.02
        end
        Process.kill("KILL", -pid) if process_group_alive?(pid)
      rescue Errno::ESRCH
        nil
      end

      def process_group_alive?(pid)
        Process.kill(0, -pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      # HIVE_TUI_LOG_DIR is reserved: the e2e driver reads BEGIN/END/ERRNO
      # markers from this directory's log to wait for subprocess completion
      # (TmuxDriver#wait_for_subprocess_log). A scenario `tui_env` override
      # would desynchronize the writer (TUI subprocess) from the reader
      # (driver), making subprocess-bound waits silently never observe
      # markers. Apply scenario-supplied env first, then pin our reserved
      # key last so user input cannot clobber it. A scenario that explicitly
      # sets HIVE_TUI_LOG_DIR is rejected with a clear error.
      RESERVED_TUI_ENV_KEYS = %w[HIVE_TUI_LOG_DIR].freeze

      def session_env(base_env = SandboxEnv.repro_env(@sandbox_dir, @run_home))
        scenario_env = StringExpander.expand(@scenario.setup["tui_env"] || {}, expander_context)
        clobbered = scenario_env.keys.map(&:to_s) & RESERVED_TUI_ENV_KEYS
        unless clobbered.empty?
          raise ArgumentError,
                "scenario `tui_env` cannot override reserved e2e keys: #{clobbered.inspect} " \
                "(these are owned by the driver — see tmux_session_lifecycle.rb)"
        end

        env = SandboxEnv.merge(base_env, scenario_env)
        env["HIVE_TUI_LOG_DIR"] = @tui_log_dir
        env
      end

      def expander_context
        @context.expander_context(slug_resolver: -> { @context.slug.to_s })
      end

      def start_asciinema_if_available
        return if @asciinema
        return unless AsciinemaDriver.available?

        @asciinema = AsciinemaDriver.new(
          socket_name: @tmux.socket_name,
          session_name: @tmux.session_name,
          cast_path: File.join(@scenario_dir, "cast.json")
        )
        @asciinema.start
      rescue AsciinemaDriver::Unavailable
        @asciinema = nil
      end
    end
  end
end
