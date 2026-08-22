require "json"
require "hive/patrol_fix/admission_store"

module Hive
  module RefactorPatrol
    # Architecture Patrol's source adapter. It preserves the v4 aggregate while
    # reserving accepted immutable source bytes directly in AdmissionStore.
    class FixAdmissionAdapter
      attr_reader :store

      def self.for_project(project_root:, hive_state_path: nil)
        project = File.expand_path(project_root)
        state = File.expand_path(hive_state_path || ".hive-state", project)
        new(root: File.join(state, "patrol-fix", "admissions"))
      end

      def initialize(root:)
        @store = Hive::PatrolFix::AdmissionStore.new(root: File.expand_path(root))
      end

      def source = "architecture_patrol"
      def fetch(occurrence_id) = store.fetch(occurrence_id)
      def published?(occurrence_id) = !fetch(occurrence_id).nil?

      def publish_disposition!(aggregate, disposition, accepted_at: Time.now.utc)
        return nil unless actionable?(disposition)

        snapshot = source_snapshot(aggregate, disposition, accepted_at: accepted_at)
        store.reserve!(
          occurrence_id: occurrence_id(aggregate, disposition, snapshot),
          snapshot: snapshot, now: accepted_at
        )
      end

      private

      def actionable?(disposition)
        disposition["admissible"] == true && %w[fix discuss].include?(disposition["route"])
      end

      def source_snapshot(aggregate, disposition, accepted_at:)
        thesis = disposition.fetch("thesis")
        identity = "#{aggregate.fetch('job_id')}:#{disposition.fetch('id')}"
        evidence = Array(thesis["evidence"]).map { |item| bounded_json_text(item) }.reject(&:empty?)
        evidence = [ text(thesis["problem"], fallback: "Accepted architecture evidence", max: 16 * 1024) ] if evidence.empty?
        paths = Array(thesis.dig("feature_boundary", "owned_files")) +
                Array(aggregate.dig("source", "changed_paths"))
        paths = paths.map(&:to_s).select { |path| safe_path?(path) }.uniq
        paths = [ "unknown" ] if paths.empty?
        commands = Array(thesis.dig("required_validation", "commands"))
        guidance = commands.empty? ? thesis["proposed_refactor"] : commands.join("; ")
        lineage = [ disposition["fingerprint"], disposition["family_id"], thesis["feature_id"] ]
          .compact.map { |value| text(value, fallback: nil, max: 512) }.compact.uniq

        accepted_at = stable_accepted_at(aggregate, accepted_at)
        Hive::PatrolFix::SourceSnapshot.build(
          engine: "architecture_patrol", identity: identity,
          title: text(thesis["proposed_refactor"] || thesis["problem"],
                      fallback: "Architecture thesis #{disposition.fetch('id')}", max: 2_048),
          summary: text([ thesis["problem"], thesis["cost"] ].compact.join(" — "),
                        fallback: "Accepted Architecture Patrol thesis", max: 16 * 1024),
          target_revision: aggregate.fetch("analysis_sha").to_s,
          evidence: evidence.first(Hive::PatrolFix::SourceSnapshot::MAX_EVIDENCE),
          affected_code: paths.first(Hive::PatrolFix::SourceSnapshot::MAX_PATHS),
          reproduction_guidance: text(guidance,
                                      fallback: "Validate the proposed architecture repair.", max: 16 * 1024),
          discovery_run: aggregate.fetch("job_id").to_s,
          semantic_lineage: lineage.empty? ? [ disposition.fetch("id").to_s ] : lineage,
          aliases: [], external_issues: [], existing_pull_requests: [],
          accepted_at: accepted_at.utc.iso8601
        )
      end

      def stable_accepted_at(aggregate, fallback)
        value = aggregate.dig("source", "merged_at") || aggregate["created_at"]
        value ? Time.iso8601(value).utc : fallback.utc
      rescue ArgumentError
        fallback.utc
      end

      def occurrence_id(aggregate, disposition, snapshot)
        "architecture:#{aggregate.fetch('job_id')}:#{disposition.fetch('id')}:#{snapshot.evidence_digest[0, 24]}"
      end

      def bounded_json_text(value)
        raw = value.is_a?(String) ? value : JSON.generate(value)
        text(raw, fallback: "", max: 16 * 1024)
      rescue JSON::GeneratorError, TypeError
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
  end
end
