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

  def test_rejects_malformed_authority_rows_and_expired_validity_windows
    invalid_rows = [
      { "kind" => "agent", "capabilities" => [ "decide" ], "version" => 1, "revoked" => false },
      { "kind" => "operator", "capabilities" => [ "unknown" ], "version" => 1, "revoked" => false },
      { "kind" => "operator", "capabilities" => [ "decide" ], "version" => 0, "revoked" => false },
      { "kind" => "operator", "capabilities" => [ "decide" ], "version" => 1, "revoked" => "no" }
    ]
    invalid_rows.each do |row|
      authority = Hive::Proposals::Authority.new({ "authorities" => { "broken" => row } })
      assert_raises(Hive::Proposals::InvalidRecord) { authority.fingerprint("broken") }
    end

    clock = -> { Time.utc(2026, 8, 30, 12, 0, 0) }
    not_yet = authority_with_window(valid_from: "2026-08-30T12:01:01Z", clock:)
    expired = authority_with_window(valid_until: "2026-08-30T12:00:00Z", clock:)

    assert_raises(Hive::Proposals::Unauthorized) do
      not_yet.authorize!(
        identity: "windowed", capability: "decide",
        expected_policy_fingerprint: not_yet.fingerprint("windowed")
      )
    end
    assert_raises(Hive::Proposals::Unauthorized) do
      expired.authorize!(
        identity: "windowed", capability: "decide",
        expected_policy_fingerprint: expired.fingerprint("windowed")
      )
    end
  end

  def test_policy_receipt_must_match_and_not_be_future_dated
    clock = -> { Time.utc(2026, 8, 30, 12, 0, 0) }
    authority = Hive::Proposals::Authority.new(config, clock:)
    fingerprint = authority.fingerprint("acceptance-policy")
    base = {
      "authority_id" => "acceptance-policy", "capability" => "decide",
      "policy_fingerprint" => fingerprint, "issued_at" => "2026-08-30T12:00:00Z"
    }

    assert_raises(Hive::Proposals::Unauthorized) do
      authority.authorize!(
        identity: "acceptance-policy", capability: "decide",
        expected_policy_fingerprint: fingerprint,
        receipt: base.merge("authority_id" => "another-policy")
      )
    end
    assert_raises(Hive::Proposals::Unauthorized) do
      authority.authorize!(
        identity: "acceptance-policy", capability: "decide",
        expected_policy_fingerprint: fingerprint,
        receipt: base.merge("issued_at" => "2026-08-30T12:02:00Z")
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

  def authority_with_window(clock:, **window)
    row = {
      "kind" => "operator", "capabilities" => [ "decide" ],
      "version" => 1, "revoked" => false
    }.merge(window.transform_keys(&:to_s))
    Hive::Proposals::Authority.new({ "authorities" => { "windowed" => row } }, clock:)
  end
end
