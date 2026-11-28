# frozen_string_literal: true

module HiveBench
  # This direct child leads the group. Its private pipes carry only small,
  # atomic line records. Neither pipe is inherited by the actual judge.
  class JudgeProcessWorker
    def initialize(deadline, grace, settlement, argv)
      @grace = Float(grace)
      @backstop = Float(deadline) + @grace + Float(settlement) unless deadline == "none"
      @argv = argv
      @control, @events, *@streams = (3..7).map do |fd|
        IO.for_fd(fd).tap { |io| io.close_on_exec = true }
      end
    end

    def run
      # Signal zero as a target means this process's own group. Only use it
      # after verifying that we are the leader created by the harness.
      return 1 unless Process.getpgrp == Process.pid

      Signal.trap("TERM") { @term_at ||= now }
      report("ready #{Process.pid}")
      loop do
        check_cleanup
        poll_judge if @judge
        readers = @control.closed? ? [] : [ @control ]
        next unless IO.select(readers, nil, nil, wait_interval)

        commands = @control.read_nonblock(4096, exception: false)
        if commands.nil?
          @control.close
          abandon
        elsif commands != :wait_readable
          commands.each_line do |line|
            case line.chomp
            when "start"
              launch unless @started || @kill_at
            when "release"
              return 0 if @started && !@judge && !@kill_at && !@term_at
            when /\Acleanup (\S+)\z/
              schedule_kill(Float(Regexp.last_match(1)))
            end
          end
        end
      end
    end

    private

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def schedule_kill(at)
      @kill_at = [ @kill_at, at ].compact.min
    end

    def abandon
      schedule_kill(now + @grace)
      return if @sent_term

      @sent_term = true
      Process.kill("TERM", 0)
    end

    def check_cleanup
      schedule_kill(@term_at + @grace) if @term_at
      if @backstop && now >= @backstop
        schedule_kill(@backstop + @grace)
        @backstop = nil
        abandon
      end
      Process.kill("KILL", 0) if @kill_at && now >= @kill_at
    end

    def wait_interval
      # Poll for judge exit and trapped TERM even if no control record arrives.
      [ 0.025, *[ @kill_at, @backstop ].compact.map { |at| [ at - now, 0 ].max } ].min
    end

    def launch
      @started = true
      bin, *args = @argv
      @judge = Process.spawn([ bin, bin ], *args, in: @streams[0], out: @streams[1],
                             err: @streams[2], close_others: true)
    rescue SystemCallError => e
      report("errno #{e.errno}")
    ensure
      @streams.each(&:close)
    end

    def poll_judge
      _, status = Process.waitpid2(@judge, Process::WNOHANG)
      return unless status

      @judge = nil
      report(status.signaled? ? "signal #{status.termsig}" : "exit #{status.exitstatus}")
    end

    def report(line)
      message = line + "\n"
      abandon unless @events.write_nonblock(message, exception: false) == message.bytesize
    rescue Errno::EPIPE
      abandon
    end
  end
end

if $PROGRAM_NAME == __FILE__
  deadline, grace, settlement, *argv = ARGV
  exit HiveBench::JudgeProcessWorker.new(deadline, grace, settlement, argv).run
end
