require "hive/agent_profiles"

module Hive
  # Capability-aware provider-account routing. A provider is an operator-owned
  # account identity; +agent+ remains the CLI adapter used to execute work.
  module ProviderRouting
    PROVIDER_ACCOUNTS_KEY = :__hive_provider_accounts
    CONTEXT_LEVELS = %w[standard large].freeze
    QUALITY_LEVELS = %w[standard high].freeze
    CAPABILITY_KEYS = %w[context quality tools permissions].freeze
    ROUTING_KEYS = %w[pool required pin].freeze
    CANDIDATE_KEYS = %w[provider agent model effort capabilities].freeze
    PIN_KEYS = %w[provider model].freeze
    TIMED_FAILURE_CLASSES = %w[quota rate_limit session_limit credit].freeze
    ADMIN_FAILURE_CLASSES = %w[auth permission billing_configuration].freeze
    FAILURE_CLASSES = (TIMED_FAILURE_CLASSES + ADMIN_FAILURE_CLASSES).freeze
    DEFAULT_COOLDOWNS = {
      "quota" => 3600,
      "rate_limit" => 300,
      "session_limit" => 3600,
      "credit" => 3600
    }.freeze
    DEFAULT_BACKOFF_CAP_SEC = 86_400
    DEFAULT_CAPABILITIES = {
      "context" => "standard",
      "quality" => "standard",
      "tools" => %w[shell filesystem].freeze,
      "permissions" => %w[read write].freeze
    }.freeze

    Account = Data.define(:key, :adapter, :max_concurrent, :cooldown_sec, :backoff_cap_sec)
    Candidate = Data.define(:provider, :agent, :model, :effort, :capabilities, :order)
    Requirements = Data.define(:context, :quality, :tools, :permissions)
    Pin = Data.define(:provider, :model)

    autoload :Configuration, File.expand_path("provider_routing/configuration.rb", __dir__)

    module_function

    def default_accounts
      @default_accounts ||= Configuration.normalize_accounts(
        Hive::AgentProfiles.registered_names.to_h do |name|
          [ name.to_s, { "adapter" => name.to_s } ]
        end,
        source: "built-in provider defaults"
      ).freeze
    end
  end
end
