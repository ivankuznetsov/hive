module Hive
  module Patrol
    # Selects a deterministic, persisted review batch so language-neutral
    # component coverage can grow without turning one patrol cycle into an
    # unbounded number of reviewer-agent calls.
    class FeatureBatch
      DEFAULT_LIMIT = 12

      Result = Data.define(:features, :start_cursor, :next_cursor, :complete)

      def initialize(cfg:, state:)
        @cfg = cfg
        @state = state
      end

      def call(features, target_sha:, limit: nil)
        ordered = Array(features).sort_by { |feature| feature.id.to_s }
        if ordered.empty?
          return Result.new(features: [], start_cursor: 0, next_cursor: 0, complete: true)
        end

        snapshot = @state.state
        cursor = snapshot["feature_review_sha"].to_s == target_sha.to_s ? snapshot["feature_review_cursor"].to_i : 0
        cursor = 0 unless cursor.between?(0, ordered.length - 1)
        selected = ordered.slice(cursor, effective_limit(limit)) || []
        next_cursor = cursor + selected.length
        complete = next_cursor >= ordered.length
        Result.new(
          features: selected, start_cursor: cursor,
          next_cursor: complete ? 0 : next_cursor, complete: complete
        )
      end

      private

      def limit
        value = @cfg.dig("patrol", "max_features_per_cycle")
        value.is_a?(Integer) && value.positive? ? value : DEFAULT_LIMIT
      end

      def effective_limit(runtime_limit)
        return limit unless runtime_limit.is_a?(Integer) && runtime_limit.positive?

        [ limit, runtime_limit ].min
      end
    end
  end
end
