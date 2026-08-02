require "json"
module HiveLiveAgentProof
  module WorkflowCreator
    class Error < StandardError; end
    module Primitives
      SECRET_PATTERNS = [ /sk-ant-[A-Za-z0-9_-]{12,}/, /sk-(?:proj-)?[A-Za-z0-9_-]{20,}/, /gh[opsu]_[A-Za-z0-9]{20,}/,
        /github_pat_[A-Za-z0-9_]{20,}/, /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/ ].freeze
      MAX_JSON_DEPTH, MAX_JSON_NODES, MAX_JSON_BYTES, MAX_JSON_INTEGER_BITS = 64, 16_384, 16_777_216, 55_732_703
      RAW_CLASS, RAW_SINGLETON_METHODS = %i[class singleton_methods].map { |name| Object.instance_method(name).freeze }
      PLAIN = ->(value, type) { RAW_CLASS.bind_call(value).equal?(type) && RAW_SINGLETON_METHODS.bind_call(value, false).empty? }.freeze
      module_function
      def canonical_json(value)
        nodes = projected = 0
        add = ->(size) { (projected += size) <= MAX_JSON_BYTES || raise(TypeError) }
        string_size = lambda do |string|
          PLAIN.call(string, String) && string.valid_encoding? && (string.encoding == Encoding::UTF_8 || string.ascii_only?) &&
            string.bytesize + 2 <= MAX_JSON_BYTES || raise(TypeError)
          string.bytesize + 2 + string.count(%Q("\\\b\f\n\r\t)) + string.count("\\") + (5 * string.count("\x00-\x07\x0B\x0E-\x1F"))
        end
        normalize = lambda do |nested, depth|
          depth <= MAX_JSON_DEPTH && (nodes += 1) <= MAX_JSON_NODES || raise(TypeError)
          [ Hash, Array, String, Integer, Float, TrueClass, FalseClass, NilClass ].any? { |type| PLAIN.call(nested, type) } || raise(TypeError)
          case nested
          when Hash
            count = nested.length; nodes + count <= MAX_JSON_NODES || raise(TypeError)
            add.call({ true => 2, false => 4 + (2 * depth) + (2 * (count - 1)) }.fetch(count.zero?))
            key_sizes = nested.each_key.to_h do |key|
              size = string_size.call(key); add.call((2 * (depth + 1)) + size + 2); [ key.encode(Encoding::UTF_8), key ]
            end.tap { |sizes| sizes.length == count || raise(TypeError) }
            key_sizes.keys.sort.to_h { |key| [ key, normalize.call(nested.fetch(key_sizes.fetch(key)), depth + 1) ] }
          when Array
            add.call({ true => 2, false => 4 + (2 * depth) + (2 * (nested.length - 1)) }.fetch(nested.empty?))
            nested.map { |item| add.call(2 * (depth + 1)).then { normalize.call(item, depth + 1) } }
          when String then add.call(string_size.call(nested)).then { nested.encode(Encoding::UTF_8) }
          when Integer then (nested.bit_length <= MAX_JSON_INTEGER_BITS || raise(TypeError)) && add.call(nested.to_s.bytesize).then { nested }
          when Float then (nested.finite? || raise(TypeError)) && add.call(JSON.generate(nested).bytesize).then { nested }
          else add.call({ true => 4, false => 5, nil => 4 }.fetch(nested)).then { nested }
          end
        end
        normalize.call(value, 0).then { |normalized|
          add.call(1).then { "#{JSON.pretty_generate(normalized)}\n".tap { |bytes| bytes.bytesize == projected || raise(TypeError) } } }
      rescue JSON::GeneratorError, JSON::NestingError, ArgumentError, EncodingError, TypeError
        raise Error, "cannot canonicalize JSON"
      end
      def safe_relative_path?(value)
        return false unless PLAIN.call(value, String) && value.valid_encoding? && (value.encoding == Encoding::UTF_8 || value.ascii_only?)
        value = value.encode(Encoding::UTF_8)
        !value.match?(%r{\A/|\A[A-Za-z]:|\x00|\\|(?:\A|/)\.{0,2}(?=/|\z)})
      end
      def secret_findings(text, exact_secrets: [])
        inspected = text.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
        findings = SECRET_PATTERNS.filter_map { |pattern| "pattern:#{pattern.source}" if pattern.match?(inspected) }
        exact_secrets.each_with_index { |secret, index| findings << "exact-secret:#{index}" if !secret.empty? && inspected.include?(secret) }
        findings
      end
      def secret_safe_text(value, exact_secrets:, limit:, input_limit:)
        value.instance_of?(String) && value.bytesize <= input_limit || raise(TypeError)
        text = value.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "\uFFFD")
        ranges, append = [], ->(range) { ranges.length < input_limit && ranges << range || raise(TypeError) }
        exact_secrets.each do |secret|
          text.scan(/(?=#{Regexp.escape(secret)})/) { Regexp.last_match.bytebegin(0).then { |at| append.call([ at, at + secret.bytesize ]) } }
        end
        SECRET_PATTERNS.each { |pattern| text.scan(pattern) { append.call([ Regexp.last_match.bytebegin(0), Regexp.last_match.byteend(0) ]) } }
        merged = ranges.sort_by!(&:first).each_with_object([]) do |range, union|
          current = union.last
          current && range.first <= current.last ? current[1] = [ current.last, range.last ].max : union << range.dup
        end
        redacted, cursor = +"", 0
        merged.each { |first, last| cursor = (redacted << text.byteslice(cursor, first - cursor) << "[REDACTED]" && last) }
        redacted << text.byteslice(cursor, text.bytesize - cursor)
        redacted.byteslice(0, limit).force_encoding(Encoding::UTF_8).scrub("")
      end
      def deep_freeze(value)
        value.each { |key, nested| deep_freeze(key); deep_freeze(nested) } if value.is_a?(Hash)
        value.each { |nested| deep_freeze(nested) } if value.is_a?(Array)
        value.freeze
      end
    end
  end
end
