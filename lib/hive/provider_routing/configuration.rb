require "hive/provider_routing"
require "hive/agent_profiles"

module Hive
  module ProviderRouting
    class Configuration
      Resolved = Data.define(:accounts, :pool, :required, :pin)

      attr_reader :accounts, :pool, :required, :pin

      class << self
        def from(cfg:, stage_name:, descriptor: nil, routing: nil,
                 agent: nil, model: nil, effort: nil, source: nil)
          cfg ||= {}
          accounts = cfg[PROVIDER_ACCOUNTS_KEY] || ProviderRouting.default_accounts
          stage_cfg = hash_at(cfg, stage_name)
          routing ||= stage_cfg["routing"] || descriptor&.routing
          source ||= "#{stage_name}.routing"

          legacy_agent = agent || descriptor&.agent || stage_cfg["agent"] || "claude"
          legacy_model = model || descriptor&.model
          legacy_effort = effort || descriptor&.effort
          if legacy_agent.to_s == "claude"
            legacy_model ||= cfg.dig("claude", "model")
            legacy_effort ||= cfg.dig("claude", "effort")
          end

          new(
            accounts: accounts,
            routing: routing,
            legacy: {
              "agent" => legacy_agent.to_s,
              "model" => blank_to_nil(legacy_model),
              "effort" => default_effort_to_nil(legacy_effort)
            },
            source: source
          )
        end

        # Direct AgentProfile extension points pre-date named provider config
        # and may pass an unregistered profile object. Preserve that public
        # contract through the same router as a validated pool of one; authored
        # YAML still goes through #from and therefore still rejects unknown
        # adapters.
        def single(provider:, agent:, model: nil, effort: nil, capabilities: DEFAULT_CAPABILITIES)
          provider = provider.to_s
          agent = agent.to_s
          account = Account.new(
            key: provider,
            adapter: agent,
            max_concurrent: nil,
            cooldown_sec: DEFAULT_COOLDOWNS,
            backoff_cap_sec: DEFAULT_BACKOFF_CAP_SEC
          )
          candidate = Candidate.new(
            provider: provider,
            agent: agent,
            model: model&.to_s,
            effort: effort&.to_s,
            capabilities: capabilities,
            order: 0
          )
          Resolved.new(
            accounts: { provider => account }.freeze,
            pool: [ candidate ].freeze,
            required: Requirements.new(context: nil, quality: nil, tools: [].freeze, permissions: [].freeze),
            pin: nil
          )
        end

        def normalize_accounts(raw, source:)
          unless raw.is_a?(Hash)
            raise ConfigError, "providers in #{source} must be a Hash; got #{raw.class}"
          end

          raw.each_with_object({}) do |(key, value), out|
            path = "providers.#{key}"
            provider = nonempty_string(key, "#{path} key")
            config = stringify_hash(value, path)
            unknown = config.keys - %w[adapter max_concurrent cooldown_sec backoff_cap_sec]
            reject_unknown!(unknown, path)
            adapter = nonempty_string(config["adapter"], "#{path}.adapter")
            unless Hive::AgentProfiles.registered?(adapter)
              raise ConfigError,
                    "#{path}.adapter #{adapter.inspect} is not a registered AgentProfile " \
                    "(registered: #{Hive::AgentProfiles.registered_names.inspect})"
            end

            max_concurrent = optional_positive_integer(config["max_concurrent"], "#{path}.max_concurrent")
            cap = config.key?("backoff_cap_sec") ?
              positive_integer(config["backoff_cap_sec"], "#{path}.backoff_cap_sec") : DEFAULT_BACKOFF_CAP_SEC
            cooldowns = normalize_cooldowns(config["cooldown_sec"], path)
            out[provider] = Account.new(
              key: provider,
              adapter: adapter,
              max_concurrent: max_concurrent,
              cooldown_sec: cooldowns.freeze,
              backoff_cap_sec: cap
            )
          end.freeze
        end

        # Descriptor parsing has no project/global config available. Validate
        # the closed routing vocabulary and adapter shape now, then resolve
        # provider references against the real account registry at Config.load
        # or dispatch time.
        def validate_routing_shape!(raw, source:)
          return nil if raw.nil?

          routing = stringify_hash(raw, source)
          reject_unknown!(routing.keys - ROUTING_KEYS, source)
          if routing.key?("pool")
            pool = routing["pool"]
            raise ConfigError, "#{source}.pool must be a non-empty Array" unless pool.is_a?(Array) && !pool.empty?

            pool.each_with_index do |candidate, index|
              entry = stringify_hash(candidate, "#{source}.pool[#{index}]")
              reject_unknown!(entry.keys - CANDIDATE_KEYS, "#{source}.pool[#{index}]")
              nonempty_string(entry["provider"], "#{source}.pool[#{index}].provider")
              validate_adapter!(entry["agent"], "#{source}.pool[#{index}].agent") if entry.key?("agent")
              optional_nonempty_string(entry["model"], "#{source}.pool[#{index}].model")
              optional_nonempty_string(entry["effort"], "#{source}.pool[#{index}].effort")
              normalize_capabilities(entry["capabilities"], "#{source}.pool[#{index}].capabilities")
            end
          end
          normalize_requirements(routing["required"], "#{source}.required")
          normalize_pin(routing["pin"], "#{source}.pin")
          deep_freeze(deep_dup(routing))
        end

        private

        def hash_at(cfg, stage_name)
          value = cfg[stage_name.to_s]
          value.is_a?(Hash) ? value : {}
        end

        def normalize_cooldowns(raw, path)
          return DEFAULT_COOLDOWNS.dup if raw.nil?

          value = stringify_hash(raw, "#{path}.cooldown_sec")
          reject_unknown!(value.keys - TIMED_FAILURE_CLASSES, "#{path}.cooldown_sec")
          DEFAULT_COOLDOWNS.merge(
            value.to_h { |klass, seconds| [ klass, positive_integer(seconds, "#{path}.cooldown_sec.#{klass}") ] }
          )
        end

        def normalize_capabilities(raw, path)
          value = raw.nil? ? {} : stringify_hash(raw, path)
          reject_unknown!(value.keys - CAPABILITY_KEYS, path)
          {
            "context" => level(value["context"] || DEFAULT_CAPABILITIES["context"], CONTEXT_LEVELS, "#{path}.context"),
            "quality" => level(value["quality"] || DEFAULT_CAPABILITIES["quality"], QUALITY_LEVELS, "#{path}.quality"),
            "tools" => string_set(value.fetch("tools", DEFAULT_CAPABILITIES["tools"]), "#{path}.tools"),
            "permissions" => string_set(value.fetch("permissions", DEFAULT_CAPABILITIES["permissions"]), "#{path}.permissions")
          }.freeze
        end

        def normalize_requirements(raw, path)
          value = raw.nil? ? {} : stringify_hash(raw, path)
          reject_unknown!(value.keys - CAPABILITY_KEYS, path)
          Requirements.new(
            context: value.key?("context") ? level(value["context"], CONTEXT_LEVELS, "#{path}.context") : nil,
            quality: value.key?("quality") ? level(value["quality"], QUALITY_LEVELS, "#{path}.quality") : nil,
            tools: value.key?("tools") ? string_set(value["tools"], "#{path}.tools") : [].freeze,
            permissions: value.key?("permissions") ? string_set(value["permissions"], "#{path}.permissions") : [].freeze
          )
        end

        def normalize_pin(raw, path)
          return nil if raw.nil?

          value = stringify_hash(raw, path)
          reject_unknown!(value.keys - PIN_KEYS, path)
          Pin.new(
            provider: nonempty_string(value["provider"], "#{path}.provider"),
            model: optional_nonempty_string(value["model"], "#{path}.model")
          )
        end

        def level(value, allowed, path)
          token = nonempty_string(value, path)
          return token if allowed.include?(token)

          raise ConfigError, "#{path} must be one of #{allowed.inspect}; got #{token.inspect}"
        end

        def string_set(value, path)
          raise ConfigError, "#{path} must be an Array of non-empty strings" unless value.is_a?(Array)

          values = value.map.with_index { |entry, i| nonempty_string(entry, "#{path}[#{i}]") }
          raise ConfigError, "#{path} contains duplicate values" unless values.uniq.length == values.length

          values.freeze
        end

        def validate_adapter!(value, path)
          adapter = nonempty_string(value, path)
          return adapter if Hive::AgentProfiles.registered?(adapter)

          raise ConfigError,
                "#{path} #{adapter.inspect} is not a registered AgentProfile " \
                "(registered: #{Hive::AgentProfiles.registered_names.inspect})"
        end

        def stringify_hash(value, path)
          raise ConfigError, "#{path} must be a Hash; got #{value.class}" unless value.is_a?(Hash)

          value.each_with_object({}) do |(key, child), out|
            raise ConfigError, "#{path} contains non-string key #{key.inspect}" unless key.is_a?(String) || key.is_a?(Symbol)

            out[key.to_s] = child
          end
        end

        def reject_unknown!(unknown, path)
          return if unknown.empty?

          raise ConfigError, "#{path} contains unknown key(s) #{unknown.inspect}"
        end

        def nonempty_string(value, path)
          return value.strip if value.is_a?(String) && !value.strip.empty?
          return value.to_s if value.is_a?(Symbol)

          raise ConfigError, "#{path} must be a non-empty string"
        end

        def optional_nonempty_string(value, path)
          return nil if value.nil?

          nonempty_string(value, path)
        end

        def positive_integer(value, path)
          return value if value.is_a?(Integer) && value.positive?

          raise ConfigError, "#{path} must be a positive integer; got #{value.inspect}"
        end

        def optional_positive_integer(value, path)
          return nil if value.nil?

          positive_integer(value, path)
        end

        def blank_to_nil(value)
          value = value.to_s.strip unless value.nil?
          value.nil? || value.empty? || value == "inherit" ? nil : value
        end

        def default_effort_to_nil(value)
          value = blank_to_nil(value)
          %w[default inherit].include?(value) ? nil : value
        end

        def deep_dup(value)
          case value
          when Hash then value.to_h { |key, child| [ key, deep_dup(child) ] }
          when Array then value.map { |child| deep_dup(child) }
          else value
          end
        end

        def deep_freeze(value)
          case value
          when Hash then value.each { |key, child| key.freeze; deep_freeze(child) }
          when Array then value.each { |child| deep_freeze(child) }
          end
          value.freeze
        end
      end

      def initialize(accounts:, routing:, legacy:, source:)
        @accounts = accounts
        routing = self.class.validate_routing_shape!(routing, source: source) || {}
        @required = self.class.send(:normalize_requirements, routing["required"], "#{source}.required")
        @pin = self.class.send(:normalize_pin, routing["pin"], "#{source}.pin")
        @pool = if routing.key?("pool")
          normalize_pool(routing.fetch("pool"), source)
        else
          [ normalize_legacy(legacy, source) ].freeze
        end
        validate_pin!(source)
        freeze
      end

      private

      def normalize_pool(entries, source)
        pool = entries.each_with_index.map do |raw, index|
          path = "#{source}.pool[#{index}]"
          entry = self.class.send(:stringify_hash, raw, path)
          provider = self.class.send(:nonempty_string, entry["provider"], "#{path}.provider")
          account = accounts[provider]
          raise ConfigError, "#{path}.provider references unknown provider #{provider.inspect}" unless account

          agent = entry.key?("agent") ? entry["agent"] : account.adapter
          agent = self.class.send(:validate_adapter!, agent, "#{path}.agent")
          Candidate.new(
            provider: provider,
            agent: agent,
            model: self.class.send(:optional_nonempty_string, entry["model"], "#{path}.model"),
            effort: self.class.send(:optional_nonempty_string, entry["effort"], "#{path}.effort"),
            capabilities: self.class.send(:normalize_capabilities, entry["capabilities"], "#{path}.capabilities"),
            order: index
          )
        end
        duplicates = pool.group_by { |entry| [ entry.provider, entry.model ] }.select { |_key, values| values.length > 1 }.keys
        unless duplicates.empty?
          raise ConfigError, "#{source}.pool contains duplicate provider/model entry #{duplicates.first.inspect}"
        end
        pool.freeze
      end

      def normalize_legacy(legacy, source)
        agent = self.class.send(:validate_adapter!, legacy.fetch("agent"), "#{source}.legacy.agent")
        account = accounts[agent] || accounts.values.find { |entry| entry.adapter == agent }
        unless account
          raise ConfigError,
                "#{source} cannot synthesize legacy pool: no provider account maps to adapter #{agent.inspect}"
        end

        Candidate.new(
          provider: account.key,
          agent: agent,
          model: legacy["model"],
          effort: legacy["effort"],
          capabilities: DEFAULT_CAPABILITIES,
          order: 0
        )
      end

      def validate_pin!(source)
        return unless pin

        matched = pool.any? do |entry|
          entry.provider == pin.provider && (pin.model.nil? || entry.model == pin.model)
        end
        return if matched

        raise ConfigError, "#{source}.pin does not match an entry in #{source}.pool"
      end
    end
  end
end
