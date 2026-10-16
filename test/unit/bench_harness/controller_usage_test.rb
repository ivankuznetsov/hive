require "test_helper"
require "hive/workflows/bench"
require "hive/usage_db"

usage_harness = File.join(Hive::Workflows::Bench::RUNTIME_DIR, "harness")
$LOAD_PATH.unshift(usage_harness)
require "lib/token_report"
require "lib/hive_driver"
$LOAD_PATH.delete(usage_harness)

class BenchControllerUsageTest < Minitest::Test
  include HiveTestHelper

  def test_controller_exports_only_cell_opencode_totals_and_uses_latest_snapshot
    with_tmp_dir do |root|
      previous = Hive::UsageDb.instance_variable_get(:@database)
      db = Hive::RuntimeControlPlane::Database.new(path: File.join(root, "controller", "runtime.sqlite3")).migrate!
      Hive::UsageDb.database = db
      record_usage(session: "one")
      record_usage(session: "other-task", task: "other")
      record_usage(session: "other-agent", agent: "pi")
      exports = File.join(root, "usage-export")
      FileUtils.mkdir_p(exports)
      first = HiveBench::TokenReport.export_opencode_usage(exports, task_slug: "task")
      assert_equal 0o444, File.stat(first).mode & 0o777
      payload = JSON.parse(File.read(first))
      assert_equal %w[models schema status], payload.keys.sort
      assert_equal({ "input" => 70, "output" => 20, "cache_read" => 30, "cache_write" => 5 }, payload.fetch("models").fetch("model"))
      refute_includes File.read(first), "private-session-source"
      record_usage(session: "two")
      second = HiveBench::TokenReport.export_opencode_usage(exports, task_slug: "task")
      refute_equal first, second
      target = File.join(root, "target")
      log_dir = File.join(target, ".hive-state", "logs")
      FileUtils.mkdir_p(log_dir)
      assert_equal({ "input" => 140, "output" => 40, "cache_read" => 60, "cache_write" => 10 },
                   HiveBench::TokenReport.scan_cell(target).fetch("model"))
      assert_equal payload, JSON.parse(File.read(first)), "prior receipt must remain immutable"
    ensure
      Hive::UsageDb.database = previous
      db&.disconnect
    end
  end

  def test_legacy_database_remains_a_fallback_when_no_export_exists
    with_tmp_dir do |root|
      home = File.join(root, ".hb", "hive-home")
      FileUtils.mkdir_p(home)
      legacy = SQLite3::Database.new(File.join(home, "usage.db"))
      legacy.execute("CREATE TABLE token_usage (agent TEXT, model TEXT, input INTEGER, output INTEGER, cached INTEGER)")
      legacy.execute("INSERT INTO token_usage VALUES ('opencode', 'old-model', 12, 4, 2)")
      legacy.close
      assert_equal({ "input" => 12, "output" => 4, "cache_read" => 2, "cache_write" => 0 },
                   HiveBench::TokenReport.scan_cell(root).fetch("old-model"))
    end
  end

  def test_driver_combines_pi_stream_and_opencode_receipt_without_recounting_result_usage
    with_tmp_dir do |root|
      target = File.join(root, "target")
      logs = File.join(target, ".hive-state", "logs")
      exports = File.join(root, "usage-export")
      FileUtils.mkdir_p([ logs, exports ])
      File.write(File.join(exports, "opencode-usage-001.json"), JSON.generate(
        schema: HiveBench::TokenReport::EXPORT_SCHEMA, status: "available",
        models: { "deepseek" => { input: 100, output: 20, cache_read: 30, cache_write: 5 } }
      ))
      events = [
        { type: "message_end", message: { role: "assistant", model: "deepseek",
          usage: { input: 10, output: 4, cacheRead: 2, cacheWrite: 1 } } },
        { type: "result", total_cost_usd: 0.125,
          usage: { input_tokens: 999, output_tokens: 999 } }
      ]
      File.write(File.join(logs, "plan-session.log"), events.map { |event| JSON.generate(event) }.join("\n") + "\n")
      driver = HiveBench::HiveDriver.new(reuse_existing: false, reuse_unverified: false)
      assert_equal({ "input_tokens" => 110, "output_tokens" => 24, "cached_tokens" => 32,
                     "cache_creation_tokens" => 6, "cost_usd" => 0.125 }, driver.send(:telemetry, target))
    end
  end

  def test_unavailable_controller_usage_is_not_reported_as_zero
    with_tmp_dir do |root|
      previous = Hive::UsageDb.instance_variable_get(:@database)
      db = Hive::RuntimeControlPlane::Database.new(path: File.join(root, "missing", "runtime.sqlite3"))
      Hive::UsageDb.database = db
      exports = File.join(root, "usage-export")
      FileUtils.mkdir_p(exports)
      assert_raises(HiveBench::TokenReport::UsageUnavailable) do
        HiveBench::TokenReport.export_opencode_usage(exports, task_slug: "task")
      end
      payload = JSON.parse(File.read(Dir.glob(File.join(exports, "*.json")).fetch(0)))
      assert_equal "unavailable", payload.fetch("status")
      refute payload.key?("models")
      assert_raises(HiveBench::TokenReport::UsageUnavailable) do
        HiveBench::TokenReport.scan_cell(File.join(root, "target"))
      end
    ensure
      Hive::UsageDb.database = previous
      db&.disconnect
    end
  end

  def test_exit_hook_keeps_stage_failure_and_marks_export_failure
    source = File.read(File.join(Hive::Workflows::Bench::RUNTIME_DIR, "harness", "lib", "hive_stages.sh"))
    function = source[/^export_controller_usage\(\) \{\n.*?^\}/m]
    refute_nil function
    [ [ 0, 0, 0 ], [ 7, 0, 7 ], [ 0, 1, 4 ], [ 7, 1, 7 ] ].each do |stage, export, expected|
      _out, err, status = Open3.capture3("bash", "-c", <<~SH)
        #{function}
        SLUG=task
        ruby() { return #{export}; }
        trap export_controller_usage EXIT
        exit #{stage}
      SH
      assert_equal expected, status.exitstatus, err
    end
  end

  private

  def record_usage(session:, task: "task", agent: "opencode")
    Hive::UsageDb.record!(agent: agent, model: "model", project_slug: "work", task_slug: task,
      stage: "4-execute", started_at: Time.now.utc, ended_at: Time.now.utc,
      input: 100, output: 20, cached: 30, cache_read: 30, cache_write: 5,
      input_includes_cache_read: true, input_includes_cache_write: false,
      session_id: session, source: "private-session-source")
  end
end
