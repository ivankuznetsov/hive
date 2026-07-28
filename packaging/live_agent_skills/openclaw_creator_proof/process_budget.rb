module HiveLiveAgentProof
  module OpenClawCreatorProof
    class ProcessBudget
      POST_KILL_GRACE = 2.0
      OWNER_CLEANUP_MARGIN = 1.0
      PARENT_WATCHDOG_MARGIN = 1.0

      attr_reader :term_grace, :timeout

      def initialize(timeout:, term_grace:)
        @timeout = Float(timeout)
        @term_grace = Float(term_grace)
        raise ArgumentError, "timeout must be positive" unless @timeout.positive?
        raise ArgumentError, "term_grace must be positive" unless @term_grace.positive?
      end

      def post_kill_grace = POST_KILL_GRACE

      def owner_seconds
        @timeout + (2 * @term_grace) + POST_KILL_GRACE + OWNER_CLEANUP_MARGIN
      end

      def parent_seconds
        owner_seconds + PARENT_WATCHDOG_MARGIN
      end

      def owner_shutdown_seconds
        @term_grace + POST_KILL_GRACE + OWNER_CLEANUP_MARGIN
      end
    end
  end
end
