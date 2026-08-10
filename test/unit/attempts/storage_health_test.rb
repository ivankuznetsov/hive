require "test_helper"
require "hive/attempts/storage_health"

class AttemptsStorageHealthTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 8, 10, 12, 0, 0)

  def test_records_one_bounded_maintenance_result_and_current_hot_counts
    with_tmp_dir do |root|
      health = Hive::Attempts::StorageHealth.new(root: root)

      assert health.claim_maintenance(now: NOW, interval_sec: 3_600)
      refute health.claim_maintenance(now: NOW + 60, interval_sec: 3_600)
      health.complete_maintenance(
        now: NOW + 2,
        result: { promoted: 4, deleted: 3, cold_examined: 7 }
      )

      status = health.snapshot(hot_count: 2, invalid_hot_count: 1)

      assert_equal "healthy", status.fetch("status")
      assert_equal 3, status.dig("layout", "generation")
      assert_equal 2, status.dig("hot", "records")
      assert_equal 1, status.dig("hot", "invalid")
      assert_equal "2026-08-10T12:00:02.000000Z",
                   status.dig("maintenance", "last_completed_at")
      assert_equal(
        { "promoted" => 4, "deleted" => 3, "cold_examined" => 7 },
        status.dig("maintenance", "last_result")
      )
      assert_nil status.fetch("last_error")
      assert_nil status.fetch("degraded_reason")
    end
  end

  def test_failure_is_a_bounded_reason_code_without_raw_error_text
    with_tmp_dir do |root|
      health = Hive::Attempts::StorageHealth.new(root: root)
      error = RuntimeError.new("secret output must not enter status")

      health.fail_maintenance(error: error, now: NOW)
      status = health.snapshot(hot_count: nil, invalid_hot_count: nil)

      assert_equal "degraded", status.fetch("status")
      assert_equal "maintenance_failed", status.fetch("degraded_reason")
      assert_equal(
        {
          "operation" => "maintenance", "class" => "RuntimeError",
          "observed_at" => "2026-08-10T12:00:00.000000Z"
        },
        status.fetch("last_error")
      )
      refute_includes JSON.generate(status), error.message
    end
  end

  def test_success_clears_only_the_matching_operation_failure
    with_tmp_dir do |root|
      health = Hive::Attempts::StorageHealth.new(root: root)
      health.fail_maintenance(error: RuntimeError.new("hidden"), now: NOW)

      health.complete_migration(
        now: NOW + 1,
        result: { source_count: 4, promoted: 3, hot: 1, invalid: 0 }
      )
      still_degraded = health.snapshot(hot_count: 1, invalid_hot_count: 0)
      assert_equal "maintenance_failed", still_degraded.fetch("degraded_reason")

      health.complete_maintenance(
        now: NOW + 2,
        result: { promoted: 0, deleted: 0, cold_examined: 0 }
      )
      recovered = health.snapshot(hot_count: 1, invalid_hot_count: 0)
      assert_equal "healthy", recovered.fetch("status")
      assert_nil recovered.fetch("last_error")
    end
  end
end
