require "json"
require "time"
require "hive/patrol_fix/admission_store"

module Hive
  module Patrol
    # Ordinary Patrol's source adapter. Accepted findings reserve their immutable
    # source bytes directly in the project AdmissionStore.
    class FixAdmissionAdapter
      attr_reader :store

      class << self
        def for_project(project_root:, hive_state_path: nil)
          project = File.expand_path(project_root)
          state = File.expand_path(hive_state_path || ".hive-state", project)
          new(root: File.join(state, "patrol-fix", "admissions"))
        end

        def snapshot_for(finding, accepted_at:)
          data = finding.to_h
          Hive::PatrolFix::SourceSnapshot.build(
            engine: "ordinary_patrol",
            identity: data.fetch("id").to_s,
            title: text(data["title"], fallback: "Patrol finding #{data.fetch('id')}", max: 2_048),
            summary: text(data["description"] || data["root_cause"],
                          fallback: "Accepted Patrol finding", max: 16 * 1024),
            target_revision: data.fetch("target_sha").to_s,
            evidence: evidence(data),
            affected_code: affected_code(data),
            reproduction_guidance: text(
              data["reproduction"] || data["validation"] || data["recommendation"],
              fallback: "Reproduce and validate the accepted Patrol finding.", max: 16 * 1024
            ),
            discovery_run: text(data["validation_key"] || data["fingerprint"],
                                fallback: data.fetch("id").to_s, max: 512),
            semantic_lineage: semantic_lineage(data),
            aliases: [], external_issues: [], existing_pull_requests: [],
            accepted_at: stable_accepted_at(finding, accepted_at).iso8601
          )
        end

        private

        def evidence(data)
          values = Array(data["evidence"]).map { |value| bounded_json_text(value) }.reject(&:empty?)
          values << text(data["root_cause"] || data["description"],
                         fallback: "Accepted Patrol evidence", max: 16 * 1024) if values.empty?
          values.first(Hive::PatrolFix::SourceSnapshot::MAX_EVIDENCE)
        end

        def affected_code(data)
          scope = data["scope"].is_a?(Hash) ? data.fetch("scope") : {}
          candidates = Array(scope["paths"]) +
                       Array(scope["files"]) +
                       Array(data["evidence"]).filter_map do |item|
                         item.is_a?(Hash) &&
                           (item["path"] || item["file"] || item[:path] || item[:file])
                       end
          paths = candidates.map(&:to_s).select { |path| safe_path?(path) }.uniq
          paths = [ "unknown" ] if paths.empty?
          paths.first(Hive::PatrolFix::SourceSnapshot::MAX_PATHS)
        end

        def semantic_lineage(data)
          values = [ data["fingerprint"], data["feature_id"], data["root_cause"] ]
            .compact.map { |value| text(value, fallback: nil, max: 512) }.compact.uniq
          values = [ data.fetch("id").to_s ] if values.empty?
          values.first(Hive::PatrolFix::SourceSnapshot::MAX_LINEAGE)
        end

        def stable_accepted_at(finding, fallback)
          value = finding.lifecycle_updated_at.to_s
          value.empty? ? fallback.utc : Time.iso8601(value).utc
        rescue ArgumentError
          fallback.utc
        end

        def bounded_json_text(value)
          raw = value.is_a?(String) ? value : JSON.generate(value)
          text(raw, fallback: "", max: 16 * 1024)
        rescue JSON::JSONError, TypeError
          ""
        end

        def text(value, fallback:, max:)
          result = value.to_s.strip
          result = fallback.to_s if result.empty? && fallback
          return nil if result.empty?
          result.byteslice(0, max).to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
            .gsub(/[\u0000-\u001f\u007f]/, " ").strip
        end

        def safe_path?(path)
          !path.empty? && !path.start_with?("/") && !path.include?("\\") &&
            !path.split("/").include?("..") && path.bytesize <= 1_024
        end
      end

      def initialize(root:)
        @store = Hive::PatrolFix::AdmissionStore.new(root: File.expand_path(root))
      end

      def source = "ordinary_patrol"
      def fetch(occurrence_id) = store.fetch(occurrence_id)
      def published?(occurrence_id) = !fetch(occurrence_id).nil?

      def occurrence_id_for(finding)
        snapshot = self.class.snapshot_for(finding, accepted_at: Time.now.utc)
        occurrence_id(finding, snapshot)
      end

      def published_for_finding?(finding)
        published?(occurrence_id_for(finding))
      end

      def reservation_for(finding, accepted_at: Time.now.utc)
        return nil unless admitted?(finding)

        snapshot = self.class.snapshot_for(finding, accepted_at: accepted_at)
        { occurrence_id: occurrence_id(finding, snapshot), snapshot: snapshot }.freeze
      end

      def publish_finding!(finding, accepted_at: Time.now.utc)
        reservation = reservation_for(finding, accepted_at: accepted_at)
        return nil unless reservation

        store.reserve!(
          occurrence_id: reservation.fetch(:occurrence_id),
          snapshot: reservation.fetch(:snapshot), now: accepted_at
        )
      end

      private

      def admitted?(finding)
        finding.respond_to?(:lifecycle_state) &&
          finding.lifecycle_state.to_s == "active" &&
          finding.respond_to?(:lifecycle_reason) &&
          %w[admitted recurrence_after_terminal].include?(finding.lifecycle_reason.to_s)
      end

      def occurrence_id(finding, snapshot)
        "ordinary:#{finding.id}:#{snapshot.evidence_digest[0, 24]}"
      end
    end
  end
end
