module HiveLiveAgentProof
  module OpenClawCreatorProof
    class CapturedProcessStatus
      attr_reader :exitstatus, :termsig

      def initialize(exitstatus:, termsig:)
        @exitstatus = exitstatus
        @termsig = termsig
      end

      def success? = @exitstatus == 0 && @termsig.nil?
    end
  end
end
