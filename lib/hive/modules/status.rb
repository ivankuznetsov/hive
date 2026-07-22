require "hive/stringify_keys"

module Hive
  module Modules
    # Immutable, already-redacted projection shared by CLI and Web. Consumers
    # do not receive raw configuration files, environment values, diagnostics,
    # stderr, or logs and therefore do not need to implement their own safety
    # filtering.
    class Status
      LIFECYCLE_STATES = %w[
        active activating corrupt disabled failed_activation uninstalled_history
      ].freeze

      attr_reader :data

      def initialize(data)
        @data = Hive::StringifyKeys.call(data)
        validate!
        deep_freeze(@data)
        freeze
      end

      def to_h = Hive::StringifyKeys.call(data)
      def [](key) = data[key.to_s]
      def fetch(key, *args, &block) = data.fetch(key.to_s, *args, &block)
      def dig(*keys) = data.dig(*keys.map(&:to_s))

      def self.corrupt(name:, generated_at:, failure_reason: "state_corrupt")
        new(
          "name" => name.to_s, "lifecycle_state" => "corrupt",
          "installed" => nil, "enabled" => nil, "epoch" => nil,
          "high_water_at" => nil, "generated_at" => generated_at,
          "active" => nil, "previous" => nil,
          "integrity" => {
            "configuration_valid" => false, "generation_present" => false,
            "activation_fenced" => false, "journal_present" => false
          },
          "settings" => [], "grants" => nil, "grant_digest" => nil,
          "hooks" => [], "latest_decision" => nil, "latest_attempt" => nil,
          "retry" => nil, "artifacts" => [], "failure_reason" => failure_reason,
          "history_available" => true
        )
      end

      private

      def validate!
        expected = %w[
          active artifacts enabled epoch failure_reason generated_at grant_digest grants
          high_water_at history_available hooks installed integrity latest_attempt
          latest_decision lifecycle_state name previous retry settings
        ]
        unless data.keys.sort == expected && !data.fetch("name").empty? &&
               LIFECYCLE_STATES.include?(data.fetch("lifecycle_state")) &&
               data.fetch("hooks").is_a?(Array) && data.fetch("settings").is_a?(Array) &&
               data.fetch("artifacts").is_a?(Array)
          raise Hive::ConfigError, "module status projection is malformed"
        end
      end

      def deep_freeze(value)
        case value
        when Hash then value.each { |key, child| key.freeze; deep_freeze(child) }.freeze
        when Array then value.each { |child| deep_freeze(child) }.freeze
        else value.freeze
        end
      end
    end
  end
end
