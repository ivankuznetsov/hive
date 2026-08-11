require "hive"
require "hive/canonical_json"

module Hive
  # Pure configuration and value-object boundary for opt-in provider-account
  # routing. Runtime health, capacity, admission, and recovery live outside
  # this namespace's U1 policy objects.
  module ProviderRouting
    PROVIDER_ACCOUNTS_KEY = :__hive_provider_accounts
    POLICY_SCHEMA = "hive-provider-routing-policy/v1"

    CONTEXT_LEVELS = %w[standard large].freeze
    QUALITY_LEVELS = %w[standard high].freeze
    CONTEXT_RANK = CONTEXT_LEVELS.each_with_index.to_h.freeze
    QUALITY_RANK = QUALITY_LEVELS.each_with_index.to_h.freeze
    TOOL_CAPABILITIES = %w[browser filesystem mcp shell web].freeze
    PERMISSION_CAPABILITIES = %w[network read write].freeze

    ACCOUNT_HEALTH_CLASSES = %w[
      authentication
      billing_configuration
      exhausted_credits
      account_quota
      provider_rate_limit
      provider_outage
    ].freeze
    DEFAULT_COOLDOWN_SEC = {
      "authentication" => 3600,
      "billing_configuration" => 3600,
      "exhausted_credits" => 3600,
      "account_quota" => 3600,
      "provider_rate_limit" => 300,
      "provider_outage" => 300
    }.freeze
    MIN_COOLDOWN_SEC = 1
    MAX_COOLDOWN_SEC = 7 * 24 * 60 * 60
    MAX_IDENTIFIER_BYTES = 128

    DEFAULT_CAPABILITIES = {
      "context" => "standard",
      "quality" => "standard",
      "tools" => [].freeze,
      "permissions" => [].freeze
    }.freeze
    PROFILE_CAPABILITY_LIMITS = {
      "claude" => {
        "tools" => TOOL_CAPABILITIES,
        "permissions" => PERMISSION_CAPABILITIES
      },
      "codex" => {
        "tools" => %w[filesystem mcp shell web].freeze,
        "permissions" => PERMISSION_CAPABILITIES
      },
      "pi" => {
        "tools" => %w[filesystem shell web].freeze,
        "permissions" => PERMISSION_CAPABILITIES
      },
      "grok" => {
        "tools" => %w[filesystem shell web].freeze,
        "permissions" => PERMISSION_CAPABILITIES
      }
    }.freeze

    Account = Data.define(
      :id, :adapter, :launch_binding, :models, :max_concurrent, :cooldown_sec
    ) do
      def initialize(id:, adapter:, launch_binding:, models:, max_concurrent:, cooldown_sec:)
        super(
          id: ProviderRouting.frozen_string(id),
          adapter: ProviderRouting.frozen_string(adapter),
          launch_binding: ProviderRouting.frozen_string(launch_binding),
          models: ProviderRouting.deep_freeze(Array(models).map(&:to_s)),
          max_concurrent: Integer(max_concurrent),
          cooldown_sec: ProviderRouting.deep_freeze(cooldown_sec.to_h)
        )
        freeze
      end

      alias key id
    end

    Requirements = Data.define(:context, :quality, :tools, :permissions) do
      def initialize(context: nil, quality: nil, tools: [], permissions: [])
        super(
          context: context && ProviderRouting.frozen_string(context),
          quality: quality && ProviderRouting.frozen_string(quality),
          tools: ProviderRouting.deep_freeze(Array(tools).map(&:to_s)),
          permissions: ProviderRouting.deep_freeze(Array(permissions).map(&:to_s))
        )
        freeze
      end

      def self.empty
        @empty ||= new.freeze
      end

      def to_h
        {
          "context" => context,
          "quality" => quality,
          "tools" => tools,
          "permissions" => permissions
        }
      end
    end

    Pin = Data.define(:account, :model) do
      def initialize(account: nil, provider: nil, model: nil)
        account ||= provider
        super(
          account: ProviderRouting.frozen_string(account),
          model: model && ProviderRouting.frozen_string(model)
        )
        freeze
      end

      alias provider account

      def to_h = { "provider" => account, "model" => model }
    end

    autoload :Configuration, File.expand_path("provider_routing/configuration.rb", __dir__)
    autoload :Candidate, File.expand_path("provider_routing/candidate.rb", __dir__)
    autoload :Policy, File.expand_path("provider_routing/policy.rb", __dir__)
    autoload :PolicyStore, File.expand_path("provider_routing/policy_store.rb", __dir__)
    autoload :Request, File.expand_path("provider_routing/request.rb", __dir__)
    autoload :Decision, File.expand_path("provider_routing/decision.rb", __dir__)
    autoload :OperationalProjection,
             File.expand_path("provider_routing/operational_projection.rb", __dir__)
    autoload :Route, File.expand_path("provider_routing/route.rb", __dir__)
    autoload :Router, File.expand_path("provider_routing/router.rb", __dir__)

    module_function

    def frozen_string(value)
      value.to_s.dup.freeze
    end

    def deep_freeze(value)
      case value
      when Hash
        value.each { |key, child| key.freeze; deep_freeze(child) }
      when Array
        value.each { |child| deep_freeze(child) }
      when String
        value.freeze
      end
      value.freeze
    end

    def deep_copy(value)
      case value
      when Hash
        value.to_h { |key, child| [ key.to_s.dup, deep_copy(child) ] }
      when Array
        value.map { |child| deep_copy(child) }
      when String
        value.dup
      else
        value
      end
    end

    def profile_capability_limits(name)
      PROFILE_CAPABILITY_LIMITS.fetch(name.to_s) do
        { "tools" => [].freeze, "permissions" => [].freeze }.freeze
      end
    end

    def canonical_json(value)
      Hive::CanonicalJSON.generate(value)
    end

    def digest(value)
      Hive::CanonicalJSON.digest(value).freeze
    end
  end
end
