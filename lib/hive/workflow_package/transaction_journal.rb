require "base64"
require "json"
require "fileutils"
require "hive/atomic_file"
require "hive/workflow_package/canonical_json"

module Hive
  module WorkflowPackage
    class TransactionJournal
      BINARY_MARKER = "__binary__"

      attr_reader :path

      def initialize(workflows_dir)
        @path = File.join(workflows_dir, ".transaction.json")
      end

      def write(data)
        Hive::AtomicFile.write(path, CanonicalJSON.generate(encode(data)), mode: 0o600)
      end

      def read
        decode(JSON.parse(File.read(path)))
      rescue Errno::ENOENT
        nil
      rescue JSON::ParserError
        raise Hive::ConfigError, "managed workflow transaction journal is malformed"
      end

      def clear
        FileUtils.rm_f(path)
      end

      private

      # Raw lock bytes read with File.binread are opaque ASCII-8BIT payloads;
      # canonical JSON only accepts valid, normalized UTF-8 text. Wrap such
      # strings in a base64 envelope so journal round-trips preserve them.
      def encode(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, child), out| out[key] = encode(child) }
        when Array
          value.map { |child| encode(child) }
        when String
          opaque_binary?(value) ? {BINARY_MARKER => Base64.strict_encode64(value)} : value
        else
          value
        end
      end

      def decode(value)
        case value
        when Hash
          return Base64.strict_decode64(value.fetch(BINARY_MARKER)).b if binary_envelope?(value)

          value.each_with_object({}) { |(key, child), out| out[key] = decode(child) }
        when Array
          value.map { |child| decode(child) }
        else
          value
        end
      end

      def binary_envelope?(value)
        value.size == 1 && value.key?(BINARY_MARKER)
      end

      def opaque_binary?(value)
        !value.encoding.equal?(Encoding::UTF_8) && !value.ascii_only?
      end
    end
  end
end
