require_relative "../test_helper"
require "hive/agent_profiles"
require "hive/billing_evidence"

class BillingEvidenceTest < Minitest::Test
  def test_profile_contract_is_the_single_billing_evidence_authority
    Hive::AgentProfiles.registered_names.sort.each do |name|
      profile = Hive::AgentProfiles.lookup(name)
      route, source = Hive::BillingEvidence.for_profile(profile)

      if profile.billing_semantics == :subscription_backed
        assert_equal [ "subscription", "agent_profile_contract" ], [ route, source ],
                     "#{name} declares subscription_backed and must prove it from its contract"
      else
        assert_equal [ "unknown", "unavailable" ], [ route, source ],
                     "#{name} does not declare subscription_backed, so evidence stays unavailable"
      end
    end
  end

  def test_subscription_backed_declaration_is_authoritative_regardless_of_adapter_name
    profile = Struct.new(:name, :billing_semantics)
                    .new(:future_adapter, :subscription_backed)

    assert_equal [ "subscription", "agent_profile_contract" ],
                 Hive::BillingEvidence.for_profile(profile)
  end

  def test_profiles_without_subscription_semantics_stay_unknown_and_unavailable
    api_billed = Struct.new(:name, :billing_semantics).new(:claude, :api_billed)
    anonymous = Struct.new(:billing_semantics).new(:unknown)

    assert_equal [ "unknown", "unavailable" ],
                 Hive::BillingEvidence.for_profile(api_billed)
    assert_equal [ "unknown", "unavailable" ],
                 Hive::BillingEvidence.for_profile(anonymous)
    assert_equal [ "unknown", "unavailable" ],
                 Hive::BillingEvidence.for_profile(Object.new)
  end
end
