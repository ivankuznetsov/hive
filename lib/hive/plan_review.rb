require "hive"

module Hive
  module PlanReview
    SCHEMA = "hive-plan-review".freeze
    SCHEMA_VERSION = 1
    LEVELS = %w[skip standard mandatory].freeze
    LEVEL_RANK = LEVELS.each_with_index.to_h.freeze
    CLASSIFIER_VERSION = 1

    class Error < Hive::Error; end
    class InvalidPlan < Error; end
    class InvalidRecord < Error; end
    class StaleObservation < Error; end
    class TransitionBlocked < Error; end

    module_function

    def level!(value, label: "plan review level")
      normalized = value.to_s.strip
      return normalized if LEVEL_RANK.key?(normalized)

      raise Hive::ConfigError,
            "#{label} must be one of #{LEVELS.join(', ')}; got #{value.inspect}"
    end

    def higher_level(*levels)
      levels.compact.map { |level| level!(level) }.max_by { |level| LEVEL_RANK.fetch(level) }
    end
  end
end
