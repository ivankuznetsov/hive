require "test_helper"
require "hive/commands/patrol"

class PatrolQueryCommandTest < Minitest::Test
  include HiveTestHelper

  def test_list_reads_bounded_projection_without_running_a_cycle
    with_tmp_dir do |dir|
      state_root = File.join(dir, ".hive-state")
      store = Hive::Patrol::StateStore.new(dir, hive_state_path: state_root)
      store.with_cycle_lock { nil }
      store.write_finding(
        Hive::Patrol::Finding.new(
          id: "finding-1", feature_id: "feature-1", category: "bug",
          severity: "high", confidence: "high", title: "Broken boundary",
          description: "Evidence", lifecycle_state: "active",
          lifecycle_updated_at: "2026-08-13T12:00:00Z"
        )
      )
      store.rebuild_finding_query_projection!
      entry = {
        "name" => "demo", "path" => dir,
        "hive_state_path" => state_root
      }

      output, = capture_io do
        Hive::Commands::Patrol.new(
          "demo", project_entry: entry, list: true, json: true
        ).call
      end
      payload = JSON.parse(output)

      assert_equal "hive-patrol-findings", payload.fetch("schema")
      assert_equal 1, payload.fetch("count")
      assert_equal "finding-1", payload.dig("findings", 0, "id")
    end
  end


  def test_list_errors_use_the_findings_query_contract
    output, = capture_io do
      assert_raises(Hive::ConfigError) do
        Hive::Commands::Patrol.new(
          "missing", project_entry: nil, list: true, json: true
        ).call
      end
    end
    payload = JSON.parse(output)

    assert_equal "hive-patrol-findings", payload.fetch("schema")
    assert_equal 1, payload.fetch("schema_version")
    assert_equal false, payload.fetch("ok")
    assert_equal "config", payload.fetch("error_kind")
  end
end
