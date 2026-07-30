module Hive
  module RefactorPatrol
    class EffectDenied < StandardError
      attr_reader :reason, :receipt

      def initialize(reason, receipt)
        @reason = reason.to_s.freeze
        @receipt = receipt
        super("architecture patrol effect denied: #{@reason}")
      end
    end

    class EffectReconciliationRequired < StandardError
      attr_reader :reason, :receipt

      def initialize(reason, receipt)
        @reason = reason.to_s.freeze
        @receipt = receipt
        super("architecture patrol effect requires exact reconciliation: #{@reason}")
      end
    end
  end
end
