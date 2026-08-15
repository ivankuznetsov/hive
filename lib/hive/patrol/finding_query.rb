require "hive/patrol/state_store"

module Hive
  module Patrol
    # Versioned, read-only view over Patrol's writer-maintained finding
    # projection. Both CLI and Web use this boundary.
    class FindingQuery
      SCHEMA = "hive-patrol-findings".freeze
      SCHEMA_VERSION = Hive::Schemas::SCHEMA_VERSIONS.fetch(SCHEMA)

      def self.error_envelope(error)
        Hive::Schemas::ErrorEnvelope.build(
          schema: SCHEMA,
          error: error,
          error_kind: error.is_a?(Hive::ConfigError) ? "config" : "error"
        )
      end

      def initialize(store)
        @store = store
      end

      def list_envelope(project:, project_root:)
        projection = @store.finding_query_projection
        state = @store.state
        {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "ok" => true,
          "action" => "list",
          "project" => project.to_s,
          "project_root" => project_root.to_s,
          "count" => projection.fetch("total"),
          "counts" => projection.fetch("counts"),
          "findings" => projection.fetch("items"),
          "truncated" => projection.fetch("truncated"),
          "last_run_at" => state["last_run_at"],
          "feature_review_active" => state["feature_review_active"] == true
        }
      end

      def text(payload)
        lines = [
          "hive patrol findings: #{payload.fetch('project')} " \
            "count=#{payload.fetch('count')} " \
            "active=#{payload.fetch('counts').fetch('active', 0)} " \
            "returned=#{payload.fetch('findings').size}"
        ]
        payload.fetch("findings").each do |finding|
          lines << [
            finding.fetch("id"),
            "state=#{finding.fetch('lifecycle_state', 'active')}",
            "severity=#{finding['severity']}",
            finding["title"] || finding["category"]
          ].compact.join(" ")
        end
        lines.join("\n")
      end
    end
  end
end
