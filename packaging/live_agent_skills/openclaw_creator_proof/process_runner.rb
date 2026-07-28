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
        retained_tail = [ scan.bytesize, @scan_window ].min
        @tail = scan.byteslice(scan.bytesize - retained_tail, retained_tail).to_s.b
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

    class CapturedProcessStatus
      attr_reader :exitstatus, :termsig

      def initialize(exitstatus:, termsig:)
        @exitstatus = exitstatus
        @termsig = termsig
      end

      def success? = @exitstatus == 0 && @termsig.nil?
    end

    class ProcessRunner
      READ_CHUNK = 16 * 1024
      POST_KILL_GRACE = 2.0
      SUPERVISOR_CLEANUP_MARGIN = 1.0
      PR_SET_CHILD_SUBREAPER = 36
      PR_GET_CHILD_SUBREAPER = 37

      attr_reader :supervisor_pid

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
        ensure_containment_available!
        reader, writer = IO.pipe
        pid = Process.fork do
          reader.close
          write_supervised_result(
            writer,
            environment: environment,
            argv: argv,
            chdir: chdir,
            stdin_data: stdin_data,
            timeout: Float(timeout)
          )
        end
        writer.close
        @supervisor_pid = pid
        payload = Marshal.load(reader)
        _waited_pid, supervisor_status = Process.wait2(pid)
        supervisor_reaped = true
        unless supervisor_status.success?
          raise Failure.new(
            phase: "process",
            reason: "containment_failed",
            detail: "process containment supervisor exited unsuccessfully"
          )
        end
        raise_marshaled_failure!(payload) if payload["failure"]

        status_record = payload.delete("status_record")
        payload["status"] = status_record && CapturedProcessStatus.new(
          exitstatus: status_record["exitstatus"],
          termsig: status_record["termsig"]
        )
        payload
      rescue EOFError, TypeError => e
        raise Failure.new(
          phase: "process",
          reason: "containment_failed",
          detail: "process containment supervisor returned invalid evidence: #{e.message}"
        )
      ensure
        reader&.close unless reader&.closed?
        writer&.close unless writer&.closed?
        reap_supervisor(pid) if pid && !supervisor_reaped
        @supervisor_pid = nil
      end

      private

      def ensure_containment_available!
        available = RUBY_PLATFORM.include?("linux") &&
                    File.directory?("/proc") &&
                    Process.respond_to?(:fork)
        return if available

        raise Failure.new(
          phase: "process",
          reason: "containment_unavailable",
          detail: "Linux /proc child-subreaper containment is required"
        )
      end

      def reap_supervisor(pid)
        begin
          Process.kill("TERM", pid)
        rescue Errno::ESRCH
          nil
        end
        deadline =
          monotonic_now + @term_grace + POST_KILL_GRACE +
          SUPERVISOR_CLEANUP_MARGIN
        loop do
          begin
            waited = Process.waitpid(pid, Process::WNOHANG)
          rescue Errno::ECHILD
            return
          end
          return if waited
          break if monotonic_now >= deadline

          sleep 0.01
        end
        begin
          Process.kill("KILL", pid)
        rescue Errno::ESRCH
          nil
        end
        begin
          Process.waitpid(pid)
        rescue Errno::ECHILD
          nil
        end
      end

      def write_supervised_result(writer, **options)
        Signal.trap("TERM") { raise Interrupt }
        enable_child_subreaper!
        payload = run_supervised(**options)
      rescue Interrupt
        payload = failure_payload(
          reason: "interrupted",
          detail: "process containment supervisor was interrupted"
        )
      rescue Failure => e
        payload = failure_payload(
          phase: e.phase,
          reason: e.reason,
          detail: e.message
        )
      rescue StandardError => e
        payload = failure_payload(
          reason: "containment_failed",
          detail: "#{e.class}: #{e.message}"
        )
      ensure
        Signal.trap("TERM", "IGNORE")
        cleanup_failure = drain_supervisor_descendants
        payload = cleanup_failure if cleanup_failure
        payload ||= failure_payload(
          reason: "containment_failed",
          detail: "process containment supervisor exited without a result"
        )
        begin
          Marshal.dump(payload, writer)
        rescue Errno::EPIPE, IOError
          nil
        end
        writer.close unless writer.closed?
        exit! 0
      end

      def enable_child_subreaper!
        handle = Fiddle::Handle::DEFAULT
        function = Fiddle::Function.new(
          handle["prctl"],
          [
            Fiddle::TYPE_INT, Fiddle::TYPE_LONG, Fiddle::TYPE_LONG,
            Fiddle::TYPE_LONG, Fiddle::TYPE_LONG
          ],
          Fiddle::TYPE_INT
        )
        state = Fiddle::Pointer.malloc(Fiddle::SIZEOF_INT)
        state[0, Fiddle::SIZEOF_INT] = [ 0 ].pack("i")
        configured = function.call(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0).zero?
        observed =
          function.call(PR_GET_CHILD_SUBREAPER, state.to_i, 0, 0, 0).zero? &&
          state[0, Fiddle::SIZEOF_INT].unpack1("i") == 1
        return if configured && observed

        raise Failure.new(
          phase: "process",
          reason: "containment_unavailable",
          detail: "cannot establish and verify Linux child-subreaper containment"
        )
      rescue Fiddle::DLError => e
        raise Failure.new(
          phase: "process",
          reason: "containment_unavailable",
          detail: "cannot load Linux process containment: #{e.message}"
        )
      end

      def drain_supervisor_descendants
        teardown = base_teardown
        terminate_remaining_descendants(teardown)
        reap_adopted_children
        remaining = live_descendants
        return if remaining.empty?

        failure_payload(
          reason: "containment_failed",
          detail:
            "process containment supervisor retained #{remaining.length} descendant(s)"
        )
      rescue StandardError => e
        failure_payload(
          reason: "containment_failed",
          detail: "process containment cleanup failed: #{e.class}: #{e.message}"
        )
      end

      def failure_payload(reason:, detail:, phase: "process")
        {
          "failure" => {
            "phase" => phase,
            "reason" => reason,
            "detail" => detail
          }
        }
      end

      def run_supervised(environment:, argv:, chdir:, stdin_data:, timeout:)
        started = monotonic_now
        stdout_capture = StreamCapture.new(limit: @output_limit, exact_secrets: @exact_secrets)
        stderr_capture = StreamCapture.new(limit: @output_limit, exact_secrets: @exact_secrets)
        status = nil
        teardown = base_teardown
        timed_out = false
        interrupted = false

        Open3.popen3(
          environment, *argv,
          chdir: chdir, pgroup: true, unsetenv_others: true
        ) do |stdin, stdout, stderr, waiter|
          writer = start_writer(stdin, stdin_data)
          stdout_reader = start_reader(stdout, stdout_capture)
          stderr_reader = start_reader(stderr, stderr_capture)
          begin
            status = wait_for(waiter, timeout)
            unless status
              timed_out = true
              terminate_running_tree(waiter, teardown)
              status = wait_for(waiter, POST_KILL_GRACE)
            end
          rescue Interrupt
            interrupted = true
            terminate_running_tree(waiter, teardown)
            status = wait_for(waiter, POST_KILL_GRACE)
          ensure
            terminate_remaining_descendants(teardown)
            close_and_join_writer(writer, stdin)
            close_and_join_reader(stdout_reader, stdout)
            close_and_join_reader(stderr_reader, stderr)
            finalize_teardown!(teardown, status, writer, stdout_reader, stderr_reader)
          end
        end

        build_result(
          argv: argv,
          started: started,
          status: status,
          stdout_capture: stdout_capture,
          stderr_capture: stderr_capture,
          teardown: teardown,
          timed_out: timed_out,
          interrupted: interrupted
        )
      rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR, SystemCallError => e
        raise Failure.new(
          phase: "process",
          reason: "spawn_failed",
          detail: "cannot start #{File.basename(argv.fetch(0).to_s)}: #{e.message}"
        )
      end

      def terminate_running_tree(waiter, teardown)
        teardown["term_sent"] =
          signal_group(waiter.pid, "TERM") || signal_descendants("TERM") ||
          teardown["term_sent"]
        return if wait_for(waiter, @term_grace)

        teardown["kill_sent"] =
          signal_group(waiter.pid, "KILL") || signal_descendants("KILL") ||
          teardown["kill_sent"]
      end

      def terminate_remaining_descendants(teardown)
        return if live_descendants.empty?

        teardown["term_sent"] = signal_descendants("TERM") || teardown["term_sent"]
        return if wait_until_descendants_gone(@term_grace)

        teardown["kill_sent"] = signal_descendants("KILL") || teardown["kill_sent"]
        wait_until_descendants_gone(POST_KILL_GRACE)
      end

      def signal_descendants(signal)
        pids = live_descendants
        signalled = false
        pids.reverse_each do |pid|
          Process.kill(signal, pid)
          signalled = true
        rescue Errno::ESRCH
          nil
        end
        signalled
      end

      def wait_until_descendants_gone(seconds)
        deadline = monotonic_now + seconds
        loop do
          reap_adopted_children
          return true if live_descendants.empty?
          return false if monotonic_now >= deadline

          sleep 0.01
        end
      end

      def live_descendants
        parent_map = {}
        states = {}
        Dir.glob("/proc/[0-9]*/stat").each do |path|
          pid, parent_pid, state = proc_identity(path)
          parent_map[parent_pid] ||= []
          parent_map[parent_pid] << pid
          states[pid] = state
        rescue Errno::ENOENT, Errno::EACCES, ArgumentError, IndexError
          next
        end
        queue = Array(parent_map[Process.pid])
        descendants = []
        until queue.empty?
          pid = queue.shift
          descendants << pid unless states[pid] == "Z"
          queue.concat(Array(parent_map[pid]))
        end
        descendants.uniq
      end

      def proc_identity(path)
        stat = File.read(path)
        suffix = stat[(stat.rindex(")") + 2)..]
        fields = suffix.split
        [
          Integer(File.basename(File.dirname(path)), 10),
          Integer(fields.fetch(1), 10),
          fields.fetch(0)
        ]
      end

      def reap_adopted_children
        loop do
          pid = Process.waitpid(-1, Process::WNOHANG)
          break unless pid
        end
      rescue Errno::ECHILD
        nil
      end

      def finalize_teardown!(teardown, status, writer, stdout_reader, stderr_reader)
        reap_adopted_children
        remaining = live_descendants
        teardown["reaped"] = !status.nil? && remaining.empty?
        teardown["readers"] =
          stdout_reader.alive? || stderr_reader.alive? ? "incomplete" : "complete"
        teardown["writer"] = writer.alive? ? "incomplete" : "complete"
        teardown["descendants"] = remaining.empty? ? "none" : "remaining"
        teardown["containment"] = "linux_child_subreaper"
        teardown["status"] =
          if teardown["reaped"] && teardown["readers"] == "complete" &&
             teardown["writer"] == "complete" && teardown["descendants"] == "none"
            "passed"
          else
            "failed"
          end
      end

      def build_result(argv:, started:, status:, stdout_capture:, stderr_capture:,
                       teardown:, timed_out:, interrupted:)
        {
          "status_record" => status && {
            "exitstatus" => status.exitstatus,
            "termsig" => status.termsig
          },
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
            "interrupted" => interrupted,
            "duration_ms" => ((monotonic_now - started) * 1_000).round,
            "stdout" => stdout_capture.record,
            "stderr" => stderr_capture.record,
            "teardown" => teardown
          }
        }
      end

      def raise_marshaled_failure!(payload)
        failure = payload.fetch("failure")
        raise Failure.new(
          phase: failure.fetch("phase"),
          reason: failure.fetch("reason"),
          detail: failure.fetch("detail")
        )
      end

      def base_teardown
        {
          "status" => "not_started",
          "term_sent" => false,
          "kill_sent" => false,
          "reaped" => false,
          "readers" => "not_started",
          "writer" => "not_started",
          "descendants" => "not_checked",
          "containment" => "linux_child_subreaper"
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

      def close_and_join_writer(writer, stdin)
        writer.join(@term_grace)
        if writer.alive?
          stdin.close unless stdin.closed?
          writer.join(@term_grace)
        end
        stdin.close unless stdin.closed?
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

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
