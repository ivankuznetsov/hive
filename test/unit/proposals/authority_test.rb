require "test_helper"
require "hive/proposals/authority"

class ProposalAuthorityTest < Minitest::Test
  def test_operator_and_policy_authorities_are_capability_scoped_and_fresh
    authority = Hive::Proposals::Authority.new(config)
    operator_fingerprint = authority.fingerprint("alice")
    operator = authority.authorize!(
      identity: "alice", capability: "decide",
      expected_policy_fingerprint: operator_fingerprint
    )

    assert_equal "operator", operator.fetch("kind")
    assert_equal operator_fingerprint, operator.fetch("policy_fingerprint")
    assert_raises(Hive::Proposals::Unauthorized) do
      authority.authorize!(
        identity: "alice", capability: "rollback",
        expected_policy_fingerprint: operator_fingerprint
      )
    end

    policy_fingerprint = authority.fingerprint("acceptance-policy")
    policy = authority.authorize!(
      identity: "acceptance-policy", capability: "decide",
      expected_policy_fingerprint: policy_fingerprint,
      receipt: {
        "authority_id" => "acceptance-policy", "capability" => "decide",
        "policy_fingerprint" => policy_fingerprint,
        "issued_at" => "2026-08-30T12:00:00Z"
      }
    )
    assert_equal "policy", policy.fetch("kind")
  end

  def test_absent_stale_revoked_and_receiptless_authority_fail_closed
    authority = Hive::Proposals::Authority.new(config)

    assert_raises(Hive::Proposals::Unauthorized) do
      authority.authorize!(
        identity: "missing", capability: "decide",
        expected_policy_fingerprint: "a" * 64
      )
    end
    assert_raises(Hive::Proposals::StaleObservation) do
      authority.authorize!(
        identity: "alice", capability: "decide",
        expected_policy_fingerprint: "a" * 64
      )
    end
    assert_raises(Hive::Proposals::Unauthorized) do
      authority.authorize!(
        identity: "revoked", capability: "decide",
        expected_policy_fingerprint: authority.fingerprint("revoked")
      )
    end
    assert_raises(Hive::Proposals::Unauthorized) do
      authority.authorize!(
        identity: "acceptance-policy", capability: "decide",
        expected_policy_fingerprint: authority.fingerprint("acceptance-policy")
      )
    end
  end

  private

  def config
    {
      "authorities" => {
        "alice" => {
          "kind" => "operator", "capabilities" => %w[decide supersede],
          "version" => 1, "revoked" => false
        },
        "acceptance-policy" => {
          "kind" => "policy", "capabilities" => [ "decide" ],
          "version" => 3, "revoked" => false
        },
        "revoked" => {
          "kind" => "operator", "capabilities" => [ "decide" ],
          "version" => 1, "revoked" => true
        }
      }
    }
  end
end
