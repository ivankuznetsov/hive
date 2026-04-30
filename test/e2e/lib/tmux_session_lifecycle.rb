require "rbconfig"
require "shellwords"
require_relative "asciinema_driver"
require_relative "paths"
require_relative "sandbox_env"
require_relative "tmux_driver"

module Hive
  module E2E
    # Wraps the lazy start/stop of a tmux session for tui_* steps and the
    # asciinema recorder that piggybacks on it. Lives separately from the
    # step dispatcher so the dispatcher stays a small switch over step kinds.
    class TmuxSessionLifecycle
      attr_reader :tmux, :asciinema

      def initialize(scenario:, sandbox_dir:, run_home:, run_id:, scenario_dir:)
        @scenario = scenario
        @sandbox_dir = sandbox_dir
        @run_home = run_home
        @run_id = run_id
        @scenario_dir = scenario_dir
        @tmux = nil
        @asciinema = nil
      end

      def start_session
        return @tmux if @tmux
        raise "tmux is required for TUI e2e scenarios" unless TmuxDriver.available?

        env = SandboxEnv.repro_env(@sandbox_dir, @run_home)
        env.merge!(@scenario.setup["tui_env"] || {})
        command = Shellwords.join([ RbConfig.ruby, "-I#{Paths.lib_dir}", Paths.hive_bin, "tui" ])
        @tmux = TmuxDriver.new(run_id: @run_id, session_name: "scenario-#{@scenario.name}",
                               command: command, env: env)
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
