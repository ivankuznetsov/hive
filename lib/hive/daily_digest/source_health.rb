require "hive/daily_digest/materiality"

module Hive
  module DailyDigest
    # Typed source result used by collectors so one unavailable project never
    # turns healthy projects into a false empty day.
    SourceHealth = Data.define(:source, :scope, :status, :freshness_at, :gap) do
      def self.healthy(source:, scope:, freshness_at: nil)
        new(source: source, scope: scope, status: "healthy", freshness_at: freshness_at, gap: nil)
      end

      def self.unavailable(source:, scope:, reason_code:, reason:, observed_at:,
                           freshness_at: nil, project_id: nil)
        gap = Materiality.build_gap(
          source: source, scope: scope, reason_code: reason_code, reason: reason,
          observed_at: observed_at, freshness_at: freshness_at, project_id: project_id
        )
        new(source: source, scope: scope, status: "unavailable", freshness_at: freshness_at, gap: gap)
      end

      def healthy? = status == "healthy"
    end
  end
end
