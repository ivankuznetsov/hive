require "test_helper"
require "hive/scheduling_proof/freshness"

class SchedulingProofFreshnessTest < Minitest::Test
  NOW = Time.utc(2026, 7, 17, 12, 0, 0)

  def test_uses_ninety_second_minimum_stale_threshold
    fresh = Hive::SchedulingProof::Freshness.project(
      as_of: NOW, heartbeat_at: NOW - 90, poll_interval_sec: 30, daemon_running: true
    )
    stale = Hive::SchedulingProof::Freshness.project(
      as_of: NOW, heartbeat_at: NOW - 91, poll_interval_sec: 30, daemon_running: true
    )

    refute fresh.fetch("stale")
    assert stale.fetch("stale")
    assert_equal 90, stale.fetch("stale_after_sec")
    assert_includes stale.fetch("unavailable_live_claims"), "queue_position"
  end

  def test_uses_twice_poll_interval_when_larger
    proof = Hive::SchedulingProof::Freshness.project(
      as_of: NOW, heartbeat_at: NOW - 121, poll_interval_sec: 60, daemon_running: true
    )

    assert proof.fetch("stale")
    assert_equal 120, proof.fetch("stale_after_sec")
  end

  def test_distinguishes_stopped_and_never_snapshotted_daemons
    stopped = Hive::SchedulingProof::Freshness.project(
      as_of: NOW, heartbeat_at: NOW - 10, poll_interval_sec: 30, daemon_running: false
    )
    missing = Hive::SchedulingProof::Freshness.project(
      as_of: NOW, heartbeat_at: nil, poll_interval_sec: 30, daemon_running: true
    )

    assert_equal "stopped", stopped.fetch("daemon_state")
    assert_equal "unavailable", missing.fetch("daemon_state")
    assert stopped.fetch("stale")
    assert missing.fetch("stale")
  end

  def test_invalid_or_missing_times_degrade_to_epoch
    missing = Hive::SchedulingProof::Freshness.project(
      as_of: nil, heartbeat_at: nil, poll_interval_sec: 30, daemon_running: true
    )
    invalid = Hive::SchedulingProof::Freshness.project(
      as_of: "not-a-time", heartbeat_at: "also-not-a-time",
      poll_interval_sec: 30, daemon_running: true
    )

    assert_equal "1970-01-01T00:00:00.000000Z", missing.fetch("as_of")
    assert_equal "1970-01-01T00:00:00.000000Z", invalid.fetch("scheduler_heartbeat_at")
  end
end
