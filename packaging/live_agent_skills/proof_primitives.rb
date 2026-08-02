require "json"

module HiveLiveAgentProof
  module WorkflowCreator
    class Error < StandardError; end
    module Primitives
      SECRET_PATTERNS = [
        /sk-ant-[A-Za-z0-9_-]{12,}/,
        /sk-(?:proj-)?[A-Za-z0-9_-]{20,}/,
        /gh[opsu]_[A-Za-z0-9]{20,}/,
        /github_pat_[A-Za-z0-9_]{20,}/,
        /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/
      ].freeze

      module_function
      def canonical_json(value)
        normalize = lambda do |nested|
          case nested
          when Hash
            raise TypeError unless nested.keys.all?(String)
            nested.keys.sort.to_h { |key| [ key, normalize.call(nested.fetch(key)) ] }
          when Array
            nested.map { |item| normalize.call(item) }
          when String
            raise TypeError unless nested.valid_encoding?
            nested
          when Integer, Float, TrueClass, FalseClass, NilClass
            nested
          else
            raise TypeError
          end
        end
        "#{JSON.pretty_generate(normalize.call(value))}\n"
      rescue JSON::GeneratorError, ArgumentError, TypeError
        raise Error, "cannot canonicalize JSON"
      end
      def safe_relative_path?(value)
        return false unless value.is_a?(String) && !value.empty? && value.valid_encoding?
        return false if value.start_with?("/") || value.include?("\0")

        value.split("/", -1).none? { |part| part.empty? || part == "." || part == ".." }
      end
      def secret_findings(text, exact_secrets: [])
        inspected = text.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
        findings = SECRET_PATTERNS.filter_map do |pattern|
          "pattern:#{pattern.source}" if pattern.match?(inspected)
        end
        exact_secrets.each_with_index do |secret, index|
          candidate = secret.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
          findings << "exact-secret:#{index}" if !candidate.empty? && inspected.include?(candidate)
        end
        findings
      end

      def secret_safe_text(value, exact_secrets:, limit:)
        text = value.to_s.encode(
          Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "\uFFFD"
        )
        exact_secrets.each do |secret|
          candidate = secret.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
          text.gsub!(candidate, "[REDACTED]") unless candidate.empty?
        end
        SECRET_PATTERNS.each { |pattern| text.gsub!(pattern, "[REDACTED]") }
        text.byteslice(0, limit).force_encoding(Encoding::UTF_8).scrub("")
      end

      def deep_freeze(value)
        case value
        when Hash
          value.each { |key, nested| deep_freeze(key); deep_freeze(nested) }
        when Array
          value.each { |nested| deep_freeze(nested) }
        end
        value.freeze
      end
    end
  end
end
