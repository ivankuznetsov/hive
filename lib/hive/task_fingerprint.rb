require "digest"
require "json"

module Hive
  module TaskFingerprint
    VERSION = "tfp1".freeze
    CARD_VERSION = "card1".freeze
    SEMANTIC_KEYS = %i[
      stage workflow marker_name marker_attrs depends_on task_generation
      condition_task_generation commit_generation condition_gate
      implementation_identity
    ].freeze
    CARD_VOLATILE_KEYS = %w[age_seconds card_digest].freeze

    module_function

    def for_row(row)
      payload = SEMANTIC_KEYS.to_h { |key| [ key.to_s, row[key] ] }
      "#{VERSION}:#{::Digest::SHA256.hexdigest(JSON.generate(canonical(payload)))}"
    end

    def card_digest(card)
      stable = card.reject { |key, _| CARD_VOLATILE_KEYS.include?(key.to_s) }
      "#{CARD_VERSION}:#{::Digest::SHA256.hexdigest(JSON.generate(canonical(stable)))}"
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
        value
      end
    end
  end
end
