require "json"

module Hive
  module RefactorPatrol
    class Reporter
      V1_SCHEMA_VERSION = 1
      V2_SCHEMA_VERSION = 2
      CONFIDENCE_ORDER = { "low" => 0, "medium" => 1, "high" => 2 }.freeze
      ZERO_REASONS = %w[no_mapped_slice no_theses all_suppressed].freeze

      def initialize(cfg)
        @cfg = cfg
      end

      def envelope(project:, project_root:, dry_run:, features:, theses:, suppressed:, last_scanned_sha:,
                   version: V1_SCHEMA_VERSION)
        raise ArgumentError, "unsupported refactor patrol report version #{version}" unless version == V1_SCHEMA_VERSION

        ranked = ranked_items(theses)
        {
          "schema" => "hive-refactor-patrol",
          "schema_version" => V1_SCHEMA_VERSION,
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

      # PR-scoped discovery uses a deliberately separate v2 contract. Analysis
      # disposition is computed once here and action outcomes are copied into a
      # sibling collection; a later fixer/issue result cannot reclassify a
      # thesis.
      def v2_envelope(job_id:, project:, project_root:, dry_run:, source_pr:, analysis_sha:,
                      features:, theses:, suppressed:, complete:, review_errors:, actions:,
                      attempts:, zero_reason: nil)
        dispositions = classify(theses, suppressed)
        errors = json_copy(Array(review_errors))
        actually_complete = complete == true && errors.empty?
        reason = actually_complete ? resolved_zero_reason(zero_reason, features, theses, dispositions) : nil

        {
          "schema" => "hive-refactor-patrol",
          "schema_version" => V2_SCHEMA_VERSION,
          "ok" => true,
          "job_id" => job_id.to_s,
          "project" => project.to_s,
          "project_root" => project_root.to_s,
          "dry_run" => dry_run == true,
          "source_pr" => source_pr.nil? ? nil : json_copy(source_pr),
          "analysis_sha" => analysis_sha.to_s,
          "complete" => actually_complete,
          "features_mapped" => Array(features).size,
          "accepted" => dispositions.fetch("accepted"),
          "flagged" => dispositions.fetch("flagged"),
          "suppressed" => dispositions.fetch("suppressed"),
          "review_errors" => errors,
          "zero_reason" => reason,
          "attempts" => json_copy(Array(attempts)),
          "actions" => json_copy(Array(actions))
        }
      end

      def self.error_envelope(error, version:, error_kind:, job_id: nil, source_pr: nil)
        unless [ V1_SCHEMA_VERSION, V2_SCHEMA_VERSION ].include?(version)
          raise ArgumentError, "unsupported refactor patrol report version #{version}"
        end

        base = Hive::Schemas::ErrorEnvelope.build(
          schema: "hive-refactor-patrol",
          error: error,
          error_kind: error_kind.to_s
        ).slice(
          "schema", "schema_version", "ok", "error_class", "error_kind", "exit_code", "message"
        )
        base["schema_version"] = version
        return base if version == V1_SCHEMA_VERSION

        base.merge(
          "job_id" => job_id.to_s,
          "source_pr" => source_pr,
          "complete" => false
        )
      end

      def text(payload, theses)
        lines = [
          "hive refactor-patrol: #{payload.fetch('project')} mapped=#{payload.fetch('features_mapped')} theses=#{payload.fetch('theses')}"
        ]
        payload.fetch("ranked").each_with_index do |item, idx|
          thesis = theses.find { |candidate| candidate.id == item.fetch("id") }
          next unless thesis

          line = "#{idx + 1}. #{thesis.feature} score=#{format('%.2f', item.fetch('score'))} flags=#{item.fetch('flagged').join(',')}"
          advisories = item.fetch("advisories")
          line += " advisories=#{advisories.join(',')}" unless advisories.empty?
          lines << line
          lines << "   problem: #{thesis.problem}"
          lines << "   refactor: #{thesis.proposed_refactor}"
          lines << "   validation: #{validation_summary(thesis)}"
          lines << "   boundary: #{Array(thesis.feature_boundary['owned_files']).join(', ')}"
        end
        lines << "flagged=#{payload.fetch('flagged_theses').size} suppressed=#{payload.fetch('suppressed').size}"
        lines.join("\n")
      end

      private

      def classify(theses, suppressed)
        candidates = Array(theses)
        ids = candidates.map { |thesis| thesis.id.to_s }
        duplicate = ids.tally.find { |_id, count| count > 1 }&.first
        raise ArgumentError, "duplicate thesis id #{duplicate.inspect}" if duplicate

        suppressed_by_id = Array(suppressed).to_h do |item|
          id = item.fetch("id").to_s
          raise ArgumentError, "suppressed thesis #{id.inspect} has no generated thesis" unless ids.include?(id)

          [ id, item ]
        end
        if suppressed_by_id.size != Array(suppressed).size
          raise ArgumentError, "duplicate suppressed thesis id"
        end

        result = { "accepted" => [], "flagged" => [], "suppressed" => [] }
        candidates.each do |thesis|
          if (suppression = suppressed_by_id[thesis.id.to_s])
            result.fetch("suppressed") << disposition_item(
              thesis,
              reasons: [ suppression.fetch("reason").to_s ],
              reference: suppression["reference"]
            )
            next
          end

          reasons = Array(thesis.risk && thesis.risk["flags"]).map(&:to_s).reject(&:empty?)
          unless thesis.admissible == true
            reason = thesis.admissibility_reason.to_s
            reasons << reason unless reason.empty?
          end
          reasons << "below_min_confidence" if below_min_confidence?(thesis)
          reasons.uniq!
          bucket = reasons.empty? && thesis.admissible == true ? "accepted" : "flagged"
          result.fetch(bucket) << disposition_item(thesis, reasons: reasons)
        end
        result
      end

      def disposition_item(thesis, reasons:, reference: nil)
        {
          "id" => thesis.id.to_s,
          "feature_id" => thesis.feature_id.to_s,
          "fingerprint" => thesis.fingerprint.to_s,
          "score" => score(thesis),
          "admissible" => thesis.admissible == true,
          "reasons" => reasons
        }.tap do |item|
          item["reference"] = reference.to_s unless reference.nil? || reference.to_s.empty?
        end
      end

      def below_min_confidence?(thesis)
        CONFIDENCE_ORDER.fetch(thesis.confidence.to_s, -1) < min_confidence
      end

      def resolved_zero_reason(explicit, features, theses, dispositions)
        no_actionable_dispositions = dispositions.fetch("accepted").empty? && dispositions.fetch("flagged").empty?
        return nil unless no_actionable_dispositions

        inferred = if Array(features).empty?
                     "no_mapped_slice"
        elsif Array(theses).empty?
                     "no_theses"
        elsif dispositions.fetch("suppressed").size == Array(theses).size
                     "all_suppressed"
        end
        requested = explicit&.to_s
        if requested && !ZERO_REASONS.include?(requested)
          raise ArgumentError, "unsupported zero reason #{requested.inspect}"
        end
        if requested && inferred && requested != inferred
          raise ArgumentError, "zero reason #{requested.inspect} does not match #{inferred.inspect}"
        end

        requested || inferred
      end

      def json_copy(value)
        JSON.parse(JSON.generate(value))
      end

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
            "flagged" => Array(thesis.risk["flags"]),
            "advisories" => Array(thesis.risk["advisories"])
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
        theses.count do |thesis|
          thesis.admissible &&
            Array(thesis.risk["flags"]).empty? &&
            CONFIDENCE_ORDER.fetch(thesis.confidence.to_s, -1) >= min_confidence &&
            thesis.collision.nil?
        end
      end

      def min_confidence
        CONFIDENCE_ORDER.fetch(@cfg.dig("refactor_patrol", "min_confidence") || "medium")
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
