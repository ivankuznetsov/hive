module Hive
  module BillingEvidence
    ROUTES = %w[subscription api unknown].freeze
    SOURCES = %w[
      provider_account_config agent_profile_contract unavailable
    ].freeze

    module_function

    # The profile's declared billing_semantics contract is the single
    # authority for subscription evidence. Billing evidence never re-derives
    # admission from the adapter name; a profile that declares
    # `subscription_backed` proves subscription semantics from its own
    # contract, and every other declaration stays unknown/unavailable
    # unless an admitted provider-account configuration declares the route.
    def for_profile(profile)
      if profile.respond_to?(:billing_semantics) &&
         profile.billing_semantics.to_s == "subscription_backed"
        [ "subscription", "agent_profile_contract" ]
      else
        [ "unknown", "unavailable" ]
      end
    end
  end
end
