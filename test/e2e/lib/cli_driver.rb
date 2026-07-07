require "English"
require "open3"
require "rbconfig"
require "shellwords"
require "time"
require_relative "paths"
require_relative "sandbox_env"

module Hive
  module E2E
    class CliDriver
      Result = Data.define(:stdout, :stderr, :exit_code, :duration_seconds, :timed_out)
      READER_JOIN_GRACE_SECONDS = 0.1

      class ExitMismatchError < StandardError
        attr_reader :expected, :actual, :stdout, :stderr

        def initialize(expected:, actual:, stdout:, stderr:)
          @expected = expected
          @actual = actual
          @stdout = stdout
          @stderr = stderr
          super("expected exit #{expected}, got #{actual}")
        end
      end

      class StderrMismatchError < StandardError
        attr_reader :pattern, :stdout, :stderr

        def initialize(pattern:, stdout:, stderr:)
          @pattern = pattern
          @stdout = stdout
          @stderr = stderr
          super("stderr did not match #{pattern.inspect}")
        end
      end

      def initialize(sandbox_dir, run_home, fake_claude_path: Paths.fake_claude)
        @sandbox_dir = sandbox_dir
        @run_home = run_home
        @fake_claude_path = fake_claude_path
      end

      def call(args, expect_exit: 0, expect_stderr_match: nil, cwd: @sandbox_dir, timeout: 30.0, env_overrides: {})
        args = args.map(&:to_s)
        started = monotonic_time
        result = nil
        SandboxEnv.with(@sandbox_dir, @run_home, @fake_claude_path) do |env|
          result = spawn_and_capture(env.merge(SandboxEnv.stringify_env(env_overrides)), args, cwd, timeout)
        end
        duration = monotonic_time - started
        result = Result.new(stdout: result.stdout, stderr: result.stderr, exit_code: result.exit_code,
                            duration_seconds: duration.round(3), timed_out: result.timed_out)
        validate_exit!(result, expect_exit) unless expect_exit.nil?
        validate_stderr!(result, expect_stderr_match) if expect_stderr_match
        result
      end

      def command(args)
        [ RbConfig.ruby, "-I#{Paths.lib_dir}", Paths.hive_bin, *args.map(&:to_s) ]
      end

      private

      ProcessResult = Data.define(:stdout, :stderr, :exit_code, :timed_out)

      def spawn_and_capture(env, args, cwd, timeout)
        deadline = monotonic_time + timeout
        stdout = +""
        stderr = +""
        timed_out = false
        status = nil

        Open3.popen3(env, *command(args), chdir: cwd, pgroup: true) do |stdin, out, err, wait_thr|
          stdin.close
          out_reader = Thread.new { read_stream(out) }
          err_reader = Thread.new { read_stream(err) }
          unless wait_thr.join(timeout)
            timed_out = true
            terminate(wait_thr.pid)
          end
          status = wait_thr.value
          readers = [ out_reader, err_reader ]
          reader_deadline = timed_out ? monotonic_time + READER_JOIN_GRACE_SECONDS : deadline
          unless readers_finished?(readers, reader_deadline)
            timed_out = true
            terminate(wait_thr.pid)
            readers_finished?(readers, monotonic_time + READER_JOIN_GRACE_SECONDS)
          end
          status = nil if timed_out
          stdout = safe_thread_value(out_reader)
          stderr = safe_thread_value(err_reader)
        end

        ProcessResult.new(stdout: stdout, stderr: stderr, exit_code: status&.exitstatus, timed_out: timed_out)
      end

      def readers_finished?(readers, deadline)
        readers.all? do |reader|
          next true unless reader.alive?

          remaining = deadline - monotonic_time
          remaining.positive? && reader.join(remaining)
        end
      end

      def read_stream(stream)
        stream.read
      rescue IOError
        ""
      end

      def safe_thread_value(thread)
        thread.kill if thread.alive?
        thread.value.to_s
      rescue StandardError
        ""
      end

      # Signal the entire process group (negative pid) so any children spawned by the
      # CLI under test (editor shims, sub-shells, etc.) are torn down too. Open3's
      # pgroup: true makes the child pid the process-group id, so this still works
      # after the direct child has exited and only descendants remain.
      def terminate(pid)
        Process.kill("TERM", -pid)
        sleep 0.5
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH
        nil
      end

      def validate_exit!(result, expected)
        return if result.exit_code == expected

        raise ExitMismatchError.new(expected: expected, actual: result.exit_code, stdout: result.stdout, stderr: result.stderr)
      end

      def validate_stderr!(result, pattern)
        regex = pattern.is_a?(Regexp) ? pattern : Regexp.new(pattern.to_s)
        return if result.stderr.match?(regex)

        raise StderrMismatchError.new(pattern: regex, stdout: result.stdout, stderr: result.stderr)
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
