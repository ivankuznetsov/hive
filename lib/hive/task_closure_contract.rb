module Hive
  # Lightweight public vocabulary for closure-capable command surfaces.
  # The full TaskClosure service stays lazy until an operator enters the
  # preview/confirm flow.
  module TaskClosureContract
    REASONS = %w[already_delivered superseded cancelled].freeze
  end
end
