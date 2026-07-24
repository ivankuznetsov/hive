require "hive"

module Hive
  module Attempts
    ClientResult = Data.define(
      :status, :exit_status, :outcome, :receipt, :attempt_id, :stdout_bytes
    ) do
      def initialize(status:, exit_status:, outcome:, receipt:, attempt_id:, stdout_bytes: 0)
        super
      end

      def stdout_emitted? = stdout_bytes.to_i.positive?
    end

    DispatchResult = Data.define(:status, :attempt, :receipt, :attach_descriptor, :reason) do
      def accepted? = status == :accepted
      def live? = %i[accepted existing_live].include?(status)
    end

    class UnsupportedDetachment < Hive::Error; end
  end
end
