module Hive
  module RefactorPatrol
    # One durable discovery claim can emit its claim, one progress checkpoint
    # per feature, and one terminal checkpoint or release. Admission reserves
    # that complete unit so a worker never starts work it cannot journal.
    module DiscoveryCapacity
      MAX_FEATURES_PER_CLAIM = 12
      MAX_EFFECTS_PER_CLAIM = MAX_FEATURES_PER_CLAIM + 2

      module_function

      def exhausted?(effect_count:, effect_limit:)
        effect_count >= effect_limit - MAX_EFFECTS_PER_CLAIM
      end
    end
  end
end
