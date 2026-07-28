module HiveLiveAgentProof
  module OpenClawCreatorProof
    class CaptureWorker
      READ_CHUNK = 16 * 1024

      def initialize(budget:, output_limit:, exact_secrets:, secret_patterns:,
                     network_capture_factory: nil, warden_factory: nil)
        @budget = budget
        @output_limit = output_limit
        @exact_secrets = exact_secrets
        @secret_patterns = secret_patterns
        @network_capture_factory =
          network_capture_factory || ->(pid) { NetworkCapture.new(pid) }
        @warden_factory =
          warden_factory || lambda { |pid|
            ContainmentWarden.new(root_pid: pid, budget: @budget)
          }
      end

      def call(environment:, argv:, chdir:, stdin_data:, timeout:)
        started = monotonic_now
        stdout_capture = stream_capture
        stderr_capture = stream_capture
        status = nil
        timed_out = false
        interrupted = false
        network_capture = nil
        worker_teardown = nil

        Open3.popen3(
          environment, *argv,
          chdir: chdir, pgroup: true, unsetenv_others: true
        ) do |stdin, stdout, stderr, waiter|
          warden = @warden_factory.call(Process.pid)
          network_capture = @network_capture_factory.call(waiter.pid)
          network_capture.start
          writer = start_writer(stdin, stdin_data)
          stdout_reader = start_reader(stdout, stdout_capture)
          stderr_reader = start_reader(stderr, stderr_capture)
          begin
            status = wait_for(waiter, timeout)
            unless status
              timed_out = true
              terminate_running_tree(waiter, warden)
              status = wait_for(waiter, @budget.post_kill_grace)
            end
          rescue Interrupt
            interrupted = true
            terminate_running_tree(waiter, warden)
            status = wait_for(waiter, @budget.post_kill_grace)
          ensure
            cleanup_errors = []
            safely(cleanup_errors) { warden.drain_remaining_descendants }
            safely(cleanup_errors) { network_capture.stop }
            safely(cleanup_errors) { close_and_join_writer(writer, stdin) }
            safely(cleanup_errors) { close_and_join_reader(stdout_reader, stdout) }
            safely(cleanup_errors) { close_and_join_reader(stderr_reader, stderr) }
            worker_teardown = worker_teardown(
              status, writer, stdout_reader, stderr_reader, warden
            )
            raise cleanup_errors.first if cleanup_errors.any?
          end
        end

        build_result(
          argv: argv,
          started: started,
          status: status,
          stdout_capture: stdout_capture,
          stderr_capture: stderr_capture,
          network_capture: network_capture,
          worker_teardown: worker_teardown,
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

      private

      def stream_capture
        StreamCapture.new(
          limit: @output_limit,
          exact_secrets: @exact_secrets,
          secret_patterns: @secret_patterns
        )
      end

      def terminate_running_tree(waiter, warden)
        warden.terminate_group(waiter.pid, "TERM")
        return if wait_for(waiter, @budget.term_grace)

        warden.terminate_group(waiter.pid, "KILL")
      end

      def worker_teardown(status, writer, stdout_reader, stderr_reader, warden)
        remaining = warden.descendants
        {
          "term_sent" => warden.term_sent,
          "kill_sent" => warden.kill_sent,
          "target_reaped" => !status.nil?,
          "readers" =>
            stdout_reader.alive? || stderr_reader.alive? ? "incomplete" : "complete",
          "writer" => writer.alive? ? "incomplete" : "complete",
          "descendants" => remaining.empty? ? "none" : "remaining"
        }
      end

      def build_result(argv:, started:, status:, stdout_capture:, stderr_capture:,
                       network_capture:, worker_teardown:, timed_out:, interrupted:)
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
            "network" => network_capture.record
          },
          "worker_teardown" => worker_teardown
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
        end.tap { |thread| thread.report_on_exception = false }
      end

      def start_reader(io, capture)
        Thread.new do
          loop { capture.update(io.readpartial(READ_CHUNK)) }
        rescue EOFError, IOError
          nil
        end.tap { |thread| thread.report_on_exception = false }
      end

      def close_and_join_writer(writer, stdin)
        close_and_join_thread(writer, stdin, "stdin writer")
      end

      def close_and_join_reader(reader, io)
        close_and_join_thread(reader, io, "stream reader")
      end

      def close_and_join_thread(thread, io, label)
        error = join_error(thread)
        closing_error = close_error(io)
        error ||= closing_error
        if thread.alive?
          final_join_error = join_error(thread)
          error ||= final_join_error
        end
        fail_thread!(label, error) if error
        observe_thread!(thread, label)
      end

      def observe_thread!(thread, label)
        if thread.alive?
          raise Failure.new(
            phase: "process",
            reason: "containment_failed",
            detail: "#{label} thread did not stop"
          )
        end

        thread.value
      rescue Failure
        raise
      rescue StandardError => e
        fail_thread!(label, e)
      end

      def fail_thread!(label, error)
        raise Failure.new(
          phase: "process",
          reason: "containment_failed",
          detail: "#{label} thread failed: #{error.class}: #{error.message}"
        )
      end

      def join_error(thread)
        thread.join(@budget.term_grace)
        nil
      rescue StandardError => e
        e
      end

      def close_error(io)
        io.close unless io.closed?
        nil
      rescue StandardError => e
        e
      end

      def wait_for(waiter, seconds)
        joined = waiter.join(seconds)
        joined ? waiter.value : nil
      end

      def safely(errors)
        yield
      rescue StandardError => e
        errors << e
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
