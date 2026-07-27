require "test_helper"
require "hive/conditions/transition_guard"

class ConditionsTransitionGuardTest < Minitest::Test
  include HiveTestHelper

  def test_closure_guard_accepts_only_the_exact_valid_receipt_digest
    task = Object.new
    calls = []
    validator = lambda do |observed, receipt_digest:, project:|
      calls << [ observed, receipt_digest, project ]
      {
        "type" => "task_closure",
        "receipt_digest" => receipt_digest,
        "evidence_digest" => "b" * 64,
        "reason" => "already_delivered",
        "authority" => "remote_merge"
      }
    end

    with_replaced_singleton_method(Hive::TaskClosure, :transition_evidence, validator) do
      assert Hive::Conditions::TransitionGuard.validate_closure!(
        task, receipt_digest: "a" * 64, project: "app"
      )
    end

    assert_equal [ [ task, "a" * 64, "app" ] ], calls
  end

  def test_closure_guard_fails_closed_for_an_absent_invalid_or_stale_receipt
    validator = ->(*) { nil }

    with_replaced_singleton_method(Hive::TaskClosure, :transition_evidence, validator) do
      error = assert_raises(Hive::TaskClosure::InvalidReceipt) do
        Hive::Conditions::TransitionGuard.validate_closure!(
          Object.new, receipt_digest: "b" * 64, project: "app"
        )
      end
      assert_match(/absent, invalid, or stale/, error.message)
    end
  end
end
