module Hive
  module Patrol
    # Selects a deterministic, persisted review batch so language-neutral
    # component coverage can grow without turning one patrol cycle into an
    # unbounded number of reviewer-agent calls.
    class FeatureBatch
      DEFAULT_LIMIT = 12

      Result = Data.define(:features, :next_cursor, :complete)

      def initialize(cfg:, state:)
        @cfg = cfg
        @state = state
      end

      def call(features, target_sha:)
        ordered = Array(features).sort_by { |feature| feature.id.to_s }
        return Result.new(features: [], next_cursor: 0, complete: true) if ordered.empty?

        snapshot = @state.state
        cursor = snapshot["feature_review_sha"].to_s == target_sha.to_s ? snapshot["feature_review_cursor"].to_i : 0
        cursor = 0 unless cursor.between?(0, ordered.length - 1)
        selected = ordered.slice(cursor, limit) || []
        next_cursor = cursor + selected.length
        complete = next_cursor >= ordered.length
        Result.new(features: selected, next_cursor: complete ? 0 : next_cursor, complete: complete)
      end

      private

      def limit
        value = @cfg.dig("patrol", "max_features_per_cycle")
        value.is_a?(Integer) && value.positive? ? value : DEFAULT_LIMIT
      end
    end
  end
end
