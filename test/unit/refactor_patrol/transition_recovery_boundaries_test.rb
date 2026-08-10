require "test_helper"
require "hive/refactor_patrol/action_transitions"
require "hive/refactor_patrol/decision_projection"
require "hive/refactor_patrol/discovery_block_transitions"
require "hive/refactor_patrol/discovery_transition_context"
require "hive/refactor_patrol/transition_evidence"

class RefactorPatrolTransitionRecoveryBoundariesTest < Minitest::Test
  Intent = Data.define(
    :intent_id, :module_name, :occurrence_id, :owner_epoch, :sink, :target,
    :idempotency_key, :scope
  )

  def test_transition_inputs_reject_invalid_operation_and_preserve_rejection_code
    input = Hive::RefactorPatrol::DecisionProjection.operation_input(
      job_id: "job-7", phase: :action, operation: "checkpoint"
    )
    assert_equal "operation", input.fetch("kind")

    error = assert_raises(Hive::ConfigError) do
      Hive::RefactorPatrol::DecisionProjection.operation_input(
        job_id: "job-7", phase: :action, operation: ""
      )
    end
    assert_equal "architecture patrol selection input is malformed", error.message

    result = Hive::RefactorPatrol::TransitionEvidence.matched_result(
      "outcome" => "rejected", "error_code" => "stale_claim"
    )
    assert_equal(
      { "transition_status" => "rejected", "error_code" => "stale_claim" },
      result.fetch("outcome")
    )
  end

  def test_diagnostic_rejection_is_persisted_through_the_block_transition
    calls = []
    capture = Object.new
    context = Object.new
    context.define_singleton_method(:gateway_supported?) { |_store| true }
    context.define_singleton_method(:reserve_occurrence) do |*|
      flunk("existing capture should be reused")
    end
    context.define_singleton_method(:digest) { |_value| "evidence-digest" }
    context.define_singleton_method(:gateway) do |*|
      Object.new.tap do |gateway|
        gateway.define_singleton_method(:perform!) do |**options|
          intent = Intent.new(
            "intent-#{'1' * 64}", "architecture-patrol", "occ-#{'a' * 64}",
            1, "discovery", "job-7:block", "block", { "job_id" => "job-7" }
          )
          options.fetch(:reject).call(intent, RuntimeError.new("denied"), "denied")
        end
      end
    end
    store = Object.new
    store.define_singleton_method(:occurrence_capture) { |_job_id| capture }
    store.define_singleton_method(:next_diagnostic_episode) { |*| 1 }
    store.define_singleton_method(:assert_recorded_transitions_terminal!) { |*| true }
    store.define_singleton_method(:record_job_transition_rejection!) do |job_id, **options|
      calls << [ job_id, options ]
      { "job_id" => job_id }
    end

    Hive::RefactorPatrol::DiscoveryBlockTransitions.new(context: context).block(
      entry: { "name" => "demo" }, store: store,
      aggregate: { "job_id" => "job-7" }, phase: :discovery,
      reason: "authority_revoked", evidence: { "gate" => "discovery" },
      now: Time.utc(2026, 7, 29), backoff_sec: 60
    )

    assert_equal "job-7", calls.dig(0, 0)
    assert_equal "discovery-block-rejection", calls.dig(0, 1, :operation)
    assert_equal "denied", calls.dig(0, 1, :transition, "error_code")
  end

  def test_recorded_nonlocal_transition_stops_recovery_before_gateway_replay
    intent = nonlocal_intent
    store = Object.new
    store.define_singleton_method(:occurrence_capture) { |_job_id| Object.new }
    store.define_singleton_method(:unsettled_recorded_transitions) do |_aggregate|
      [ [ intent, { "intent_id" => intent.intent_id } ] ]
    end
    context = Hive::RefactorPatrol::DiscoveryTransitionContext.new(
      config_loader: ->(*) { {} }, module_execution: nil, owner: "daemon",
      occurrence_lifecycle: Object.new
    )

    error = assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
      context.reconcile_recorded(
        { "path" => "/tmp/demo" }, store, { "job_id" => "job-7" }, Time.utc(2026, 7, 29)
      )
    end
    assert_equal "recorded transition sink is not local", error.message
  end

  private

  def nonlocal_intent
    @nonlocal_intent ||= Intent.new(
      "intent-#{'2' * 64}", "architecture-patrol", "occ-#{'b' * 64}", 1,
      "branch", "owner/demo:topic", "branch", { "job_id" => "job-7" }
    )
  end
end
