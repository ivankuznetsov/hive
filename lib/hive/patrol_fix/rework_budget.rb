require "hive/patrol_fix"

module Hive
  module PatrolFix
    # One task-level bound on automatic rework cycles. Independent review and
    # the pre-publication secret gate draw from the same
    # `patrol.max_rework_cycles` allowance, so neither can loop a task
    # forever and together they cannot exceed the configured cap. Operator
    # releases are deliberate decisions and never consult this budget.
    module ReworkBudget
      DEFAULT_MAX_REWORKS = 2

      module_function

      def limit(cfg, override = nil)
        value = override.nil? ? (cfg || {}).dig("patrol", "max_rework_cycles") : override
        value = DEFAULT_MAX_REWORKS if value.nil?
        unless value.is_a?(Integer) && value >= 0
          raise Hive::ConfigError, "Patrol Fix max rework cycles must be a non-negative integer"
        end

        value
      end

      def spent(receipts)
        receipts.count do |row|
          row["kind"] == "decision" && row.dig("payload", "route") == "rework"
        end
      end

      def remaining?(receipts, limit)
        spent(receipts) < limit
      end
    end
  end
end
