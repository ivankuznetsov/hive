module HiveLiveAgentProof
  module OpenClawCreatorProof
    class StreamCapture
      attr_reader :retained, :bytes, :findings

      def initialize(limit:, exact_secrets:)
        @limit = limit
        @exact_secrets = exact_secrets.reject(&:empty?).map { |secret| secret.to_s.b }
        @scan_window = [ 512, *@exact_secrets.map(&:bytesize) ].max
        @retained = +"".b
        @bytes = 0
        @digest = Digest::SHA256.new
        @tail = +"".b
        @findings = Set.new
      end

      def update(chunk)
        raw = chunk.to_s.b
        @bytes += raw.bytesize
        @digest.update(raw)
        remaining = @limit - @retained.bytesize
        @retained << raw.byteslice(0, remaining) if remaining.positive?
        scan = @tail + raw
        utf8 = scan.dup.force_encoding(Encoding::UTF_8).scrub
        SECRET_PATTERNS.each do |pattern|
          @findings << "pattern:#{pattern.source}" if pattern.match?(utf8)
        end
        @exact_secrets.each_with_index do |secret, index|
          @findings << "exact-secret:#{index}" if scan.include?(secret)
        end
        @tail = scan.byteslice(-@scan_window, @scan_window).to_s.b
      end

      def record
        {
          "sha256" => @digest.hexdigest,
          "bytes" => @bytes,
          "retained_bytes" => @retained.bytesize,
          "truncated" => @bytes > @retained.bytesize
        }
      end
    end

    class ProcessRunner
      READ_CHUNK = 16 * 1024
      POST_KILL_GRACE = 2.0

      def initialize(timeout:, term_grace:, output_limit:, exact_secrets:)
        @timeout = Float(timeout)
        @term_grace = Float(term_grace)
        @output_limit = Integer(output_limit)
        @exact_secrets = exact_secrets.map(&:to_s)
        raise ArgumentError, "timeout must be positive" unless @timeout.positive?
        raise ArgumentError, "term_grace must be positive" unless @term_grace.positive?
        raise ArgumentError, "output_limit must be positive" unless @output_limit.positive?
      end

      def call(environment:, argv:, chdir:, stdin_data: nil, timeout: @timeout)
        started = monotonic_now
        stdout_capture = StreamCapture.new(limit: @output_limit, exact_secrets: @exact_secrets)
        stderr_capture = StreamCapture.new(limit: @output_limit, exact_secrets: @exact_secrets)
        status = nil
        teardown = base_teardown
        timed_out = false

        Open3.popen3(
          environment, *argv,
          chdir: chdir, pgroup: true, unsetenv_others: true
        ) do |stdin, stdout, stderr, waiter|
          writer = start_writer(stdin, stdin_data)
          stdout_reader = start_reader(stdout, stdout_capture)
          stderr_reader = start_reader(stderr, stderr_capture)

          status = wait_for(waiter, timeout)
          unless status
            timed_out = true
            teardown["term_sent"] = signal_group(waiter.pid, "TERM")
            status = wait_for(waiter, @term_grace)
            unless status
              teardown["kill_sent"] = signal_group(waiter.pid, "KILL")
              status = wait_for(waiter, POST_KILL_GRACE)
            end
          end

          if status && live_group?(waiter.pid)
            teardown["term_sent"] = signal_group(waiter.pid, "TERM") ||
                                    teardown["term_sent"]
            unless wait_until_group_gone(waiter.pid, @term_grace)
              teardown["kill_sent"] = signal_group(waiter.pid, "KILL") ||
                                      teardown["kill_sent"]
              wait_until_group_gone(waiter.pid, POST_KILL_GRACE)
            end
          end

          writer.join(@term_grace)
          if writer.alive?
            stdin.close unless stdin.closed?
            writer.join(@term_grace)
          end
          stdin.close unless stdin.closed?
          close_and_join_reader(stdout_reader, stdout)
          close_and_join_reader(stderr_reader, stderr)

          teardown["reaped"] = !status.nil?
          teardown["readers"] =
            stdout_reader.alive? || stderr_reader.alive? ? "incomplete" : "complete"
          teardown["writer"] = writer.alive? ? "incomplete" : "complete"
          teardown["descendants"] = live_group?(waiter.pid) ? "remaining" : "none"
          teardown["status"] =
            if teardown["reaped"] && teardown["readers"] == "complete" &&
               teardown["writer"] == "complete" && teardown["descendants"] == "none"
              "passed"
            else
              "failed"
            end
        end

        {
          "status" => status,
          "stdout" => stdout_capture.retained,
          "stderr" => stderr_capture.retained,
          "secret_findings" =>
            (stdout_capture.findings | stderr_capture.findings).to_a.sort,
          "record" => {
            "executable" => File.basename(argv.fetch(0).to_s),
            "argv_sha256" => Digest::SHA256.hexdigest(JSON.generate(argv.map(&:to_s))),
            "exit_status" => status&.exitstatus,
            "signal" => status&.termsig,
            "timed_out" => timed_out,
            "duration_ms" => ((monotonic_now - started) * 1_000).round,
            "stdout" => stdout_capture.record,
            "stderr" => stderr_capture.record,
            "teardown" => teardown
          }
        }
      rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR, SystemCallError => e
        raise Failure.new(
          phase: "process",
          reason: "spawn_failed",
          detail: "cannot start #{File.basename(argv.fetch(0).to_s)}: #{e.message}"
        )
      end

      private

      def base_teardown
        {
          "status" => "not_started",
          "term_sent" => false,
          "kill_sent" => false,
          "reaped" => false,
          "readers" => "not_started",
          "writer" => "not_started",
          "descendants" => "not_checked"
        }
      end

      def start_writer(stdin, stdin_data)
        Thread.new do
          begin
            stdin.write(stdin_data.to_s) unless stdin_data.nil?
          rescue Errno::EPIPE, IOError
            nil
          ensure
            stdin.close unless stdin.closed?
          end
        end
      end

      def start_reader(io, capture)
        Thread.new do
          loop { capture.update(io.readpartial(READ_CHUNK)) }
        rescue EOFError, IOError
          nil
        end
      end

      def close_and_join_reader(reader, io)
        reader.join(@term_grace)
        unless reader.alive?
          io.close unless io.closed?
          return
        end

        io.close unless io.closed?
        reader.join(@term_grace)
      end

      def wait_for(waiter, seconds)
        joined = waiter.join(seconds)
        joined ? waiter.value : nil
      end

      def signal_group(pgid, signal)
        Process.kill(signal, -pgid)
        true
      rescue Errno::ESRCH
        false
      end

      def wait_until_group_gone(pgid, seconds)
        deadline = monotonic_now + seconds
        loop do
          return true unless live_group?(pgid)
          return false if monotonic_now >= deadline

          sleep 0.01
        end
      end

      def live_group?(pgid)
        proc_members = live_proc_group_members(pgid)
        return !proc_members.empty? unless proc_members.nil?

        Process.kill(0, -pgid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      def live_proc_group_members(pgid)
        return nil unless File.directory?("/proc")

        Dir.glob("/proc/[0-9]*/stat").filter_map do |path|
          stat = File.read(path)
          suffix = stat[(stat.rindex(")") + 2)..]
          fields = suffix.split
          state = fields.fetch(0)
          process_group = Integer(fields.fetch(2), 10)
          File.basename(File.dirname(path)) if process_group == pgid && state != "Z"
        rescue Errno::ENOENT, Errno::EACCES, ArgumentError, IndexError
          nil
        end
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
