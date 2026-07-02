module Hive
  module RefactorPatrol
    class Reporter
      CONFIDENCE_ORDER = { "low" => 0, "medium" => 1, "high" => 2 }.freeze

      def initialize(cfg)
        @cfg = cfg
      end

      def envelope(project:, project_root:, dry_run:, features:, theses:, suppressed:, last_scanned_sha:)
        ranked = ranked_items(theses)
        {
          "schema" => "hive-refactor-patrol",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-refactor-patrol"),
          "ok" => true,
          "project" => project,
          "project_root" => project_root,
          "dry_run" => dry_run,
          "features_mapped" => features.size,
          "theses" => accepted_count(theses),
          "ranked" => ranked.first(max_theses_per_run),
          "flagged_theses" => flagged_items(theses),
          "suppressed" => suppressed,
          "last_scanned_sha" => last_scanned_sha.to_s
        }
      end

      def text(payload, theses)
        lines = [
          "hive refactor-patrol: #{payload.fetch('project')} mapped=#{payload.fetch('features_mapped')} theses=#{payload.fetch('theses')}"
        ]
        payload.fetch("ranked").each_with_index do |item, idx|
          thesis = theses.find { |candidate| candidate.id == item.fetch("id") }
          next unless thesis

          lines << "#{idx + 1}. #{thesis.feature} score=#{format('%.2f', item.fetch('score'))} flags=#{item.fetch('flagged').join(',')}"
          lines << "   problem: #{thesis.problem}"
          lines << "   refactor: #{thesis.proposed_refactor}"
          lines << "   validation: #{validation_summary(thesis)}"
          lines << "   boundary: #{Array(thesis.feature_boundary['owned_files']).join(', ')}"
        end
        lines << "flagged=#{payload.fetch('flagged_theses').size} suppressed=#{payload.fetch('suppressed').size}"
        lines.join("\n")
      end

      private

      def ranked_items(theses)
        theses.reject { |thesis| thesis.collision && thesis.collision["kind"].to_s.start_with?("collision_already", "collision_dismissed", "collision_similar") }
              .sort_by { |thesis| -score(thesis) }
              .map do |thesis|
          {
            "id" => thesis.id,
            "feature_id" => thesis.feature_id,
            "score" => score(thesis),
            "breakdown" => thesis.expected_leverage.fetch("breakdown", {}),
            "admissible" => thesis.admissible == true,
            "flagged" => Array(thesis.risk["flags"])
          }
        end
      end

      def flagged_items(theses)
        theses.filter_map do |thesis|
          reasons = []
          reasons.concat(Array(thesis.risk["flags"]))
          reasons << thesis.admissibility_reason unless thesis.admissible
          next if reasons.empty?

          { "id" => thesis.id, "reason" => reasons.uniq.join(",") }
        end
      end

      def accepted_count(theses)
        min = CONFIDENCE_ORDER.fetch(@cfg.dig("refactor_patrol", "min_confidence") || "medium")
        theses.count do |thesis|
          thesis.admissible &&
            Array(thesis.risk["flags"]).empty? &&
            CONFIDENCE_ORDER.fetch(thesis.confidence.to_s, -1) >= min &&
            thesis.collision.nil?
        end
      end

      def score(thesis)
        thesis.expected_leverage.fetch("score", 0).to_f
      end

      def validation_summary(thesis)
        validation = thesis.required_validation
        commands = Array(validation["commands"])
        return "characterization first: #{validation['notes']}" if validation["characterization_first"]

        commands.join(", ")
      end

      def max_theses_per_run
        @cfg.dig("refactor_patrol", "max_theses_per_run") || 10
      end
    end
  end
end
