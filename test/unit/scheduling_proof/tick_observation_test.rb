require "test_helper"
require "hive/scheduling_proof/tick_observation"

class SchedulingProofTickObservationTest < Minitest::Test
  def test_builds_versioned_generation_keyed_snapshot
    observation = Hive::SchedulingProof::TickObservation.new(
      daemon_instance_id: "pid-12-start-abc", daemon_state: "running",
      heartbeat_at: Time.utc(2026, 7, 17, 12), poll_interval_sec: 30,
      configuration_fingerprint: "cfg", tick_health: "ok",
      unavailable_live_claims: [], configured_slots: 3,
      owners: [ { "project" => "demo", "task_slug" => "task", "stage" => "4-execute",
                  "task_generation" => 2, "attempt_id" => "attempt-1", "attempt_state" => "running" } ],
      candidates: []
    )

    snapshot = observation.to_h
    assert_equal "hive-scheduler-snapshot", snapshot.fetch("schema")
    assert_equal 1, snapshot.fetch("schema_version")
    assert_equal "2026-07-17T12:00:00.000000Z", snapshot.fetch("heartbeat_at")
    assert_equal 3, snapshot.dig("fleet", "configured_slots")
    assert_equal "attempt-1", snapshot.dig("fleet", "owners", 0, "attempt_id")
  end
end
