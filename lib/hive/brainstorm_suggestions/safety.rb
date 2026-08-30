# frozen_string_literal: true

require "hive/secret_patterns"

module Hive
  module BrainstormSuggestions
    # One admission policy shared by provider validation and persisted-state
    # validation. Re-reading a hand-edited sidecar must never be a weaker path
    # to actionable text than accepting the original provider result.
    module Safety
      UNSAFE_MARKUP_RE = %r{(?:```|~~~|</?[A-Za-z][^>]*>|<!--|\[[^\]]+\]\([^\)]+\))}.freeze
      UNSAFE_STRUCTURE_RE = /\A\s*(?:\#{1,6}\s|[-*+]\s|\d+\.\s|>|\|)/.freeze
      PROMPT_CONTROL_RE = /(?:ignore\s+(?:all|any|the|previous)|system\s+prompt|developer\s+message|assistant\s*:|tool[_ -]?call|execute\s+(?:this|the)\s+command)/i.freeze
      CONTROL_RE = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.freeze

      module_function

      def safe_text?(value)
        return false unless value.is_a?(String) && value.valid_encoding?
        return false if value.strip.empty? || value.length > MAX_TEXT_CHARACTERS
        return false if value.lines.length > MAX_TEXT_LINES

        safe_content?(value)
      end

      def safe_rationale?(value)
        return false unless value.is_a?(String) && value.valid_encoding?
        return false if value.strip.empty? || value.length > MAX_RATIONALE_CHARACTERS
        return false if value.lines.length > 3

        safe_content?(value)
      end

      def safe_content?(value)
        !value.match?(CONTROL_RE) &&
          !value.match?(UNSAFE_MARKUP_RE) &&
          value.lines.none? { |line| line.match?(UNSAFE_STRUCTURE_RE) } &&
          !value.match?(PROMPT_CONTROL_RE) &&
          !Hive::SecretPatterns.match?(value)
      end
    end
  end
end
