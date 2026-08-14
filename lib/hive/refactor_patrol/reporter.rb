require "json"
require "hive/refactor_patrol/thesis"

module Hive
  module RefactorPatrol
    class Reporter
      V4_SCHEMA_VERSION = 4
      ZERO_REASONS = %w[no_mapped_slice no_theses all_dismissed].freeze

      def initialize(cfg)
        @cfg = cfg
      end

      def envelope(project:, project_root:, dry_run:, features:, theses:, suppressed:, last_scanned_sha:,
                   version: V4_SCHEMA_VERSION, complete: true, review_errors: [], feature_results: nil)
        raise ArgumentError, "unsupported refactor patrol report version #{version}" unless version == V4_SCHEMA_VERSION

        dispositions = classify(theses, suppressed)
        errors = json_copy(Array(review_errors))
        progress = feature_results || inferred_feature_results(features, theses, errors)
        {
          "schema" => "hive-refactor-patrol",
          "schema_version" => V4_SCHEMA_VERSION,
          "ok" => true,
          "project" => project,
          "project_root" => project_root,
          "dry_run" => dry_run,
          "review_complete" => complete == true && errors.empty? && Array(progress).all? { |item| item["complete"] == true },
          "review_errors" => errors,
          "feature_results" => json_copy(Array(progress)),
          "features_mapped" => features.size,
          "fix" => dispositions.fetch("fix"),
          "discuss" => dispositions.fetch("discuss"),
          "dismiss" => dispositions.fetch("dismiss"),
          "last_scanned_sha" => last_scanned_sha.to_s
        }
      end

      # PR-scoped discovery uses a deliberately separate current contract. Analysis
      # disposition is computed once here and action outcomes are copied into a
      # sibling collection; a later fixer/issue result cannot reclassify a
      # thesis.
      def v4_envelope(job_id:, project:, project_root:, dry_run:, source_pr:, analysis_sha:,
                      features:, theses:, suppressed:, complete:, review_errors:, actions:,
                      attempts:, zero_reason: nil, feature_results: nil)
        dispositions = classify(theses, suppressed)
        errors = json_copy(Array(review_errors))
        actually_complete = complete == true && errors.empty?
        reason = actually_complete ? resolved_zero_reason(zero_reason, features, theses, dispositions) : nil
        progress = feature_results || inferred_feature_results(features, theses, errors)

        {
          "schema" => "hive-refactor-patrol",
          "schema_version" => V4_SCHEMA_VERSION,
          "ok" => true,
          "job_id" => job_id.to_s,
          "project" => project.to_s,
          "project_root" => project_root.to_s,
          "dry_run" => dry_run == true,
          "source_pr" => source_pr.nil? ? nil : json_copy(source_pr),
          "analysis_sha" => analysis_sha.to_s,
          "complete" => actually_complete,
          "features_mapped" => Array(features).size,
          "fix" => dispositions.fetch("fix"),
          "discuss" => dispositions.fetch("discuss"),
          "dismiss" => dispositions.fetch("dismiss"),
          "review_errors" => errors,
          "feature_results" => json_copy(Array(progress)),
          "zero_reason" => reason,
          "attempts" => json_copy(Array(attempts)),
          "actions" => json_copy(Array(actions))
        }
      end

      def self.error_envelope(error, version:, error_kind:, job_id: nil, source_pr: nil)
        unless version == V4_SCHEMA_VERSION
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
        return base if job_id.nil?

        base.merge(
          "job_id" => job_id.to_s,
          "source_pr" => source_pr,
          "complete" => false
        )
      end

      def text(payload, theses)
        dispositions = FINDING_ROUTES.flat_map do |route|
          payload.fetch(route).map { |item| [ route, item ] }
        end
        lines = [
          "hive refactor-patrol: #{payload.fetch('project')} mapped=#{payload.fetch('features_mapped')} " \
          "findings=#{dispositions.size} review=#{payload.fetch('review_complete') ? 'complete' : 'partial'}"
        ]
        dispositions.each_with_index do |(route, item), idx|
          thesis = theses.find { |candidate| candidate.id == item.fetch("id") }
          next unless thesis

          lines << "#{idx + 1}. #{thesis.feature} route=#{route} reasons=#{item.fetch('reasons').join(',')}"
          lines << "   problem: #{thesis.problem}"
          lines << "   refactor: #{thesis.proposed_refactor}"
          lines << "   validation: #{validation_summary(thesis)}"
          lines << "   boundary: #{Array(thesis.feature_boundary['owned_files']).join(', ')}"
        end
        lines << "fix=#{payload.fetch('fix').size} discuss=#{payload.fetch('discuss').size} dismiss=#{payload.fetch('dismiss').size}"
        lines << "review_errors=#{payload.fetch('review_errors').size}" unless payload.fetch("review_complete")
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

        result = { "fix" => [], "discuss" => [], "dismiss" => [] }
        candidates.each do |thesis|
          if (suppression = suppressed_by_id[thesis.id.to_s])
            result.fetch("dismiss") << disposition_item(
              thesis,
              route: "dismiss", reasons: [ suppression.fetch("reason").to_s ],
              reference: suppression["reference"]
            )
            next
          end

          route = thesis.effective_route(min_confidence: min_confidence)
          reasons = thesis.route_reasons(min_confidence: min_confidence)
          result.fetch(route) << disposition_item(thesis, route: route, reasons: reasons)
        end
        result
      end

      def disposition_item(thesis, route:, reasons:, reference: nil)
        {
          "id" => thesis.id.to_s,
          "feature_id" => thesis.feature_id.to_s,
          "fingerprint" => thesis.fingerprint.to_s,
          "route" => route,
          "admissible" => thesis.admissible == true,
          "reasons" => reasons,
          # The daemon checkpoints this immutable snapshot into the
          # authoritative job aggregate. Action workers must never have to
          # re-run discovery or reconstruct a proposal from mutable files.
          "thesis" => json_copy(thesis.to_h.merge("route" => route))
        }.tap do |item|
          item["reference"] = reference.to_s unless reference.nil? || reference.to_s.empty?
        end
      end

      def resolved_zero_reason(explicit, features, theses, dispositions)
        no_actionable_dispositions = dispositions.fetch("fix").empty? && dispositions.fetch("discuss").empty?
        return nil unless no_actionable_dispositions

        inferred = if Array(features).empty?
                     "no_mapped_slice"
        elsif Array(theses).empty?
                     "no_theses"
        elsif dispositions.fetch("dismiss").size == Array(theses).size
                     "all_dismissed"
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

      def inferred_feature_results(features, theses, errors)
        Array(features).map do |feature|
          feature_errors = errors.select { |error| error["feature_id"].to_s == feature.id.to_s }
          {
            "feature_id" => feature.id.to_s,
            "complete" => feature_errors.empty?,
            "thesis_ids" => Array(theses).select { |thesis| thesis.feature_id.to_s == feature.id.to_s }
                                          .map { |thesis| thesis.id.to_s },
            "errors" => feature_errors
          }
        end
      end

      def json_copy(value)
        JSON.parse(JSON.generate(value))
      end

      def min_confidence
        @cfg.dig("refactor_patrol", "min_confidence") || "medium"
      end

      def validation_summary(thesis)
        validation = thesis.required_validation
        commands = Array(validation["commands"])
        return "characterization first: #{validation['notes']}" if validation["characterization_first"]

        commands.join(", ")
      end

    end
  end
end
