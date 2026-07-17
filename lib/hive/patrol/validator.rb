require "open3"

module Hive
  module Patrol
    class Validator
      COMMAND_NAMES = %w[docs format lint public_contract typecheck test].freeze
      DEFAULT_TIMEOUT_SEC = 600
      DEFAULT_MAX_OUTPUT_BYTES = 64 * 1024
      TERM_GRACE_SEC = 0.5

      CommandResult = Struct.new(
        :name, :command, :exit_code, :signal, :stdout, :stderr, :timed_out,
        :output_truncated,
        keyword_init: true
      ) do
        def passed?
          timed_out != true && signal.nil? && exit_code == 0
        end

        def to_h
          {
            "name" => name,
            "command" => command,
            "exit_code" => exit_code,
            "signal" => signal,
            "stdout" => tail(stdout),
            "stderr" => tail(stderr),
            "timed_out" => timed_out == true,
            "output_truncated" => output_truncated == true
          }
        end

        # Keep the last 4000 chars for the audit trail. `str[-4000, 4000]`
        # returns nil when the string is shorter than 4000 chars (negative
        # start out of range), collapsing every short lint/test output to
        # "". A last-N slice preserves short strings intact.
        def tail(value)
          str = value.to_s
          str[-4000..] || str
        end
      end

      def initialize(commands = nil, timeout_sec: DEFAULT_TIMEOUT_SEC,
                     max_output_bytes: DEFAULT_MAX_OUTPUT_BYTES, **command_keywords)
        @commands = (commands || {}).merge(command_keywords)
        @timeout_sec = timeout_sec.to_f
        @max_output_bytes = max_output_bytes.to_i
      end

      def configured?(names: nil)
        active_commands(names: names).any?
      end

      def validate(worktree_path, names: nil)
        active = active_commands(names: names)
        return { "passed" => false, "reason" => "no_validation_commands", "commands" => [] } if active.empty?

        results = active.map { |name, command| run_command(name, command, worktree_path) }
        {
          "passed" => results.all?(&:passed?),
          "commands" => results.map(&:to_h)
        }
      end

      private

      def active_commands(names: nil)
        selected = names && Array(names).map(&:to_s)
        COMMAND_NAMES.filter_map do |name|
          next if selected && !selected.include?(name)

          command = @commands[name]
          [ name, command ] if command.is_a?(String) && !command.strip.empty?
        end
      end

      def run_command(name, command, worktree_path)
        stdin, stdout, stderr, waiter = Open3.popen3(
          "bash", "-lc", command, chdir: worktree_path, pgroup: true
        )
        stdin.close
        out_reader = Thread.new { bounded_read(stdout) }
        err_reader = Thread.new { bounded_read(stderr) }
        timed_out = !waiter.join(@timeout_sec)
        terminate(waiter) if timed_out
        out, out_truncated = reader_value(out_reader, stdout)
        err, err_truncated = reader_value(err_reader, stderr)
        process_status = waiter.value
        signal = !timed_out && process_status.signaled? ? process_status.termsig : nil
        exit_code = if timed_out
                      124
        elsif process_status.exited?
                      process_status.exitstatus
        else
                      128 + signal.to_i
        end
        CommandResult.new(
          name: name, command: command, exit_code: exit_code, signal: signal,
          stdout: out, stderr: err, timed_out: timed_out,
          output_truncated: out_truncated || err_truncated
        )
      rescue SystemCallError => e
        CommandResult.new(
          name: name, command: command, exit_code: 127, signal: nil, stdout: "", stderr: e.message,
          timed_out: false, output_truncated: false
        )
      ensure
        [ stdin, stdout, stderr ].compact.each { |io| io.close unless io.closed? }
      end

      def bounded_read(io)
        buffer = +"".b
        truncated = false
        loop do
          chunk = io.readpartial(4096)
          buffer << chunk
          next unless buffer.bytesize > @max_output_bytes

          truncated = true
          buffer = buffer.byteslice(-@max_output_bytes, @max_output_bytes) || +"".b
        end
      rescue EOFError, IOError
        buffer.force_encoding(Encoding::UTF_8)
        [ buffer.scrub("?"), truncated ]
      end

      def reader_value(reader, io)
        unless reader.join(1)
          io.close unless io.closed?
          reader.join(0.1)
        end
        if reader.alive?
          reader.kill
          return [ "", true ]
        end
        reader.value
      rescue IOError
        [ "", false ]
      end

      def terminate(waiter)
        Process.kill("TERM", -waiter.pid)
        return if waiter.join(TERM_GRACE_SEC)

        Process.kill("KILL", -waiter.pid)
        waiter.join(TERM_GRACE_SEC)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
  end
end
