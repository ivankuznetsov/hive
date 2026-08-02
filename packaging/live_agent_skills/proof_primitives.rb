require "json"
module HiveLiveAgentProof
  module WorkflowCreator
    class Error < StandardError; end
    module Primitives
      SECRET_PATTERNS = [
        /sk-ant-[A-Za-z0-9_-]{12,}/, /sk-(?:proj-)?[A-Za-z0-9_-]{20,}/,
        /gh[opsu]_[A-Za-z0-9]{20,}/, /github_pat_[A-Za-z0-9_]{20,}/,
        /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/
      ].freeze
      MAX_JSON_DEPTH = 64
      MAX_JSON_NODES = 16_384
      MAX_JSON_BYTES = 16_777_216
      module_function
      def canonical_json(value)
        nodes = payload_bytes = 0
        normalize = lambda do |nested, depth|
          raise TypeError if depth > MAX_JSON_DEPTH || (nodes += 1) > MAX_JSON_NODES
          case nested
          when Hash
            raise TypeError unless nested.keys.all? do |key|
              key.is_a?(String) && key.valid_encoding? && (payload_bytes += key.bytesize) <= MAX_JSON_BYTES
            end
            nested.keys.sort.to_h { |key| [ key, normalize.call(nested.fetch(key), depth + 1) ] }
          when Array
            nested.map { |item| normalize.call(item, depth + 1) }
          when String
            raise TypeError unless nested.valid_encoding? && (payload_bytes += nested.bytesize) <= MAX_JSON_BYTES
            nested
          when Integer, Float, TrueClass, FalseClass, NilClass
            nested
          else
            raise TypeError
          end
        end
        bytes = "#{JSON.pretty_generate(normalize.call(value, 0))}\n"
        raise TypeError if bytes.bytesize > MAX_JSON_BYTES
        bytes
      rescue JSON::GeneratorError, JSON::NestingError, ArgumentError, TypeError
        raise Error, "cannot canonicalize JSON"
      end
      def safe_relative_path?(value)
        return false unless value.is_a?(String) && !value.empty? && value.valid_encoding?
        return false if value.start_with?("/") || value.match?(/\A[A-Za-z]:/) || value.include?("\0") || value.include?("\\")
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
