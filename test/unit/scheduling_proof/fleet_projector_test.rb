require "test_helper"
require "hive/scheduling_proof/fleet_projector"

class SchedulingProofFleetProjectorTest < Minitest::Test
  NOW = Time.utc(2026, 7, 17, 12, 0, 0)

  def test_completely_accounts_for_unused_units_in_candidate_order
    proof = projector.project(
      configured_slots: 4,
      owners: [ owner("a", "attempt-a") ],
      candidates: [ candidate("b", "dependency_wait"), candidate("c", "provider_circuit_open") ]
    )

    assert_equal 1, proof.fetch("used_slots")
    assert_equal 3, proof.fetch("unused_slots")
    assert_equal 1, proof.fetch("eligible_candidate_count")
    assert_equal 3, proof.fetch("causal_buckets").sum { |bucket| bucket.fetch("units") }
    assert_equal %w[dependency_wait provider_circuit_open no_candidate],
                 proof.fetch("causal_buckets").map { |bucket| bucket.fetch("reason") }
    assert_equal 1, proof.fetch("owners").size
    refute proof.fetch("stale")
  end

  def test_overcommit_and_duplicate_owners_degrade_without_clamping
    proof = projector.project(
      configured_slots: 1,
      owners: [ owner("a", "attempt-a"), owner("a", "attempt-b") ],
      candidates: []
    )

    assert_equal "accounting_inconsistent", proof.fetch("health")
    assert_equal 2, proof.fetch("used_slots")
    assert_nil proof.fetch("unused_slots")
    assert_equal "no_safe_action", proof.dig("action", "kind")
    assert_includes proof.fetch("accounting_errors"), "owners_exceed_configured_slots"
    assert_includes proof.fetch("accounting_errors"), "duplicate_task_generation_owner"
  end

  def test_stopped_daemon_attributes_current_unused_capacity_without_losing_prior_buckets
    prior = [ { "reason" => "dependency_wait", "units" => 1, "tasks" => [ "demo/b" ] } ]
    proof = projector(daemon_running: false).project(
      configured_slots: 2, owners: [], candidates: [ candidate("b", "dependency_wait") ],
      prior_causal_buckets: prior
    )

    assert_equal [ "daemon_not_running" ], proof.fetch("causal_buckets").map { |bucket| bucket["reason"] }
    assert_equal 2, proof.dig("causal_buckets", 0, "units")
    assert_equal prior, proof.fetch("prior_causal_buckets")
    assert proof.fetch("stale")
  end

  private

  def projector(daemon_running: true)
    Hive::SchedulingProof::FleetProjector.new(
      as_of: NOW, heartbeat_at: NOW - 2, poll_interval_sec: 30,
      daemon_running: daemon_running
    )
  end

  def owner(slug, attempt_id)
    {
      "project" => "demo", "task_slug" => slug, "stage" => "4-execute",
      "task_generation" => 3, "attempt_id" => attempt_id, "attempt_state" => "running"
    }
  end

  def candidate(slug, reason)
    {
      "project" => "demo", "task_slug" => slug, "stage" => "4-execute",
      "task_generation" => 3, "reason" => reason,
      "eligible" => slug == "c", "queue_position" => slug == "b" ? 1 : 2
    }
  end
end
