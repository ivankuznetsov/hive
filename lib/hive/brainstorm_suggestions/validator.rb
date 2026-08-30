# frozen_string_literal: true

require "json"
require "hive/brainstorm_suggestions"

module Hive
  module BrainstormSuggestions
    # Converts one provider result into a closed, bounded controller result.
    # Raw rejected output is neither returned nor interpolated into reasons.
    module Validator
      RESULT_KEYS = %w[disposition text rationale provenance reason reason_code].freeze
      DISPOSITIONS = %w[suggestion no_safe_suggestion].freeze
      SAFE_REASONS = {
        "insufficient_evidence" => "No safe suggestion is available from the selected evidence.",
        "conflicting_evidence" => "The selected evidence does not support one safe suggestion.",
        "sensitive_context" => "Suggestion generation was suppressed because selected context is sensitive.",
        "unsafe_output" => "The generated candidate did not pass Hive's advisory safety checks."
      }.freeze
      class InvalidOutput < Error; end

      module_function

      def call(raw, manifest:)
        value = normalize(raw)
        unknown = value.keys - RESULT_KEYS
        raise InvalidOutput, "provider result has an unsupported shape" unless unknown.empty?
        disposition = value["disposition"]
        raise InvalidOutput, "provider result has an unsupported disposition" unless
          DISPOSITIONS.include?(disposition)

        return no_safe(value["reason_code"]) if disposition == "no_safe_suggestion"

        sources = manifest_sources(manifest)
        claims = value["provenance"]
        return no_safe("unsafe_output") unless
          claims.is_a?(Array) && !claims.empty? && claims.all? { |claim| sources.include?(claim) }

        text = canonical_text(value["text"])
        rationale = value["rationale"]
        return no_safe("unsafe_output") unless Safety.safe_text?(text)
        return no_safe("unsafe_output") unless Safety.safe_rationale?(rationale)

        {
          "state" => "fresh",
          "text" => text,
          "rationale" => rationale,
          "provenance" => sources,
          "safe_reason" => nil,
          "retryable" => true,
          "dismissed" => false
        }
      rescue JSON::ParserError, TypeError
        raise InvalidOutput, "provider result is not valid structured output"
      end

      def canonical_text(value)
        return value unless value.is_a?(String) && value.valid_encoding?
        return value if value.match?(Safety::BARE_CR_RE)

        value.gsub("\r\n", "\n").rstrip
      end
      private_class_method :canonical_text

      def normalize(raw)
        value = raw.is_a?(String) ? JSON.parse(raw) : raw
        raise InvalidOutput, "provider result must be an object" unless value.is_a?(Hash)

        value.to_h { |key, item| [ key.to_s, item ] }
      end
      private_class_method :normalize

      def manifest_sources(manifest)
        entries = manifest.is_a?(Hash) ? manifest["entries"] || manifest[:entries] : nil
        raise InvalidOutput, "bound manifest has no admitted sources" unless entries.is_a?(Array)

        sources = entries.filter_map do |entry|
          next unless entry.is_a?(Hash)

          source = entry["source"] || entry[:source]
          source if SOURCE_CLASSES.include?(source)
        end.uniq.sort
        raise InvalidOutput, "bound manifest has no admitted sources" if sources.empty?

        sources
      end
      private_class_method :manifest_sources

      def no_safe(reason_code)
        reason = SAFE_REASONS.fetch(reason_code.to_s, SAFE_REASONS.fetch("unsafe_output"))
        {
          "state" => "no_safe_suggestion",
          "text" => nil,
          "rationale" => nil,
          "provenance" => [],
          "safe_reason" => reason,
          "retryable" => true,
          "dismissed" => false
        }
      end
      private_class_method :no_safe
    end
  end
end
