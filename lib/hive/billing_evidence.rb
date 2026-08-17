module Hive
  module BillingEvidence
    ROUTES = %w[subscription api unknown].freeze
    SOURCES = %w[
      provider_account_config agent_profile_contract unavailable
    ].freeze
    DIRECT_SUBSCRIPTION_ADAPTERS = %w[claude codex grok].freeze

    module_function

    def for_profile(profile)
      if DIRECT_SUBSCRIPTION_ADAPTERS.include?(profile.name.to_s) &&
         profile.respond_to?(:billing_semantics) &&
         profile.billing_semantics.to_s == "subscription_backed"
        [ "subscription", "agent_profile_contract" ]
      else
        [ "unknown", "unavailable" ]
      end
    end
  end
end
