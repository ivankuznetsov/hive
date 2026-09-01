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

  def test_identified_task_queries_only_its_exact_durable_attempt
    calls = []
    repository = Object.new
    repository.define_singleton_method(:live_attempt_for) do |task_id:|
      calls << task_id
      { "attempt_id" => "attempt-1" }
    end
    repository.define_singleton_method(:active_attempts) do
      flunk "transition guard performed a global attempt scan"
    end
    task = Struct.new(:id, keyword_init: true).new(id: "expected")

    assert Hive::Conditions::TransitionGuard.send(
      :admitted_attempt?, task, repository: repository
    )
    assert_equal [ "expected" ], calls
  end

  def test_unidentified_task_does_not_scan_attempts
    repository = Object.new
    repository.define_singleton_method(:live_attempt_for) { flunk "missing task id was queried" }
    repository.define_singleton_method(:active_attempts) { flunk "global attempts were scanned" }
    task = Struct.new(:id, keyword_init: true).new(id: nil)

    refute Hive::Conditions::TransitionGuard.send(
      :admitted_attempt?, task, repository: repository
    )
  end

  def test_terminal_attempt_waits_for_task_journal_publication
    projection = { "identity" => { "attempt_id" => "attempt-1" } }
    repository = Object.new
    journal_acknowledged = false
    repository.define_singleton_method(:publication) do |_attempt_id|
      { "consumers" => { "journal" => journal_acknowledged } }
    end

    assert Hive::Conditions::TransitionGuard.send(
      :journal_publication_pending?, projection, repository: repository
    )
    journal_acknowledged = true
    refute Hive::Conditions::TransitionGuard.send(
      :journal_publication_pending?, projection, repository: repository
    )
  end
end
