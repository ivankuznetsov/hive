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
                     group_reader: Process.method(:getpgid))
        @start_reader = start_reader
        @signaler = signaler
        @session_reader = session_reader
        @group_reader = group_reader
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

      private

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
