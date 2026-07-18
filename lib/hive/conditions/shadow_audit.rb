module Hive
  module Conditions
    module ShadowAudit
      CATEGORIES = %w[
        commit_success research_success no_change agent_loss operator_repair
      ].freeze
      MINIMUM_TRANSITIONS = 100

      module_function

      def event(task:, attempt:, task_generation:, commit_generation:, category:,
                marker_action:, condition_action:, explained: false)
        category = category.to_s
        raise ArgumentError, "unknown shadow audit category #{category.inspect}" unless CATEGORIES.include?(category)

        {
          event_type: "shadow_audit",
          task: {
            "id" => task.respond_to?(:id) ? task.id&.to_s : nil,
            "slug" => task.slug.to_s
          },
          workflow: "coding",
          stage: "4-execute", # coding-scoped: rollout evidence is limited to coding execute
          attempt_id: attempt.attempt_id,
          task_generation: task_generation,
          ownership_generation: attempt.ownership_generation,
          commit_generation: commit_generation,
          reason: marker_action == condition_action ? "shadow_match" : "shadow_mismatch",
          evidence: [],
          provenance: { "source" => "shadow_evaluator" },
          payload: {
            "category" => category,
            "marker_action" => marker_action,
            "condition_action" => condition_action,
            "match" => marker_action == condition_action,
            "explained" => explained == true
          }
        }
      end

      def summary(records:, allow_list: [], fixture_status: {})
        audits = records.select { |record| record["event_type"] == "shadow_audit" }
        categories = CATEGORIES.to_h do |category|
          [ category, audits.count { |record| record.dig("payload", "category") == category } ]
        end
        mismatches = audits.reject { |record| record.dig("payload", "match") == true }
        unexplained = mismatches.reject { |record| record.dig("payload", "explained") == true }
        fixtures = fixture_status.to_h.transform_keys(&:to_s)
        parity_ready = audits.size >= MINIMUM_TRANSITIONS &&
                       categories.values.all?(&:positive?) &&
                       unexplained.empty? &&
                       allow_list.empty?
        fixture_ready = !fixtures.empty? && fixtures.values.all? { |value| value == true }
        {
          "total_transitions" => audits.size,
          "categories" => categories,
          "explained_mismatches" => mismatches.size - unexplained.size,
          "unexplained_mismatches" => unexplained.size,
          "allow_list" => allow_list,
          "fixtures" => fixtures,
          "parity_ready" => parity_ready,
          "external_fixture_evidence_required" => fixtures.empty?,
          "ready" => parity_ready && fixture_ready,
          "automatic_promotion" => false
        }
      end
    end
  end
end
