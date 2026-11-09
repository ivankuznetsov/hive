require "hive"

module Hive
  module Attempts
    class RepositoryError < Hive::Error; end
    class CompareAndSwapFailed < RepositoryError; end
    # The attempt record built for one task failed its own validation (for
    # example a task without an id). That is a per-task data problem, not a
    # storage failure, so callers may block just that task.
    class InvalidAttemptRecord < RepositoryError; end
    # SQLite lock contention outlasted the runtime database busy timeout:
    # another Hive process held the write lock. Nothing was written, and the
    # same operation can be retried later, so callers may defer instead of
    # failing. Corruption, schema, and storage errors never take this class.
    class RuntimeDatabaseBusy < RepositoryError
      def exit_code = Hive::ExitCodes::TEMPFAIL
    end
    class CapacityExceeded < RepositoryError; end
    class StaleTaskSource < RepositoryError; end

    module BookkeepingReason
      VALUES = %w[runtime_bookkeeping_busy first_heartbeat_owner_unverifiable_ceiling].freeze

      def self.from(value)
        if value.is_a?(Hash)
          reason = value[:error_reason] || value["error_reason"] || value[:reason] || value["reason"]
          return reason if VALUES.include?(reason)
        else
          candidates = value.is_a?(Exception) ? Hive::InternalError.exception_chain(value) : [ value ]
          candidates.each do |candidate|
            reason = candidate.reason if candidate.respond_to?(:reason)
            return reason if VALUES.include?(reason)
          end
        end
        nil
      end
    end

    ClientResult = Data.define(
      :status, :exit_status, :outcome, :receipt, :attempt_id, :stdout_bytes,
      :output_status, :reason
    ) do
      def initialize(status:, exit_status:, outcome:, receipt:, attempt_id:, stdout_bytes: 0,
                     output_status: nil, reason: nil)
        super
      end

      def stdout_emitted? = stdout_bytes.to_i.positive?
    end

    DispatchResult = Data.define(
      :status, :attempt, :receipt, :attach_descriptor, :reason, :decision
    ) do
      def initialize(status:, attempt:, receipt:, attach_descriptor:, reason:, decision: nil)
        super
      end

      def accepted? = status == :accepted
      def live? = %i[accepted existing_live].include?(status)
    end

    class UnsupportedDetachment < Hive::Error; end
  end
end
