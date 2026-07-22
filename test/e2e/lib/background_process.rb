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
        @pgid = nil
        @reaped = false
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
          @pid = Process.spawn(SandboxEnv.merge(env, @env_overrides), *command, **spawn_opts)
        end
        @pgid = @pid
        @reaped = false
        self
      end

      def alive?
        return false unless @pid
        return false if child_reaped?

        Process.kill(0, @pid)
        true
      rescue Errno::ESRCH, Errno::EPERM
        # ESRCH: gone. EPERM: the pid was recycled to another user's process,
        # so OUR process is gone either way.
        false
      end

      # TERM the whole process group, then KILL after a short grace if the
      # original child has not exited. The grace is a kill-escalation delay,
      # not a condition wait — scenarios wait on file/log conditions, never on
      # sleep.
      #
      # `pgroup: true` at spawn makes the child its own group leader, so its
      # pgid == @pid. Do not asynchronously detach/reap the child: while it is
      # unreaped, the pid/pgid cannot be reused for an unrelated process group.
      def stop(grace: 0.5)
        return unless @pid

        pgid = @pgid || @pid
        unless child_reaped?
          signal_group("TERM", pgid)
          wait_until_reaped(grace)
        end
        unless child_reaped?
          signal_group("KILL", pgid)
          wait_until_reaped(0.2)
        end
      ensure
        detach_unreaped_child
        @pid = nil
        @pgid = nil
        @reaped = false
      end

      private

      def child_reaped?
        return true if @reaped
        return true unless @pid

        @reaped = !Process.waitpid(@pid, Process::WNOHANG).nil?
      rescue Errno::ECHILD
        @reaped = true
      end

      def wait_until_reaped(seconds)
        deadline = Time.now + seconds
        sleep 0.05 until child_reaped? || Time.now >= deadline
        child_reaped?
      end

      def signal_group(signal, pgid)
        Process.kill(signal, -pgid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      def detach_unreaped_child
        return unless @pid && !@reaped

        Process.detach(@pid)
      rescue Errno::ECHILD
        nil
      end
    end
  end
end
