require "hive/lock"

module Hive
  module Attempts
    ProcessSnapshot = Data.define(
      :pid, :start_fingerprint, :session_id, :process_group_id
    ) do
      def to_h
        {
          "pid" => pid,
          "start_fingerprint" => start_fingerprint,
          "session_id" => session_id,
          "process_group_id" => process_group_id
        }
      end
    end

    # Host-local PID-reuse-safe identity checks. Adoption never calls wait2:
    # adopted wrappers are not children of the restarted daemon.
    class ProcessIdentity
      def initialize(start_reader: Hive::Lock.method(:process_start_time),
                     signaler: Process.method(:kill),
                     session_reader: Process.method(:getsid),
                     group_reader: Process.method(:getpgid),
                     sleeper: ->(seconds) { sleep(seconds) },
                     monotonic: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @start_reader = start_reader
        @signaler = signaler
        @session_reader = session_reader
        @group_reader = group_reader
        @sleeper = sleeper
        @monotonic = monotonic
      end

      def capture(pid)
        pid = Integer(pid)
        return nil unless alive?(pid)

        start = @start_reader.call(pid)
        return nil if start.to_s.empty?

        ProcessSnapshot.new(
          pid: pid,
          start_fingerprint: start.to_s,
          session_id: @session_reader.call(pid),
          process_group_id: @group_reader.call(pid)
        )
      rescue ArgumentError, TypeError, Errno::ESRCH, Errno::EPERM
        nil
      end

      # :matching | :missing | :mismatched | :unverifiable
      def status(expected)
        return :unverifiable unless expected.is_a?(Hash)

        pid = Integer(expected["pid"] || expected[:pid])
        return :missing unless alive?(pid)

        recorded_start = (expected["start_fingerprint"] || expected[:start_fingerprint]).to_s
        live_start = @start_reader.call(pid).to_s
        return :unverifiable if recorded_start.empty? || live_start.empty?
        return :mismatched unless recorded_start == live_start

        live_session = @session_reader.call(pid)
        live_group = @group_reader.call(pid)
        expected_session = expected["session_id"] || expected[:session_id]
        expected_group = expected["process_group_id"] || expected[:process_group_id]
        return :mismatched if expected_session && live_session != expected_session
        return :mismatched if expected_group && live_group != expected_group

        :matching
      rescue ArgumentError, TypeError
        :unverifiable
      rescue Errno::ESRCH
        :missing
      rescue Errno::EPERM
        :unverifiable
      end

      def safe_group?(wrapper:, worker: nil)
        return false unless status(wrapper) == :matching

        wrapper_session = wrapper["session_id"] || wrapper[:session_id]
        wrapper_group = wrapper["process_group_id"] || wrapper[:process_group_id]
        return false unless wrapper_session && wrapper_group && wrapper_session == wrapper_group
        return true unless worker
        return false unless status(worker) == :matching

        worker_session = worker["session_id"] || worker[:session_id]
        worker_session == wrapper_session
      end

      # Cleanup for the one supported orphan case: the authoritative wrapper
      # is gone but its recorded worker group is still alive in that wrapper's
      # session. Identity is rechecked before TERM and again before KILL.
      def terminate_orphan_group(wrapper:, worker:, grace_sec: 2)
        state = orphan_group_status(wrapper: wrapper, worker: worker)
        return :absent if state == :absent
        return :identity_mismatch unless state == :matching

        pgid = worker["process_group_id"] || worker[:process_group_id]
        @signaler.call("TERM", -Integer(pgid))
        deadline = @monotonic.call + grace_sec
        loop do
          state = orphan_group_status(wrapper: wrapper, worker: worker)
          return :terminated if state == :absent
          return :identity_changed unless state == :matching
          break if @monotonic.call >= deadline

          @sleeper.call([ 0.05, deadline - @monotonic.call ].min)
        end

        return :identity_changed unless orphan_group_status(wrapper: wrapper, worker: worker) == :matching

        @signaler.call("KILL", -Integer(pgid))
        20.times do
          state = orphan_group_status(wrapper: wrapper, worker: worker)
          return :terminated if state == :absent
          return :identity_changed unless state == :matching

          @sleeper.call(0.01)
        end
        :still_alive
      rescue Errno::ESRCH
        :terminated
      rescue Errno::EPERM, ArgumentError, TypeError
        :identity_mismatch
      end

      def orphan_group_status(wrapper:, worker:)
        return :mismatched unless orphan_group_metadata_matches?(wrapper: wrapper, worker: worker)

        worker_status = status(worker)
        if worker_status == :missing
          worker_group = worker["process_group_id"] || worker[:process_group_id]
          return :absent if process_group_presence(worker_group) == :missing

          # A process group can outlive its leader. Without the leader's start
          # identity there is no safe way to prove that the remaining group is
          # still ours, but its existence must continue to fence successors.
          return :unverifiable
        end
        return worker_status unless worker_status == :matching

        :matching
      end

      private

      def orphan_group_metadata_matches?(wrapper:, worker:)
        return false unless wrapper.is_a?(Hash) && worker.is_a?(Hash)

        wrapper_session = wrapper["session_id"] || wrapper[:session_id]
        wrapper_group = wrapper["process_group_id"] || wrapper[:process_group_id]
        worker_session = worker["session_id"] || worker[:session_id]
        worker_group = worker["process_group_id"] || worker[:process_group_id]
        wrapper_session && wrapper_group && wrapper_session == wrapper_group &&
          worker_session == wrapper_session && worker_group.is_a?(Integer) && worker_group.positive?
      end

      def process_group_presence(pgid)
        @signaler.call(0, -Integer(pgid))
        :alive
      rescue Errno::ESRCH
        :missing
      rescue Errno::EPERM
        :alive
      rescue ArgumentError, TypeError, SystemCallError
        :unverifiable
      end

      def alive?(pid)
        @signaler.call(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end
    end
  end
end
