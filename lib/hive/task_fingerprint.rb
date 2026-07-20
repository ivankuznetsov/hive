require "digest"
require "json"

module Hive
  module TaskFingerprint
    VERSION = "tfp1".freeze
    CARD_VERSION = "card1".freeze
    WORKFLOW_VERSION = "wf1".freeze
    SEMANTIC_KEYS = %i[
      stage workflow workflow_semantics marker_name marker_attrs depends_on task_generation
      condition_task_generation commit_generation condition_gate
      implementation_identity
    ].freeze
    # Only fields that can alter a rendered card, its board membership/order,
    # or a card-driven transition belong in the live-update digest. Full task
    # projections carry condition history and evidence for the detail drawer;
    # serialising those large, card-invisible structures on every board poll
    # makes targeted broadcasts scale with detail history rather than cards.
    CARD_SEMANTIC_KEYS = %w[
      slug id display_name stage workflow marker attrs mtime folder_mtime pr_url
      action action_label dominant_state state_rank fingerprint
      allowed_transitions depends_on blocked_by blocked admission_error
      implementation_identity operational_chips queued_request lock dependency
    ].freeze

    module_function

    def for_row(row)
      payload = SEMANTIC_KEYS.to_h { |key| [ key.to_s, row[key] ] }
      "#{VERSION}:#{::Digest::SHA256.hexdigest(JSON.generate(canonical(payload)))}"
    end

    def card_digest(card)
      stable = card.to_h.select { |key, _| CARD_SEMANTIC_KEYS.include?(key.to_s) }
      "#{CARD_VERSION}:#{::Digest::SHA256.hexdigest(JSON.generate(canonical(stable)))}"
    end

    # A workflow id is only a selector. Project overlays can replace the
    # descriptor behind that id without changing the task metadata, altering
    # stage verbs, gates, runners, or conditions while a rendered card is still
    # in flight. Include a digest of the fully resolved descriptor shape in the
    # mutation fingerprint so same-id semantic changes make stale clients fail
    # without copying and canonicalising the full descriptor for every card.
    def workflow_semantics(workflow)
      return nil unless workflow

      descriptor = canonical(
        "id" => workflow.id,
        "dependency_gate_stage" => workflow.dependency_gate_stage,
        "stages" => workflow.stages.map(&:to_h)
      )
      "#{WORKFLOW_VERSION}:#{::Digest::SHA256.hexdigest(JSON.generate(descriptor))}"
    end

    def canonical(value)
      case value
      when Hash
        value.to_h.transform_keys(&:to_s).sort.to_h.transform_values { |item| canonical(item) }
      when Array
        value.map { |item| canonical(item) }
      when Time
        value.utc.iso8601(6)
      when Symbol
        value.to_s
      else
        return canonical(value.to_h) if value.respond_to?(:to_h)

        value
      end
    end
  end
end
