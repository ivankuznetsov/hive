require "hive"

module Hive
  module Attempts
    class RepositoryError < Hive::Error; end
    class CompareAndSwapFailed < RepositoryError; end
    class CapacityExceeded < RepositoryError; end
    class StaleTaskSource < RepositoryError; end

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
