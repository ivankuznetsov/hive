require "digest"
require "yaml"

module Hive
  module WorkflowPackage
    class LintPolicy
      VERSION = "v1".freeze
      PINNED_COMMIT = "ada805d0d8c94dc236a0673a22232a0440843cf0".freeze
      UPSTREAM_POLICY_SHA256 = "abb0d43bf30e683413e38060f5416e9ece370b98eba9c836a7c56ebbcdd765fa".freeze
      PATH = File.expand_path("../../../config/honeycomb-security-lint/v1.yml", __dir__).freeze
      CONTRACT_SHA256 = "9a8f3bf9e2632924e07a032e6138d4f19bee5baf32f9f4916b5419e588836d6b".freeze
      KEYS = %w[
        schema version upstream_commit upstream_policy_sha256 fixture_corpus_sha256
        expected_output_sha256 baseline_network_hosts limits known_rules
      ].freeze
      LIMIT_KEYS = %w[max_file_bytes max_total_bytes max_files max_findings].freeze
      SHA256 = /\A[0-9a-f]{64}\z/

      Policy = Data.define(:version, :upstream_commit, :contract_sha256, :limits, :known_rules, :baseline_network_hosts) do
        def identity
          {
            "version" => version,
            "upstream_commit" => upstream_commit,
            "contract_sha256" => contract_sha256
          }.freeze
        end
      end

      def self.load(path: PATH, expected_sha256: CONTRACT_SHA256)
        bytes = File.binread(path)
        digest = Digest::SHA256.hexdigest(bytes)
        unless SHA256.match?(expected_sha256.to_s) && secure_equal?(digest, expected_sha256)
          raise Hive::ConfigError, "Honeycomb lint policy integrity check failed"
        end
        data = YAML.safe_load(bytes, permitted_classes: [], permitted_symbols: [], aliases: false)
        validate!(data)
        Policy.new(
          version: data.fetch("version"), upstream_commit: data.fetch("upstream_commit"),
          contract_sha256: digest, limits: data.fetch("limits").freeze,
          known_rules: data.fetch("known_rules").freeze,
          baseline_network_hosts: data.fetch("baseline_network_hosts").freeze
        ).freeze
      rescue Psych::Exception, Errno::ENOENT, Errno::EACCES, IOError
        raise Hive::ConfigError, "Honeycomb lint policy is missing, unreadable, or malformed"
      end

      def self.validate!(data)
        unless data.is_a?(Hash) && data.keys.sort == KEYS.sort &&
               data["schema"] == "hive.honeycomb-security-lint-contract/v1" &&
               data["version"] == VERSION && data["upstream_commit"] == PINNED_COMMIT &&
               data["upstream_policy_sha256"] == UPSTREAM_POLICY_SHA256
          raise Hive::ConfigError, "Honeycomb lint policy identity is unsupported"
        end
        %w[fixture_corpus_sha256 expected_output_sha256].each do |key|
          raise Hive::ConfigError, "Honeycomb lint policy checksum is malformed" unless SHA256.match?(data[key].to_s)
        end
        limits = data["limits"]
        unless limits.is_a?(Hash) && limits.keys.sort == LIMIT_KEYS.sort && limits.values.all? { |value| value.is_a?(Integer) && value.positive? }
          raise Hive::ConfigError, "Honeycomb lint policy limits are malformed"
        end
        hosts = data["baseline_network_hosts"]
        rules = data["known_rules"]
        unless hosts.is_a?(Array) && hosts == hosts.sort.uniq && hosts.all? { |host| host.is_a?(String) && !host.empty? } &&
               rules.is_a?(Array) && rules == rules.sort.uniq && rules.all? { |rule| rule.is_a?(String) && !rule.empty? }
          raise Hive::ConfigError, "Honeycomb lint policy sets are malformed"
        end
      end
      private_class_method :validate!

      def self.secure_equal?(left, right)
        left.bytesize == right.bytesize &&
          left.bytes.zip(right.bytes).reduce(0) { |memo, (a, b)| memo | (a ^ b) }.zero?
      end
      private_class_method :secure_equal?
    end
  end
end
