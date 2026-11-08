require "hive"

module Hive
  module Attempts
    class RepositoryError < Hive::Error; end
    class CompareAndSwapFailed < RepositoryError; end
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
