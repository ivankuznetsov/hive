module Hive
  module ProviderRouting
    class Decision
      Rejection = Data.define(:provider, :model, :reason, :detail)

      attr_reader :status, :candidate, :account, :profile, :lease, :probe,
                  :attempt_id, :reason, :wait_reason, :rejections, :explanation

      def initialize(status:, attempt_id:, reason:, wait_reason:, rejections:,
                     explanation:, candidate: nil, account: nil, profile: nil,
                     lease: nil, probe: nil)
        @status = status.to_sym
        @candidate = candidate
        @account = account
        @profile = profile
        @lease = lease
        @probe = probe
        @attempt_id = attempt_id.to_s
        @reason = reason.to_s
        @wait_reason = wait_reason&.to_s
        @rejections = rejections.freeze
        @explanation = explanation.to_s
        freeze
      end

      def selected?
        status == :selected
      end

      def wait?
        status == :wait
      end

      def provider
        candidate&.provider
      end

      def model
        candidate&.model
      end

      def agent
        candidate&.agent
      end

      def effort
        candidate&.effort
      end

      def probe?
        !probe.nil? && probe.claimed
      end
    end
  end
end
