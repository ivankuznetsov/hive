require "json"
require "rbconfig"
require "hive/attempts/capability"
require "hive/attempts/store"
require "hive/attempts/stream_log"
require "hive/lock"

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
        @worker_pid = nil
        @worker_pgid = nil
      end

      def run
        @claim_capability = read_claim_capability
        return fail_before_start("invalid_claim_capability") unless @claim_capability

        record = @store.fetch(@attempt_id)
        return fail_before_start("attempt_not_launching") unless record&.state == "launching"

        log = StreamLog.new(log_path(record.attempt_id), clock: @clock)
        now = @clock.call
        record = @store.claim(
          record, owner: process_identity(Process.pid),
          claim_capability: @claim_capability,
          first_heartbeat_timeout_sec: @first_heartbeat_timeout_sec, now: now
        )
        record = @store.first_heartbeat(record, stale_sec: @stale_sec, now: @clock.call)
        signal_ready("claimed" => true, "attempt_id" => record.attempt_id, "pid" => Process.pid)
        install_signal_handlers! if @install_signal_handlers

        exit_status, outcome, record = run_worker(record, log)
        log.close
        log_reference = OutputReference.build(log.path, root: @store.root)
        terminal = @store.terminalize(
          record, outcome: outcome, exit_status: exit_status,
          final_checkpoint: record.checkpoint,
          output_references: record["current_outputs"],
          log_reference: log_reference, now: @clock.call
        )
        terminal.receipt.fetch("exit_status")
      rescue CompareAndSwapFailed, StoreError => e
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
            @store.terminalize(
              current, outcome: "failed", exit_status: Hive::ExitCodes::SOFTWARE,
              final_checkpoint: current.checkpoint, output_references: current["current_outputs"],
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
          context_w.write(@claim_capability)
          context_w.close
          gate_r.close_on_exec = false
          context_r.close_on_exec = false
          env.merge!(
            "HIVE_ATTEMPT_INTERNAL" => "1",
            "HIVE_ATTEMPT_ID" => record.attempt_id,
            "HIVE_ATTEMPT_GATE_FD" => gate_r.fileno.to_s,
            "HIVE_ATTEMPT_CONTEXT_FD" => context_r.fileno.to_s
          )
          spawn_options[gate_r.fileno] = gate_r.fileno
          spawn_options[context_r.fileno] = context_r.fileno
        end
        @worker_pid = Process.spawn(
          env, *resolved_worker_argv(record), spawn_options
        )
        gate_r&.close unless gate_r&.closed?
        context_r&.close unless context_r&.closed?
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
          ready = readers.empty? ? nil : IO.select(readers.keys, nil, nil, wait_for)
          Array(ready&.first).each { |io| drain_reader(io, readers, log) }

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
        outcome = @cancel_reason ? "cancelled" : (exit_status.zero? ? "succeeded" : "failed")
        [ exit_status, outcome, record ]
      ensure
        [ stdout_r, stdout_w, stderr_r, stderr_w, gate_r, gate_w, context_r, context_w ].compact.each do |io|
          io.close unless io.closed?
        end
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
          raise StoreError, "worker process group identity changed"
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
        raise StoreError, "worker process group cannot be signalled"
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
        raise StoreError, "process #{pid} disappeared before identity capture"
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

      def log_path(attempt_id)
        File.join(@store.logs_root, "#{attempt_id}.frames")
      end

      def install_signal_handlers!
        %w[TERM INT].each do |signal|
          Signal.trap(signal) { @cancel_reason ||= :signal }
        end
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
