require "open3"

require "hive/output_pulse"

module Hive
  module Patrol
    class Validator
      COMMAND_NAMES = %w[docs format lint public_contract typecheck test].freeze
      DEFAULT_TIMEOUT_SEC = 600
      DEFAULT_MAX_OUTPUT_BYTES = 64 * 1024
      TERM_GRACE_SEC = 0.5
      # Smallest wait slice while polling the child for completion, so tiny
      # test timeouts stay accurate without busy-waiting in production.
      WAIT_SLICE_SEC = 0.05

      CommandResult = Struct.new(
        :name, :command, :exit_code, :signal, :stdout, :stderr, :timed_out,
        :timeout_reason, :output_truncated,
        :started_at, :finished_at, :duration_ms, :provenance,
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
            "timeout_reason" => timeout_reason,
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

      def self.monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def self.configured_names(commands)
        commands ||= {}
        COMMAND_NAMES.select do |name|
          command = commands[name] || commands[name.to_sym]
          command.is_a?(String) && !command.strip.empty?
        end
      end

      # `timeout_sec` is the wall-clock backstop: it bounds total runtime (and
      # therefore cost) no matter what the child prints. `idle_timeout_sec`
      # is the wedge detector: when set, a child that produces no stdout or
      # stderr for that long is killed immediately instead of holding the
      # patrol cycle until the wall-clock cap. Progressing suites print as
      # they run, so a generous wall clock plus a short idle window fails
      # hangs fast without punishing slow-but-live validation. Nil or
      # non-positive disables the idle deadline (the historical behavior).
      def initialize(commands = nil, timeout_sec: DEFAULT_TIMEOUT_SEC,
                     idle_timeout_sec: nil,
                     max_output_bytes: DEFAULT_MAX_OUTPUT_BYTES, **command_keywords)
        @commands = (commands || {}).merge(command_keywords)
        @timeout_sec = timeout_sec.to_f
        idle = idle_timeout_sec.to_f
        @idle_timeout_sec = idle.positive? ? idle : nil
        @max_output_bytes = max_output_bytes.to_i
      end

      def configured?(names: nil)
        active_commands(names: names).any?
      end

      def configured_names
        self.class.configured_names(@commands)
      end

      def command_for(name)
        key = name.to_s
        return unless configured_names.include?(key)

        @commands[key] || @commands[key.to_sym]
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

      # Run an explicit controller/agent-selected command set. Callers must
      # supply this structured list deliberately; discovery reproduction prose
      # is never accepted or interpreted by this API.
      def validate_selected(worktree_path, selections)
        rows = Array(selections).map do |selection|
          unless selection.is_a?(Hash) && selection.keys.map(&:to_s).sort == %w[command identity provenance]
            raise ArgumentError, "selected validation command has an invalid field set"
          end
          identity = selection["identity"] || selection[:identity]
          command = selection["command"] || selection[:command]
          provenance = selection["provenance"] || selection[:provenance]
          unless identity.is_a?(String) && !identity.empty? && command.is_a?(String) && !command.empty? &&
                 %w[controller agent].include?(provenance.to_s)
            raise ArgumentError, "selected validation command is invalid"
          end
          run_command(identity, command, worktree_path, provenance: provenance.to_s)
        end
        { "passed" => !rows.empty? && rows.all?(&:passed?), "commands" => rows }
      end

      private

      def active_commands(names: nil)
        selected = names && Array(names).map(&:to_s)
        configured_names.filter_map do |name|
          next if selected && !selected.include?(name)

          [ name, command_for(name) ]
        end
      end

      def run_command(name, command, worktree_path, provenance: "controller")
        started_at = Time.now.utc
        started_monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        stdin, stdout, stderr, waiter = Open3.popen3(
          "bash", "-lc", command, chdir: worktree_path, pgroup: true
        )
        stdin.close
        pulse = Hive::OutputPulse.new
        out_reader = Thread.new { bounded_read(stdout, pulse) }
        err_reader = Thread.new { bounded_read(stderr, pulse) }
        timeout_reason = await_completion(waiter, pulse)
        timed_out = !timeout_reason.nil?
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
          timeout_reason: timeout_reason,
          output_truncated: out_truncated || err_truncated,
          started_at: started_at, finished_at: Time.now.utc,
          duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_monotonic) * 1000).round,
          provenance: provenance
        )
      rescue SystemCallError => e
        CommandResult.new(
          name: name, command: command, exit_code: 127, signal: nil, stdout: "", stderr: e.message,
          timed_out: false, timeout_reason: nil, output_truncated: false,
          started_at: started_at || Time.now.utc, finished_at: Time.now.utc,
          duration_ms: started_monotonic ? ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_monotonic) * 1000).round : 0,
          provenance: provenance
        )
      ensure
        [ stdin, stdout, stderr ].compact.each { |io| io.close unless io.closed? }
      end

      # Waits for the child to exit. Returns nil on completion, or the name
      # of the deadline that expired first: "wall_clock" (total runtime cap)
      # or "idle_output" (no stdout/stderr for @idle_timeout_sec).
      def await_completion(waiter, pulse)
        deadline = self.class.monotonic + @timeout_sec
        loop do
          now = self.class.monotonic
          return "wall_clock" if now >= deadline

          idle_remaining = nil
          if @idle_timeout_sec
            idle_deadline = pulse.last + @idle_timeout_sec
            return "idle_output" if now >= idle_deadline

            idle_remaining = idle_deadline - now
          end
          wait = [ deadline - now, idle_remaining ].compact.min.clamp(WAIT_SLICE_SEC, 1.0)
          return nil if waiter.join(wait)
        end
      end

      def bounded_read(io, pulse = nil)
        buffer = +"".b
        truncated = false
        loop do
          chunk = io.readpartial(4096)
          pulse&.touch
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
