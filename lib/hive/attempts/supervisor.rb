require "json"
require "rbconfig"
require "hive/atomic_file"
require "hive/attempts/capability"
require "hive/attempts/diagnostic_channel"
require "hive/attempts/evidence_channel"
require "hive/attempts/command_progress"
require "hive/attempts/repository"
require "hive/attempts/stream_log"
require "hive/lock"
require "hive/patrol_fix/attempt_diagnostic"

module Hive
  module Attempts
    # Authoritative owner for one accepted task command. It claims the lease,
    # reaches running before spawning, owns the worker process group, refreshes
    # heartbeat/checkpoint state, captures ordered output, and atomically
    # commits the only valid terminal receipt.
    class Supervisor
      READ_CHUNK = 16 * 1024

      def initialize(store:, attempt_id:, claim_io:, ready_io: nil,
                     heartbeat_sec: 5, stale_sec: 30,
                     first_heartbeat_timeout_sec: 30, timeout_sec: nil,
                     kill_grace_sec: 1, clock: -> { Time.now.utc },
                     monotonic: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                     install_signal_handlers: false)
        @store = store
        @attempt_id = attempt_id
        @claim_io = claim_io
        @ready_io = ready_io
        @heartbeat_sec = heartbeat_sec
        @stale_sec = stale_sec
        @first_heartbeat_timeout_sec = first_heartbeat_timeout_sec
        @timeout_sec = timeout_sec&.positive? ? timeout_sec : nil
        @kill_grace_sec = kill_grace_sec
        @clock = clock
        @monotonic = monotonic
        @install_signal_handlers = install_signal_handlers
        @ready_sent = false
        @cancel_reason = nil
        @cancel_signal = nil
        @worker_signal = nil
        @worker_pid = nil
        @worker_pgid = nil
      end

      def run
        @claim_capability = read_claim_capability
        return fail_before_start("invalid_claim_capability") unless @claim_capability

        record = @store.fetch(@attempt_id)
        return fail_before_start("attempt_not_launching") unless record&.state == "launching"

        log = @store.log_archive.open_writer(record.attempt_id, clock: @clock)
        now = @clock.call
        record = @store.claim(
          record, owner: process_identity(Process.pid),
          claim_capability: @claim_capability,
          first_heartbeat_timeout_sec: @first_heartbeat_timeout_sec, now: now
        )
        record = @store.first_heartbeat(record, stale_sec: @stale_sec, now: @clock.call)
        signal_ready("claimed" => true, "attempt_id" => record.attempt_id, "pid" => Process.pid)
        install_signal_handlers! if @install_signal_handlers

        exit_status, outcome, record, provider_signal, diagnostic_frame = run_worker(record, log)
        log.close
        log_reference = OutputReference.build(log.path, root: @store.root)
        if provider_signal
          exit_status = Hive::ExitCodes::SOFTWARE if exit_status.zero?
          outcome = "failed"
        end
        provider_evidence = EvidenceChannel.materialize(
          provider_signal,
          record: record,
          source_reference: log_reference
        )
        output_references = record["current_outputs"].dup
        diagnostic_reference = materialize_attempt_diagnostic(
          record, diagnostic_frame, log_reference: log_reference,
          exit_status: exit_status, outcome: outcome,
          provider_signal: provider_signal
        )
        output_references << diagnostic_reference if diagnostic_reference
        terminal = @store.terminalize(
          record, outcome: outcome, exit_status: exit_status,
          final_checkpoint: record.checkpoint,
          output_references: output_references,
          log_reference: log_reference, provider_evidence: provider_evidence,
          now: @clock.call
        )
        terminal.receipt.fetch("exit_status")
      rescue CompareAndSwapFailed, RepositoryError => e
        terminate_worker_group
        signal_ready("claimed" => false, "attempt_id" => @attempt_id, "error" => e.message)
        Hive::ExitCodes::TEMPFAIL
      rescue StandardError => e
        terminate_worker_group
        begin
          log&.append(:supervisor, "hive attempt supervisor failed: #{e.class}: #{e.message}\n")
          log&.close
          current = @store.fetch(@attempt_id)
          if current&.state == "running"
            reference = OutputReference.build(log.path, root: @store.root)
            output_references = current["current_outputs"].dup
            diagnostic_reference = materialize_attempt_diagnostic(
              current, nil, log_reference: reference,
              exit_status: Hive::ExitCodes::SOFTWARE, outcome: "failed"
            )
            output_references << diagnostic_reference if diagnostic_reference
            @store.terminalize(
              current, outcome: "failed", exit_status: Hive::ExitCodes::SOFTWARE,
              final_checkpoint: current.checkpoint, output_references: output_references,
              log_reference: reference, now: @clock.call
            )
          end
        rescue StandardError
          nil
        end
        signal_ready("claimed" => false, "attempt_id" => @attempt_id, "error" => e.message)
        Hive::ExitCodes::SOFTWARE
      ensure
        signal_ready("claimed" => false, "attempt_id" => @attempt_id, "error" => "wrapper_exited")
        @ready_io&.close unless @ready_io&.closed?
        @claim_io&.close unless @claim_io&.closed?
        log&.close unless log&.closed?
      end

      private

      def run_worker(record, log)
        stdout_r, stdout_w = IO.pipe
        stderr_r, stderr_w = IO.pipe
        env = scrubbed_attempt_environment
        spawn_options = {
          in: File::NULL, out: stdout_w, err: stderr_w, pgroup: true,
          close_others: true
        }
        if hive_worker?(record)
          gate_r, gate_w = IO.pipe
          context_r, context_w = IO.pipe
          diagnostic_r, diagnostic_w = IO.pipe
          context_w.write(@claim_capability)
          context_w.close
          gate_r.close_on_exec = false
          context_r.close_on_exec = false
          diagnostic_w.close_on_exec = false
          env.merge!(
            "HIVE_ATTEMPT_INTERNAL" => "1",
            "HIVE_ATTEMPT_ID" => record.attempt_id,
            "HIVE_ATTEMPT_GATE_FD" => gate_r.fileno.to_s,
            "HIVE_ATTEMPT_CONTEXT_FD" => context_r.fileno.to_s,
            "HIVE_ATTEMPT_DIAGNOSTIC_FD" => diagnostic_w.fileno.to_s
          )
          spawn_options[gate_r.fileno] = gate_r.fileno
          spawn_options[context_r.fileno] = context_r.fileno
          spawn_options[diagnostic_w.fileno] = diagnostic_w.fileno
          if record["routing"]["mode"] == "explicit"
            evidence_r, evidence_w = IO.pipe
            evidence_w.close_on_exec = false
            env["HIVE_ATTEMPT_EVIDENCE_FD"] = evidence_w.fileno.to_s
            spawn_options[evidence_w.fileno] = evidence_w.fileno
          end
        end
        @worker_pid = Process.spawn(
          env, *resolved_worker_argv(record), spawn_options
        )
        gate_r&.close unless gate_r&.closed?
        context_r&.close unless context_r&.closed?
        evidence_w&.close unless evidence_w&.closed?
        diagnostic_w&.close unless diagnostic_w&.closed?
        stdout_w.close
        stderr_w.close
        worker_identity = process_identity(@worker_pid)
        @worker_pgid = worker_identity.fetch("process_group_id")
        record = @store.checkpoint(
          record, checkpoint: record.checkpoint,
          worker: worker_identity, now: @clock.call
        )
        if gate_w
          gate_w.write("1")
          gate_w.close
        end

        readers = { stdout_r => :stdout, stderr_r => :stderr }
        next_heartbeat = @monotonic.call + @heartbeat_sec
        timeout_at = @timeout_sec && (@monotonic.call + @timeout_sec)
        status = nil
        forced_exit = nil
        post_exit_started = false
        post_exit_deadline = nil
        lingering_group = false
        termination_deadline = nil
        termination_kill_sent = false

        until status && readers.empty? && !lingering_group
          now_mono = @monotonic.call
          if @cancel_reason && forced_exit.nil?
            forced_exit = @cancel_reason == :timeout ? 124 : 143
            if status.nil?
              signal_worker_group("TERM")
              termination_deadline = now_mono + @kill_grace_sec
            end
          elsif timeout_at && now_mono >= timeout_at && @cancel_reason.nil?
            @cancel_reason = :timeout
            next
          end

          if termination_deadline && now_mono >= termination_deadline &&
             status.nil? && !termination_kill_sent
            signal_worker_group("KILL")
            termination_kill_sent = true
          end

          if now_mono >= next_heartbeat
            record = @store.heartbeat(record, stale_sec: @stale_sec, now: @clock.call)
            next_heartbeat = now_mono + @heartbeat_sec
          end

          if post_exit_started && post_exit_deadline && now_mono >= post_exit_deadline
            signal_recorded_worker_group("KILL") if recorded_worker_group_alive?
            readers.keys.each { |io| drain_reader(io, readers, log) }
            close_readers(readers)
            lingering_group = false
            next
          end

          wait_for = [ next_heartbeat - now_mono, 0.05 ].min
          wait_for = [ wait_for, timeout_at - now_mono ].min if timeout_at && @cancel_reason.nil?
          if termination_deadline && status.nil?
            wait_for = [ wait_for, termination_deadline - now_mono ].min
          end
          wait_for = [ wait_for, post_exit_deadline - now_mono ].min if post_exit_deadline
          wait_for = 0 if wait_for.negative?
          if readers.empty?
            # With every output pipe at EOF there is nothing to select on, but
            # the loop may still be awaiting worker exit or a lingering group.
            # Sleep the computed budget so WNOHANG polling does not busy-spin.
            sleep(wait_for) if wait_for.positive?
          else
            ready = IO.select(readers.keys, nil, nil, wait_for)
            Array(ready&.first).each { |io| drain_reader(io, readers, log) }
          end

          if status.nil?
            waited = Process.wait2(@worker_pid, Process::WNOHANG)
            status = waited&.last
          end

          if status && !post_exit_started
            post_exit_started = true
            lingering_group = recorded_worker_group_alive?
            if lingering_group || readers.any?
              signal_recorded_worker_group("TERM") if lingering_group && termination_deadline.nil?
              post_exit_deadline = termination_deadline || (@monotonic.call + @kill_grace_sec)
            end
          elsif lingering_group && !recorded_worker_group_alive?
            lingering_group = false
          end
          readers.keys.each { |io| drain_reader(io, readers, log) } if status
        end

        exit_status = forced_exit || status_exit(status)
        @worker_signal = signal_name(status.termsig) if status && !status.exited?
        outcome = @cancel_reason ? "cancelled" : (exit_status.zero? ? "succeeded" : "failed")
        provider_signal = EvidenceChannel.read(
          evidence_r,
          route: record["routing"].fetch("route")
        ) if evidence_r
        diagnostic_frame = DiagnosticChannel.read(diagnostic_r) if diagnostic_r
        [ exit_status, outcome, record, provider_signal, diagnostic_frame ]
      ensure
        [
          stdout_r, stdout_w, stderr_r, stderr_w, gate_r, gate_w,
          context_r, context_w, evidence_r, evidence_w,
          diagnostic_r, diagnostic_w
        ].compact.each do |io|
          io.close unless io.closed?
        end
      end

      def materialize_attempt_diagnostic(record, frame, log_reference:, exit_status:, outcome:,
                                         provider_signal: nil)
        return nil if outcome == "succeeded"
        return nil unless patrol_fix_attempt?(record)

        transport_status = frame&.status || "missing"
        document = finalize_or_synthesize_diagnostic(
          record, frame, log_reference: log_reference,
          exit_status: exit_status, outcome: outcome,
          transport_status: transport_status, provider_signal: provider_signal
        )
        path = @store.output_path(
          record.attempt_id,
          Hive::PatrolFix::AttemptDiagnostic::FILENAME,
          create_directory: true
        )
        persist_diagnostic_once(path, document)
        OutputReference.build(path, root: @store.root)
      end

      def finalize_or_synthesize_diagnostic(record, frame, log_reference:, exit_status:,
                                            outcome:, transport_status:, provider_signal: nil)
        if frame&.document
          begin
            return Hive::PatrolFix::AttemptDiagnostic.finalize(
              frame.document,
              log_reference: log_reference,
              expected_attempt_id: record.attempt_id,
              expected_stage: record["intended_stage"],
              expected_task_generation: record.task_generation,
              transport_status: transport_status,
              provider_signal: provider_signal,
              provider_name: record["provider"]
            )
          rescue Hive::PatrolFix::AttemptDiagnostic::InvalidDiagnostic
            transport_status = "malformed"
          end
        end

        envelope = {
          "phase" => "terminal",
          "status" => outcome == "cancelled" ? "cancelled" : "error",
          "exit_code" => exit_status,
          "timed_out" => @cancel_reason == :timeout,
          "cancelled" => outcome == "cancelled",
          "signal" => @worker_signal || @cancel_signal,
          "report_status" => "unknown",
          "firewall_status" => "unknown",
          "custody_status" => "unknown"
        }
        if provider_signal
          envelope.merge!(
            "provider" => record["provider"],
            "provider_failure" => provider_signal.fetch("failure_class"),
            "provider_provenance" => provider_signal.fetch("provenance"),
            "retry_at" => provider_signal["reset_hint_seconds"]
          )
        end
        Hive::PatrolFix::AttemptDiagnostic.normalize(
          envelope,
          stage: record["intended_stage"],
          task_generation: record.task_generation,
          attempt_id: record.attempt_id,
          recorded_at: @clock.call,
          transport_status: transport_status,
          log_reference: log_reference
        )
      end

      def patrol_fix_attempt?(record)
        require "hive/task_resolver"
        target = Array(record["worker_argv"])[2].to_s
        return false if target.empty?

        task = Hive::TaskResolver.new(target, project_filter: record["project"]).resolve
        Hive::Attempts::CommandProgress.task_progress?(task)
      rescue Hive::Error, SystemCallError
        false
      end

      def persist_diagnostic_once(path, document)
        source = JSON.generate(document) + "\n"
        flags = File::WRONLY | File::CREAT | File::EXCL
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(path, flags, 0o600) do |file|
          file.write(source)
          file.flush
          file.fsync
        end
        Hive::AtomicFile.fsync_directory(File.dirname(path))
        true
      rescue Errno::EEXIST
        existing = read_existing_diagnostic(path)
        raise Hive::Attempts::RepositoryError, "attempt diagnostic immutable bytes conflict" unless existing == document

        true
      rescue JSON::ParserError, SystemCallError, IOError => e
        raise Hive::Attempts::RepositoryError, "attempt diagnostic storage failed: #{e.message}"
      end

      def read_existing_diagnostic(path)
        flags = File::RDONLY | File::NONBLOCK
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        bytes = File.open(path, flags) do |file|
          stat = file.stat
          unless stat.file? && stat.nlink == 1
            raise Hive::Attempts::RepositoryError, "attempt diagnostic is not a single regular file"
          end
          if stat.size > Hive::PatrolFix::AttemptDiagnostic::MAX_BYTES
            raise Hive::Attempts::RepositoryError, "attempt diagnostic exceeds its size limit"
          end

          file.read(Hive::PatrolFix::AttemptDiagnostic::MAX_BYTES + 1).to_s
        end
        if bytes.bytesize > Hive::PatrolFix::AttemptDiagnostic::MAX_BYTES
          raise Hive::Attempts::RepositoryError, "attempt diagnostic exceeds its size limit"
        end

        document = JSON.parse(bytes)
        Hive::PatrolFix::AttemptDiagnostic.validate!(document)
        document
      rescue JSON::ParserError, Hive::PatrolFix::AttemptDiagnostic::InvalidDiagnostic,
             SystemCallError, IOError => e
        raise Hive::Attempts::RepositoryError, "attempt diagnostic storage failed: #{e.message}"
      end

      def drain_reader(io, readers, log)
        loop do
          chunk = io.read_nonblock(READ_CHUNK, exception: false)
          case chunk
          when :wait_readable then return
          when nil
            io.close unless io.closed?
            readers.delete(io)
            return
          else
            log.append(readers.fetch(io), chunk)
          end
        end
      rescue EOFError, IOError
        io.close unless io.closed?
        readers.delete(io)
      end

      def close_readers(readers)
        readers.each_key { |io| io.close unless io.closed? }
        readers.clear
      end

      def terminate_worker_group
        return nil unless @worker_pid

        signal_worker_group("TERM")
        deadline = @monotonic.call + @kill_grace_sec
        loop do
          waited = Process.wait2(@worker_pid, Process::WNOHANG)
          return waited.last if waited
          break if @monotonic.call >= deadline

          sleep [ 0.01, deadline - @monotonic.call ].min
        end
        signal_worker_group("KILL")
        Process.wait2(@worker_pid).last
      rescue Errno::ECHILD, Errno::ESRCH
        nil
      end

      def signal_worker_group(signal)
        pgid = Process.getpgid(@worker_pid)
        expected_pgid = @worker_pgid || @worker_pid
        unless pgid == @worker_pid && pgid == expected_pgid
          raise RepositoryError, "worker process group identity changed"
        end

        Process.kill(signal, -pgid)
      end

      def signal_recorded_worker_group(signal)
        return false unless @worker_pid && @worker_pgid == @worker_pid

        Process.kill(signal, -@worker_pgid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        raise RepositoryError, "worker process group cannot be signalled"
      end

      def recorded_worker_group_alive?
        return false unless @worker_pid && @worker_pgid == @worker_pid

        Process.kill(0, -@worker_pgid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      def status_exit(status)
        return Hive::ExitCodes::SOFTWARE unless status
        return status.exitstatus if status.exited?

        128 + status.termsig.to_i
      end

      def process_identity(pid)
        {
          "pid" => pid,
          "start_fingerprint" => Hive::Lock.process_start_time(pid),
          "session_id" => Process.getsid(pid),
          "process_group_id" => Process.getpgid(pid)
        }
      rescue Errno::ESRCH
        raise RepositoryError, "process #{pid} disappeared before identity capture"
      end

      def resolved_worker_argv(record)
        worker_argv = record["worker_argv"]
        return worker_argv unless worker_argv.first == "hive"

        [ RbConfig.ruby, File.expand_path("../../../bin/hive", __dir__), *worker_argv.drop(1) ]
      end

      def hive_worker?(record)
        record["worker_argv"].first == "hive"
      end

      def scrubbed_attempt_environment
        ENV.keys.grep(/\AHIVE_ATTEMPT_/).to_h { |key| [ key, nil ] }
      end

      def read_claim_capability
        return nil unless @claim_io

        value = @claim_io.read((Capability::SECRET_BYTES * 2) + 1)
        Capability.valid_secret?(value) ? value : nil
      rescue IOError, SystemCallError
        nil
      end

      def install_signal_handlers!
        %w[TERM INT].each do |signal|
          Signal.trap(signal) do
            @cancel_signal ||= signal
            @cancel_reason ||= :signal
          end
        end
      end

      def signal_name(number)
        Signal.list.key(number.to_i) || number.to_s
      end

      def signal_ready(payload)
        return if @ready_sent || @ready_io.nil? || @ready_io.closed?

        @ready_io.write(JSON.generate(payload) + "\n")
        @ready_io.flush
        @ready_sent = true
      rescue IOError, Errno::EPIPE
        @ready_sent = true
      end

      def fail_before_start(reason)
        signal_ready("claimed" => false, "attempt_id" => @attempt_id, "error" => reason)
        Hive::ExitCodes::TEMPFAIL
      end
    end
  end
end
