# frozen_string_literal: true

require "rbconfig"

module HiveBench
  # Private supervisor for the two host CLI judges in a packaged bench runtime.
  class JudgeProcess
    VERSION = 1
    GRACE = 5.0
    SETTLEMENT = 1.0
    WORKER = File.expand_path("judge_process_worker.rb", __dir__)
    CHUNK = 16 * 1024

    Status = Struct.new(:exitstatus, :termsig) do
      def success? = exitstatus == 0
    end
    Cleanup = Struct.new(:signals, :stdout_eof, :stderr_eof, :reaped, :descendants, :limitations, keyword_init: true)
    Result = Struct.new(:stdout, :stderr, :status, :timed_out, :error, :cleanup, keyword_init: true) do
      def failure_message(judge, timeout)
        reason = timed_out ? "timed out after #{timeout}s" : error
        details = [ reason, *cleanup.limitations ].compact
        "#{judge} judge #{details.join('; ')}" unless details.empty?
      end
    end

    def self.seconds(value)
      match = /\A(\+?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)([smhd]?)\z/.match(value.to_s)
      seconds = if value.is_a?(Numeric) && value.real?
        value.to_f
      elsif match
        match[1].to_f * { "" => 1, "s" => 1, "m" => 60, "h" => 3600, "d" => 86_400 }.fetch(match[2])
      end
      return seconds if seconds&.finite? && seconds >= 0

      raise ArgumentError, "invalid judge duration #{value.inspect} (expected nonnegative finite seconds or s/m/h/d)"
    end

    def self.capture(argv, stdin_data:, timeout:, env: {}, chdir: nil, grace: GRACE, settlement: SETTLEMENT)
      new(argv, stdin_data, seconds(timeout), seconds(grace), seconds(settlement)).run(env, chdir)
    end

    def initialize(argv, input, seconds, grace, settlement)
      @argv = argv
      @input = input
      @offset = 0
      @deadline = now + seconds unless seconds.zero?
      @grace = grace
      @settlement = settlement
      @pipes = []
      @outputs = {}
      @cleanup = Cleanup.new(signals: {}, stdout_eof: false, stderr_eof: false, reaped: false, limitations: [])
      @result = Result.new(stdout: +"".b, stderr: +"".b, timed_out: false, cleanup: @cleanup)
    end

    def run(env, chdir)
      # Acquisition, release and reap are indivisible with respect to Ruby
      # thread interrupts. Interruptible work always has a cleanup owner.
      Thread.handle_interrupt(Exception => :never) do
        begin
          start_worker(env, chdir)
          Thread.handle_interrupt(Exception => :immediate) { collect }
        rescue IOError, SystemCallError, ArgumentError => e
          @result.error ||= "judge supervision failed: #{e.message}"
        ensure
          begin
            finish if @pid
          ensure
            @pipes.each { |io| io.close unless io.closed? }
          end
        end
      end
      [ @result.stdout, @result.stderr ].each do |stream|
        stream.force_encoding(Encoding.default_external)
        stream.encode!(Encoding.default_internal) if Encoding.default_internal
      end
      @result
    end

    private

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def pipe
      IO.pipe.tap { |pair| @pipes.concat(pair) }
    end

    def start_worker(env, chdir)
      control, @commands = pipe
      @events, reports = pipe
      input, @stdin = pipe
      stdout, output = pipe
      stderr, error = pipe
      @outputs = { stdout => @result.stdout, stderr => @result.stderr }
      @stdout = stdout
      options = { 3 => control, 4 => reports, 5 => input, 6 => output, 7 => error,
                  in: File::NULL, out: File::NULL, err: File::NULL, close_others: true, pgroup: true }
      options[:chdir] = chdir if chdir
      @pid = Process.spawn(env, RbConfig.ruby, "--disable=gems,rubyopt", WORKER,
                           (@deadline || "none").to_s, @grace.to_s, @settlement.to_s, *@argv, options)
      [ control, reports, input, output, error ].each(&:close)
      @stdin.close if @input.empty?
    end

    def collect
      loop do
        if @deadline && now >= @deadline
          @result.timed_out = true
          break
        end
        if (@result.status || @launch_failed) && @outputs.empty?
          @complete = true
          break
        end

        readers = [ @events, *@outputs.keys ]
        writers = @stdin.closed? ? [] : [ @stdin ]
        delay = [ [ @deadline - now, 0 ].max, 60 ].min if @deadline
        ready = IO.select(readers, writers, nil, delay)
        next unless ready

        ready[0].each { |io| io == @events ? read_event : read_output(io) }
        write_input unless ready[1].empty?
      end
    end

    def read_event
      # Each record is one pipe write, smaller than PIPE_BUF and our read.
      # The worker waits for "start" between its only two reports.
      line = @events.read_nonblock(4096).chomp
      case line
      when "ready #{@pid}"
        if @signal_pid
          @signal_pid = nil
          raise IOError, "duplicate custody handshake"
        end

        @signal_pid = @pid
        command("start")
      when /\A(exit|signal|errno) (\d+)\z/
        raise IOError, "judge status without custody" unless @signal_pid

        kind, value = Regexp.last_match(1), Integer(Regexp.last_match(2))
        case kind
        when "exit" then @result.status = Status.new(value, nil)
        when "signal" then @result.status = Status.new(nil, value)
        when "errno"
          @launch_failed = true
          @result.error = "cannot launch #{@argv.first}: #{SystemCallError.new(value).message}"
        end
      else
        @signal_pid = nil
        raise IOError, "unverified custody handshake"
      end
    rescue EOFError
      raise IOError, "custody exited before judge capture completed"
    end

    def command(line)
      record = line + "\n"
      raise IOError, "could not deliver custody command" unless @commands.write_nonblock(record, exception: false) == record.bytesize
    end

    def write_input
      count = @stdin.write_nonblock(@input.byteslice(@offset, CHUNK), exception: false)
      return if count == :wait_writable

      @offset += count
      @stdin.close if @offset == @input.bytesize
    rescue Errno::EPIPE
      @stdin.close
    end

    def read_output(io)
      chunk = io.read_nonblock(CHUNK, exception: false)
      if chunk.nil?
        io == @stdout ? @cleanup.stdout_eof = true : @cleanup.stderr_eof = true
        @outputs.delete(io)
        io.close
      elsif chunk != :wait_readable
        @outputs.fetch(io) << chunk
      end
    end

    def finish
      @stdin.close unless @stdin.closed?
      if @complete
        @signal_pid = nil
        command("release")
      else
        force_cleanup
      end
    rescue IOError, SystemCallError => e
      @cleanup.limitations << "custody control failed: #{e.message}"
    ensure
      # This is the sole reaper. An unreaped direct child pins the numeric
      # identity even if the worker died. Never signal once reaping can begin.
      @signal_pid = nil
      @commands.close
      settle
    end

    def force_cleanup
      kill_at = now + @grace
      @cleanup.descendants = :unconfirmed
      @cleanup.limitations << "descendant termination unconfirmed"
      if @signal_pid
        begin
          command("cleanup #{kill_at}")
        rescue IOError, SystemCallError => e
          @cleanup.limitations << "custody control failed: #{e.message}"
        end
        signal_group("TERM")
      else
        @cleanup.limitations << "group signalling withheld: custody unverified"
        @commands.close
      end
      begin
        drain_until(kill_at)
      ensure
        # A local read failure still owes the group its grace and final signal.
        remaining = kill_at - now
        sleep(remaining) if remaining.positive?
        signal_group("KILL") if @signal_pid
      end
    end

    def signal_group(signal)
      Process.kill(signal, -@signal_pid)
      @cleanup.signals[signal] = :sent
    rescue SystemCallError => e
      @cleanup.signals[signal] = e.class.name
      @cleanup.limitations << "group #{signal}: #{e.message}"
    end

    def drain_until(deadline)
      while (left = deadline - now).positive?
        ready = IO.select(@outputs.keys, nil, nil, left)
        ready&.first&.each { |io| read_output(io) }
      end
    end

    def settle
      deadline = now + @settlement
      loop do
        unless @cleanup.reaped
          _, status = Process.waitpid2(@pid, Process::WNOHANG)
          @cleanup.reaped = true if status
          @cleanup.limitations << "custody release failed (#{status})" if @complete && status && !status.success?
        end
        break if @cleanup.reaped && @outputs.empty?
        break if now >= deadline

        drain_until([ now + 0.01, deadline ].min)
      end
      unless @cleanup.reaped
        @cleanup.limitations << "custody reap pending"
        Process.detach(@pid) # Reap only, after irrevocably surrendering signal authority.
      end
      @cleanup.limitations << "judge output pipes still open" unless @outputs.empty?
    rescue Errno::ECHILD
      @cleanup.limitations << "custody reap unavailable"
    end
  end
end
