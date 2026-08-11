require "hive/provider_routing"
require "hive/provider_routing/policy"
require "hive/agent_profiles"
require "hive/agent_profiles/launch_bindings"
require "hive/model_routing"

module Hive
  module ProviderRouting
    class Configuration
      ACCOUNT_FIELDS = %w[
        adapter launch_binding models max_concurrent cooldown_sec
      ].freeze
      ROUTING_FIELDS = %w[pool required pin].freeze
      ROUTE_FIELDS = %w[provider model effort capabilities].freeze
      CAPABILITY_FIELDS = %w[context quality tools permissions].freeze
      PIN_FIELDS = %w[provider model].freeze
      MODEL_STAGE_ALIASES = {
        "execute" => "execute_implementation",
        "review.ci" => "review_ci",
        "review.reviewers" => "review_reviewers",
        "review.triage" => "review_triage",
        "review.fix" => "review_fix",
        "review.browser_test" => "review_browser"
      }.freeze

      attr_reader :accounts, :policy, :source

      class << self
        def from(cfg:, stage_name:, routing: nil, source: nil)
          cfg ||= {}
          stage = stage_name.to_s
          stage_cfg = stage_config(cfg, stage)
          routing = stage_cfg["routing"] if routing.nil?
          source ||= "#{stage}.routing"

          if routing.nil? || (routing.is_a?(Hash) && !routing.key?("pool") && !routing.key?(:pool))
            validate_legacy_routing_shape!(routing, source)
            return new(accounts: {}, policy: Policy.legacy(stage: stage), source: source)
          end

          normalized_routing = stringify_hash(routing, source)
          reject_unknown!(normalized_routing.keys - ROUTING_FIELDS, source)
          pool = normalized_routing.fetch("pool")
          unless pool.is_a?(Array) && !pool.empty?
            raise ConfigError, "#{source}.pool must be a non-empty Array"
          end

          accounts = cfg[PROVIDER_ACCOUNTS_KEY]
          unless accounts.is_a?(Hash) && !accounts.empty?
            raise ConfigError,
                  "#{source}.pool opts into provider routing, but no global providers are configured"
          end

          normalized_accounts = if accounts.values.all? { |entry| entry.is_a?(Account) }
            accounts
          else
            normalize_accounts(accounts, source: "global providers")
          end
          build_explicit(
            cfg: cfg,
            stage: stage,
            routing: normalized_routing,
            accounts: normalized_accounts,
            source: source
          )
        end

        def normalize_accounts(raw, source:)
          unless raw.is_a?(Hash)
            raise ConfigError, "providers in #{source} must be a Hash; got #{raw.class}"
          end

          normalized = {}
          raw.each do |raw_id, raw_account|
            id = normalize_account_id(raw_id, "providers key in #{source}")
            if normalized.key?(id)
              raise ConfigError, "providers in #{source} defines normalized account #{id.inspect} more than once"
            end

            path = "providers.#{id}"
            account = stringify_hash(raw_account, path)
            reject_unknown!(account.keys - ACCOUNT_FIELDS, path)
            adapter = nonempty_string(account["adapter"], "#{path}.adapter")
            unless Hive::AgentProfiles.registered?(adapter)
              raise ConfigError,
                    "#{path}.adapter #{adapter.inspect} is not a registered AgentProfile " \
                    "(registered: #{Hive::AgentProfiles.registered_names.inspect})"
            end
            binding = launch_binding(account["launch_binding"], "#{path}.launch_binding")
            models = model_list(account["models"], "#{path}.models")
            maximum = positive_integer(account["max_concurrent"], "#{path}.max_concurrent")
            cooldowns = cooldowns(account["cooldown_sec"], "#{path}.cooldown_sec")
            normalized[id] = Account.new(
              id: id,
              adapter: adapter,
              launch_binding: binding,
              models: models,
              max_concurrent: maximum,
              cooldown_sec: cooldowns
            )
          end

          bindings = normalized.values.group_by do |account|
            [ account.adapter, effective_binding_identity(account) ]
          end
          duplicate = bindings.find { |_identity, values| values.length > 1 }
          if duplicate
            identity, values = duplicate
            raise ConfigError,
                  "providers #{values.map(&:id).inspect} have an indistinguishable launch binding " \
                  "#{identity.last.inspect} for adapter #{identity.first.inspect}"
          end

          ProviderRouting.deep_freeze(normalized)
        end

        private

        def effective_binding_identity(account)
          profile = Hive::AgentProfiles.lookup(account.adapter)
          directory = if account.launch_binding == "default"
            profile.configuration_directory
          else
            binding = Hive::AgentProfiles::LaunchBindings.resolve(
              adapter: account.adapter,
              binding_id: account.launch_binding
            )
            binding.environment.fetch(profile.configuration_environment_key)
          end
          return "default" unless directory && File.directory?(directory)

          File.realpath(directory)
        rescue ArgumentError, Errno::ENOENT, Errno::EACCES
          raise ConfigError,
                "providers.#{account.id}.launch_binding #{account.launch_binding.inspect} " \
                "became unavailable during validation"
        end

        def build_explicit(cfg:, stage:, routing:, accounts:, source:)
          models = cfg.fetch("models", Hive::ModelRouting::EMPTY_MODELS)
          models = Hive::ModelRouting.parse(models, source: source) unless models.empty?
          model_stage = model_stage_for(stage)
          routes = routing.fetch("pool").each_with_index.map do |raw_route, order|
            normalize_route(
              raw_route,
              order: order,
              accounts: accounts,
              models: models,
              model_stage: model_stage,
              cfg: cfg,
              source: source
            )
          end

          duplicate = routes.group_by(&:id).find { |_id, entries| entries.length > 1 }
          if duplicate
            raise ConfigError, "#{source}.pool contains duplicate normalized route #{duplicate.first.inspect}"
          end

          requirements = normalize_requirements(routing["required"], "#{source}.required")
          pin = normalize_pin(routing["pin"], "#{source}.pin")
          if pin && !routes.any? { |route| pin_matches?(pin, route) }
            raise ConfigError, "#{source}.pin does not match a configured route"
          end

          referenced_accounts = routes.map(&:account).uniq.to_h do |id|
            account = accounts.fetch(id)
            [
              id,
              {
                "adapter" => account.adapter,
                "launch_binding" => account.launch_binding,
                "models" => account.models,
                "max_concurrent" => account.max_concurrent,
                "cooldown_sec" => account.cooldown_sec
              }
            ]
          end
          policy = Policy.explicit(
            stage: stage,
            routes: routes,
            requirements: requirements,
            pin: pin,
            account_policy: referenced_accounts
          )
          if policy.eligible_routes.empty?
            raise ConfigError, "#{source}.required requirements exclude every route allowed by the pin"
          end

          new(accounts: accounts, policy: policy, source: source)
        end

        def normalize_route(raw, order:, accounts:, models:, model_stage:, cfg:, source:)
          path = "#{source}.pool[#{order}]"
          entry = stringify_hash(raw, path)
          forbidden = entry.keys & %w[agent adapter]
          unless forbidden.empty?
            raise ConfigError,
                  "#{path} contains per-candidate adapter overrides; per-candidate adapter overrides are not allowed"
          end
          reject_unknown!(entry.keys - ROUTE_FIELDS, path)

          account_id = normalize_account_id(entry["provider"], "#{path}.provider")
          account = accounts[account_id]
          unless account
            raise ConfigError, "#{path}.provider references unknown provider account #{account_id.inspect}"
          end
          profile = Hive::AgentProfiles.lookup(account.adapter, cfg: cfg)
          current = {}
          current[:model] = nonempty_string(entry["model"], "#{path}.model") if entry.key?("model")
          current[:effort] = nonempty_string(entry["effort"], "#{path}.effort") if entry.key?("effort")
          resolution = Hive::ModelRouting.resolve_candidate(
            models: models,
            stage: model_stage,
            profile: profile,
            current: current,
            source: path,
            cfg: cfg
          )
          model = resolution.model
          if model.to_s.empty?
            raise ConfigError, "#{path}.model must resolve to one configured model"
          end
          unless account.models.include?(model)
            raise ConfigError,
                  "#{path}.model #{model.inspect} is not configured for provider account #{account_id.inspect}"
          end
          route_id = "#{account_id}/#{model}"
          if model.bytesize > MAX_IDENTIFIER_BYTES || route_id.bytesize > MAX_IDENTIFIER_BYTES
            raise ConfigError,
                  "#{path}.model produces a route identifier longer than " \
                  "#{MAX_IDENTIFIER_BYTES} bytes"
          end

          capabilities = normalize_capabilities(entry["capabilities"], "#{path}.capabilities")
          validate_profile_capabilities!(profile, capabilities, "#{path}.capabilities")
          Route.new(
            id: route_id,
            account: account_id,
            adapter: account.adapter,
            launch_binding: account.launch_binding,
            model: model,
            effort: resolution.effort,
            order: order,
            capabilities: capabilities,
            model_routing: resolution
          )
        end

        def normalize_capabilities(raw, path)
          value = raw.nil? ? {} : stringify_hash(raw, path)
          reject_unknown!(value.keys - CAPABILITY_FIELDS, path)
          {
            "context" => level(
              value.fetch("context", DEFAULT_CAPABILITIES.fetch("context")),
              CONTEXT_LEVELS,
              "#{path}.context"
            ),
            "quality" => level(
              value.fetch("quality", DEFAULT_CAPABILITIES.fetch("quality")),
              QUALITY_LEVELS,
              "#{path}.quality"
            ),
            "tools" => capability_set(
              value.fetch("tools", DEFAULT_CAPABILITIES.fetch("tools")),
              TOOL_CAPABILITIES,
              "#{path}.tools"
            ),
            "permissions" => capability_set(
              value.fetch("permissions", DEFAULT_CAPABILITIES.fetch("permissions")),
              PERMISSION_CAPABILITIES,
              "#{path}.permissions"
            )
          }.freeze
        end

        def validate_profile_capabilities!(profile, capabilities, path)
          limits = ProviderRouting.profile_capability_limits(profile.name)
          %w[tools permissions].each do |kind|
            unsupported = capabilities.fetch(kind) - limits.fetch(kind)
            next if unsupported.empty?

            raise ConfigError,
                  "#{path}.#{kind} #{unsupported.inspect} cannot be enforced by " \
                  "agent profile #{profile.name.inspect}"
          end
        end

        def normalize_requirements(raw, path)
          return Requirements.empty if raw.nil?

          value = stringify_hash(raw, path)
          reject_unknown!(value.keys - CAPABILITY_FIELDS, path)
          Requirements.new(
            context: value.key?("context") ? level(value["context"], CONTEXT_LEVELS, "#{path}.context") : nil,
            quality: value.key?("quality") ? level(value["quality"], QUALITY_LEVELS, "#{path}.quality") : nil,
            tools: value.key?("tools") ? capability_set(value["tools"], TOOL_CAPABILITIES, "#{path}.tools") : [],
            permissions: value.key?("permissions") ? capability_set(
              value["permissions"], PERMISSION_CAPABILITIES, "#{path}.permissions"
            ) : []
          )
        end

        def normalize_pin(raw, path)
          return nil if raw.nil?

          value = stringify_hash(raw, path)
          reject_unknown!(value.keys - PIN_FIELDS, path)
          Pin.new(
            provider: normalize_account_id(value["provider"], "#{path}.provider"),
            model: value.key?("model") ? nonempty_string(value["model"], "#{path}.model") : nil
          )
        end

        def pin_matches?(pin, route)
          route.account == pin.provider && (pin.model.nil? || route.model == pin.model)
        end

        def model_stage_for(stage)
          candidate = MODEL_STAGE_ALIASES.fetch(stage, stage.tr(".", "_"))
          Hive::ModelRouting.fetch(candidate).key
        rescue Hive::ConfigError
          raise ConfigError,
                "#{stage.inspect} cannot own an explicit provider-routing pool because it has no ModelRouting identity"
        end

        def validate_legacy_routing_shape!(routing, source)
          return if routing.nil?

          value = stringify_hash(routing, source)
          reject_unknown!(value.keys - ROUTING_FIELDS, source)
          return if value.empty?

          raise ConfigError, "#{source}.pool is required when provider routing options are configured"
        end

        def stage_config(cfg, stage)
          stage.split(".").reduce(cfg) do |cursor, key|
            cursor.is_a?(Hash) ? cursor[key] : nil
          end.then { |value| value.is_a?(Hash) ? value : {} }
        end

        def cooldowns(raw, path)
          return DEFAULT_COOLDOWN_SEC.dup if raw.nil?

          value = stringify_hash(raw, path)
          reject_unknown!(value.keys - ACCOUNT_HEALTH_CLASSES, path)
          DEFAULT_COOLDOWN_SEC.merge(
            value.to_h do |klass, seconds|
              unless seconds.is_a?(Integer) && seconds.between?(MIN_COOLDOWN_SEC, MAX_COOLDOWN_SEC)
                raise ConfigError,
                      "#{path}.#{klass} must be an Integer between #{MIN_COOLDOWN_SEC} and " \
                      "#{MAX_COOLDOWN_SEC}; got #{seconds.inspect}"
              end
              [ klass, seconds ]
            end
          )
        end

        def model_list(raw, path)
          unless raw.is_a?(Array) && !raw.empty?
            raise ConfigError, "#{path} must be a non-empty Array of model identifiers"
          end

          values = raw.each_with_index.map { |value, index| nonempty_string(value, "#{path}[#{index}]") }
          raise ConfigError, "#{path} contains duplicate model identifiers" unless values.uniq.length == values.length

          values.freeze
        end

        def capability_set(raw, allowed, path)
          unless raw.is_a?(Array)
            raise ConfigError, "#{path} must be an Array"
          end

          values = raw.each_with_index.map { |value, index| nonempty_string(value, "#{path}[#{index}]") }
          duplicate = values.group_by(&:itself).find { |_value, entries| entries.length > 1 }
          raise ConfigError, "#{path} contains duplicate value #{duplicate.first.inspect}" if duplicate
          unsupported = values - allowed
          unless unsupported.empty?
            raise ConfigError, "#{path} exceeds profile hard limits; supported values: #{allowed.inspect}"
          end
          values.freeze
        end

        def level(raw, allowed, path)
          value = nonempty_string(raw, path)
          return value if allowed.include?(value)

          raise ConfigError, "#{path} exceeds profile hard limits; expected one of #{allowed.inspect}"
        end

        def launch_binding(raw, path)
          value = nonempty_string(raw, path)
          unless value.match?(/\A[a-z][a-z0-9_-]{0,63}\z/)
            raise ConfigError,
                  "#{path} must be a non-secret symbolic binding matching [a-z][a-z0-9_-]{0,63}"
          end
          value
        end

        def normalize_account_id(raw, path)
          value = nonempty_string(raw, path).downcase
          unless value.match?(/\A[a-z][a-z0-9_-]{0,63}\z/)
            raise ConfigError, "#{path} must normalize to [a-z][a-z0-9_-]{0,63}"
          end
          value.freeze
        end

        def positive_integer(value, path)
          return value if value.is_a?(Integer) && value.positive?

          raise ConfigError, "#{path} must be a positive Integer; got #{value.inspect}"
        end

        def nonempty_string(value, path)
          normalized = value.to_s.strip if value.is_a?(String) || value.is_a?(Symbol)
          return normalized.freeze if normalized && !normalized.empty?

          raise ConfigError, "#{path} must be a non-empty scalar"
        end

        def stringify_hash(value, path)
          unless value.is_a?(Hash)
            raise ConfigError, "#{path} must be a Hash; got #{value.class}"
          end

          value.each_with_object({}) do |(key, child), normalized|
            unless key.is_a?(String) || key.is_a?(Symbol)
              raise ConfigError, "#{path} contains non-string key #{key.inspect}"
            end
            string_key = key.to_s
            raise ConfigError, "#{path} defines #{string_key.inspect} more than once" if normalized.key?(string_key)

            normalized[string_key] = child
          end
        end

        def reject_unknown!(unknown, path)
          return if unknown.empty?

          raise ConfigError, "#{path} contains unknown field(s) #{unknown.sort.inspect}"
        end
      end

      def initialize(accounts:, policy:, source:)
        @accounts = ProviderRouting.deep_freeze(accounts.to_h.dup)
        @policy = policy
        @source = ProviderRouting.frozen_string(source)
        freeze
      end

      def legacy? = policy.legacy?
      def explicit? = policy.explicit?
      def routes = policy.routes
      alias pool routes
      def requirements = policy.requirements
      def pin = policy.pin
      def digest = policy.digest
    end
  end
end
