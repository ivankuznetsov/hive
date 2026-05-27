require "rbconfig"
require "fileutils"
require_relative "paths"
require_relative "sandbox_env"

module Hive
  module E2E
    # A long-lived `hive` subprocess (e.g. `daemon start`, `bot start`) the
    # harness starts and later stops. Unlike CliDriver (blocking, kill-on-
    # timeout), this returns immediately and runs until #stop. The daemon/bot
    # run ATTACHED (no `--detach`) so this owns the process group and can TERM
    # the whole tree on teardown. stdout/stderr are captured to a log file for
    # forensics; the process's own JSON-line logs go to its configured log_file.
    class BackgroundProcess
      attr_reader :pid, :log_path

      def initialize(args:, sandbox_dir:, run_home:, env: {}, log_path: nil, fake_claude_path: Paths.fake_claude)
        @args = args.map(&:to_s)
        @sandbox_dir = sandbox_dir
        @run_home = run_home
        @env_overrides = env
        @log_path = log_path
        @fake_claude_path = fake_claude_path
      end

      def start
        command = [ RbConfig.ruby, "-I#{Paths.lib_dir}", Paths.hive_bin, *@args ]
        spawn_opts = { chdir: @sandbox_dir, pgroup: true }
        if @log_path
          FileUtils.mkdir_p(File.dirname(@log_path))
          spawn_opts[:out] = @log_path
          spawn_opts[:err] = %i[child out]
        end
        # SandboxEnv.with strips leaky bundler/version-manager vars and yields
        # the sandbox env; the child inherits that cleaned env at spawn time.
        SandboxEnv.with(@sandbox_dir, @run_home, @fake_claude_path) do |env|
          @pid = Process.spawn(env.merge(stringify(@env_overrides)), *command, **spawn_opts)
        end
        Process.detach(@pid) # reap if it exits on its own; #stop still signals it
        self
      end

      def alive?
        return false unless @pid

        Process.kill(0, @pid)
        true
      rescue Errno::ESRCH
        false
      end

      # TERM the whole process group, then KILL after a short grace (mirrors
      # CliDriver#terminate). The grace is a kill-escalation delay, not a
      # condition wait — scenarios wait on file/log conditions, never on sleep.
      def stop(grace: 0.5)
        return unless @pid

        pgid = Process.getpgid(@pid)
        Process.kill("TERM", -pgid)
        sleep grace
        Process.kill("KILL", -pgid)
      rescue Errno::ESRCH
        nil
      ensure
        @pid = nil
      end

      private

      def stringify(env)
        env.each_with_object({}) { |(key, value), out| out[key.to_s] = value.nil? ? nil : value.to_s }
      end
    end
  end
end
