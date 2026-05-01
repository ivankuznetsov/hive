require "rbconfig"
require "shellwords"
require "fileutils"
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
      attr_reader :tmux, :asciinema, :tui_log_dir

      def initialize(scenario:, sandbox_dir:, run_home:, run_id:, scenario_dir:, context:)
        @scenario = scenario
        @sandbox_dir = sandbox_dir
        @run_home = run_home
        @run_id = run_id
        @scenario_dir = scenario_dir
        @context = context
        @tui_log_dir = File.join(@scenario_dir, "tui-subprocess-live")
        @tmux = nil
        @asciinema = nil
      end

      def start_session
        return @tmux if @tmux
        raise "tmux is required for TUI e2e scenarios" unless TmuxDriver.available?

        env = session_env
        command = Shellwords.join([ RbConfig.ruby, "-I#{Paths.lib_dir}", Paths.hive_bin, "tui" ])
        @tmux = TmuxDriver.new(run_id: @run_id, session_name: "scenario-#{@scenario.name}",
                               command: command, env: env,
                               subprocess_log_path: File.join(@tui_log_dir, "hive-tui-subprocess.log"))
        @tmux.start
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
        @tmux&.cleanup
      end

      private

      # HIVE_TUI_LOG_DIR is reserved: the e2e driver reads BEGIN/END/ERRNO
      # markers from this directory's log to wait for subprocess completion
      # (TmuxDriver#wait_for_subprocess_log). A scenario `tui_env` override
      # would desynchronize the writer (TUI subprocess) from the reader
      # (driver), making subprocess-bound waits silently never observe
      # markers. Apply scenario-supplied env first, then pin our reserved
      # key last so user input cannot clobber it. A scenario that explicitly
      # sets HIVE_TUI_LOG_DIR is rejected with a clear error.
      RESERVED_TUI_ENV_KEYS = %w[HIVE_TUI_LOG_DIR].freeze

      def session_env
        scenario_env = StringExpander.expand(@scenario.setup["tui_env"] || {}, expander_context)
        clobbered = scenario_env.keys.map(&:to_s) & RESERVED_TUI_ENV_KEYS
        unless clobbered.empty?
          raise ArgumentError,
                "scenario `tui_env` cannot override reserved e2e keys: #{clobbered.inspect} " \
                "(these are owned by the driver — see tmux_session_lifecycle.rb)"
        end

        env = SandboxEnv.repro_env(@sandbox_dir, @run_home)
        env.merge!(scenario_env)
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
