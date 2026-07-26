require "hive/stringify_keys"
require "hive/module_package/manifest"

module Hive
  module Modules
    # Immutable, already-redacted projection shared by CLI and Web. Consumers
    # do not receive raw configuration files, environment values, diagnostics,
    # stderr, or logs and therefore do not need to implement their own safety
    # filtering.
    class Status
      MAX_ROWS = 100
      MAX_STRING_BYTES = 4096
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
        validate_scalar_fields!
        validate_integrity!
        validate_settings!
        validate_grants!
        validate_hooks!
        validate_summary!("latest_decision", %w[
          attempt_id binding_digest cursor_after cursor_before decision_id
          evaluated_at event_id event_name hook outcome reason
        ])
        validate_summary!("latest_attempt", %w[
          attempt_id created_at ended_at event_id hook outcome retry_charge started_at state
        ])
        validate_retry!
        validate_artifacts!
      rescue NoMethodError, TypeError
        raise Hive::ConfigError, "module status projection is malformed"
      end

      def validate_scalar_fields!
        string!("name", data.fetch("name"))
        string!("generated_at", data.fetch("generated_at"))
        nullable_string!("high_water_at", data["high_water_at"])
        nullable_string!("grant_digest", data["grant_digest"], pattern: /\A[0-9a-f]{64}\z/)
        nullable_string!("failure_reason", data["failure_reason"])
        unless [ true, false, nil ].include?(data["installed"]) &&
               [ true, false, nil ].include?(data["enabled"]) &&
               (data["epoch"].nil? || data["epoch"].is_a?(Integer) && data["epoch"].positive?) &&
               [ true, false ].include?(data["history_available"])
          malformed!
        end
        %w[active previous].each do |key|
          generation = data[key]
          next if generation.nil?
          malformed! unless generation.is_a?(Hash) && generation.length <= 10
          generation.each do |field, value|
            string!(field, field)
            nullable_string!(field, value)
          end
        end
      end

      def validate_integrity!
        integrity = data.fetch("integrity")
        expected = %w[
          activation_fenced configuration_valid generation_present journal_present
        ]
        unless integrity.is_a?(Hash) && integrity.keys.sort == expected &&
               integrity.values.all? { |value| [ true, false ].include?(value) }
          malformed!
        end
      end

      def validate_settings!
        malformed! if data.fetch("settings").length > MAX_ROWS
        expected = %w[available binding name required secret type value]
        data.fetch("settings").each do |row|
          unless row.is_a?(Hash) && row.keys.sort == expected &&
                 [ true, false ].include?(row["required"]) &&
                 [ true, false ].include?(row["secret"]) &&
                 [ true, false, nil ].include?(row["available"])
            malformed!
          end
          string!("setting name", row["name"])
          string!("setting type", row["type"])
          nullable_string!("secret binding", row["binding"])
          value = row["value"]
          malformed! unless value.nil? || value.is_a?(String) || value.is_a?(Numeric) ||
                            [ true, false ].include?(value)
          string!("setting value", value) if value.is_a?(String)
        end
      end

      def validate_grants!
        grants = data["grants"]
        return if grants.nil?
        expected = Hive::ModulePackage::Manifest::PERMISSION_KEYS
        unless grants.is_a?(Hash) && grants.keys.sort == expected.sort &&
               [ true, false ].include?(grants["repository_write"])
          malformed!
        end
        expected.grep_v("repository_write").each do |key|
          values = grants[key]
          unless values.is_a?(Array) && values.length <= MAX_ROWS &&
                 values.uniq == values
            malformed!
          end
          values.each { |value| string!("grant", value) }
        end
      end

      def validate_hooks!
        malformed! if data.fetch("hooks").length > MAX_ROWS
        expected = %w[
          binding_digest concurrency cursor enabled event_bindings id
          next_trigger_at schedules target
        ]
        data.fetch("hooks").each do |row|
          unless row.is_a?(Hash) && row.keys.sort == expected &&
                 [ true, false ].include?(row["enabled"]) &&
                 row["target"].is_a?(Hash) &&
                 row["target"].keys.sort == %w[id kind] &&
                 row["schedules"].is_a?(Array) &&
                 row["event_bindings"].is_a?(Array)
            malformed!
          end
          %w[id concurrency].each { |key| string!("hook #{key}", row[key]) }
          %w[binding_digest cursor next_trigger_at].each do |key|
            nullable_string!("hook #{key}", row[key])
          end
          %w[id kind].each { |key| string!("hook target #{key}", row.dig("target", key)) }
          (row["schedules"] + row["event_bindings"]).each { |value| string!("hook binding", value) }
        end
      end

      def validate_summary!(key, expected)
        value = data[key]
        return if value.nil?
        malformed! unless value.is_a?(Hash) && value.keys.sort == expected
        value.each_value do |child|
          next if child.nil? || child.is_a?(Integer)
          string!(key, child)
        end
      end

      def validate_retry!
        retry_state = data["retry"]
        return if retry_state.nil?
        unless retry_state.is_a?(Hash) &&
               retry_state.keys.sort == %w[charge max reason status] &&
               %w[closed complete exhausted finished pending retrying unknown].include?(
                 retry_state["status"]
               ) &&
               %w[charge max].all? do |key|
                 retry_state[key].nil? ||
                   retry_state[key].is_a?(Integer) && retry_state[key] >= 0
               end &&
               [ nil, "retry_closed" ].include?(retry_state["reason"])
          malformed!
        end
      end

      def validate_artifacts!
        malformed! if data.fetch("artifacts").length > 50
        data.fetch("artifacts").each do |row|
          unless row.is_a?(Hash) && row.keys.sort == %w[path sha256 size] &&
                 row["size"].is_a?(Integer) && row["size"] >= 0 &&
                 row["sha256"].to_s.match?(/\A[0-9a-f]{64}\z/)
            malformed!
          end
          string!("artifact path", row["path"])
        end
      end

      def nullable_string!(label, value, pattern: nil)
        return if value.nil?
        string!(label, value, pattern: pattern)
      end

      def string!(_label, value, pattern: nil)
        unless value.is_a?(String) && !value.empty? &&
               value.bytesize <= MAX_STRING_BYTES &&
               (pattern.nil? || pattern.match?(value))
          malformed!
        end
      end

      def malformed!
        raise Hive::ConfigError, "module status projection is malformed"
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
