require "test_helper"
require "hive/usage_db"

class UsageCompactionTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 9, 5, 12)

  def setup
    @previous = Hive::UsageDb.instance_variable_get(:@database)
    @directory = Dir.mktmpdir("hive-usage-compaction")
    @database = Hive::RuntimeControlPlane::Database.new(
      path: File.join(@directory, "runtime.sqlite3")
    ).migrate!
    Hive::UsageDb.database = @database
  end

  def teardown
    @database&.disconnect
    Hive::UsageDb.database = @previous
    FileUtils.remove_entry(@directory)
  end

  def test_compaction_preserves_totals_and_is_repeatable_across_restart
    record("old-a")
    record("old-b", input: 200)
    record("recent", started_at: NOW - 60)
    before = Hive::UsageDb.aggregate(scope: {}, now: NOW)

    assert_equal 2, Hive::UsageDb.compact!(now: NOW)
    assert_equal before, Hive::UsageDb.aggregate(scope: {}, now: NOW)
    assert_equal 1, @database.read { |db| db[:token_usage].count }
    summary = @database.read { |db| db[:token_usage_daily].first }
    assert_equal 2, summary[:sessions_count]
    assert_equal 300, summary[:input]
    @database.disconnect
    assert_equal 0, Hive::UsageDb.compact!(now: NOW)
    assert_equal before, Hive::UsageDb.aggregate(scope: {}, now: NOW)

    error = assert_raises(Hive::RuntimeControlPlane::IntegrityError) { record("old-a") }
    assert_equal :usage_detail_expired, error.code
    assert_equal before, Hive::UsageDb.aggregate(scope: {}, now: NOW)
  end

  def test_open_sessions_and_unresolved_attempts_are_not_compacted
    record("open", ended_at: nil)
    record("unknown-attempt", attempt_id: "not-yet-accounted")
    record("closed")
    assert_equal 1, Hive::UsageDb.compact!(now: NOW)
    record("open", input: 250)
    assert_equal 250, @database.read { |db| db[:token_usage].where(session_id: "open").get(:input) }
    assert_equal 1, Hive::UsageDb.compact!(now: NOW)
    assert_equal [ "unknown-attempt" ], @database.read { |db| db[:token_usage].select_map(:session_id) }
  end

  def test_batch_bounds_unknown_metrics_and_model_groups
    record("a", input: nil)
    record("b", actual_model: "luna")
    record("c", project_slug: "other")
    assert_equal 1, Hive::UsageDb.compact!(now: NOW, limit: 1)
    assert_equal 2, Hive::UsageDb.compact!(now: NOW)
    report = Hive::UsageDb.task_usage(project_slug: "hive", task_slug: "task")
    assert report[:available]
    assert_equal 2, report[:groups].sum { |row| row[:sessions_count] }
    assert_equal %w[luna sol], report[:groups].map { |row| row[:actual_model] }.sort
    sol = report[:groups].find { |row| row[:actual_model] == "sol" }
    assert_equal 0, sol[:input_available]
    assert_equal 2, report[:compacted_sessions_count]
  end

  def test_failed_delete_rolls_back_the_summary_write
    record("old")
    @database.read do |db|
      db.run("CREATE TRIGGER reject_usage_delete BEFORE DELETE ON token_usage BEGIN SELECT RAISE(ABORT, 'test failure'); END")
    end
    assert_raises(Sequel::DatabaseError) { Hive::UsageDb.compact!(now: NOW) }
    assert_equal 1, @database.read { |db| db[:token_usage].count }
    assert_equal 0, @database.read { |db| db[:token_usage_daily].count }
  end

  def test_concurrent_compactors_move_each_session_only_once
    4.times { |n| record("old-#{n}") }
    owners = Array.new(2) { Hive::RuntimeControlPlane::Database.new(path: @database.path) }
    results = owners.map do |owner|
      Thread.new { Hive::UsageDb.compact!(now: NOW, limit: 2, database: owner) }
    end.map(&:value)
    assert_equal 4, results.sum
    assert_equal 0, @database.read { |db| db[:token_usage].count }
    assert_equal 4, @database.read { |db| db[:token_usage_daily].get(:sessions_count) }
  ensure
    owners&.each(&:disconnect)
  end

  def test_calendar_boundary_unfinished_and_invalid_dates_are_retained
    record("cutoff", started_at: Time.utc(2026, 8, 29), ended_at: Time.utc(2026, 8, 29, 0, 1))
    record("recent-end", ended_at: NOW)
    record("invalid", started_at: "0000-invalid", ended_at: "0000-invalid")
    record("old", started_at: Time.utc(2026, 8, 28, 23, 58), ended_at: Time.utc(2026, 8, 28, 23, 59))
    assert_equal 1, Hive::UsageDb.compact!(now: NOW)
    assert_equal %w[cutoff invalid recent-end], @database.read { |db| db[:token_usage].select_map(:session_id).sort }
    assert_raises(ArgumentError) { Hive::UsageDb.compact!(now: NOW, limit: 0) }
  end

  def test_closed_history_cannot_be_reintroduced_as_a_patrol_reservation
    record("old")
    Hive::UsageDb.compact!(now: NOW)
    assert_raises(Hive::RuntimeControlPlane::IntegrityError) do
      Hive::UsageDb.reserve_patrol_discovery!(
        session_id: "old-patrol", project_slug: "hive", stage: "patrol-review",
        agent: "claude", started_at: NOW - 10 * 86_400, limit: 10
      )
    end
  end

  def test_daily_thirty_day_boundary_preserves_the_whole_old_day
    record("boundary", started_at: Time.utc(2026, 8, 6, 1), ended_at: Time.utc(2026, 8, 6, 2))
    record("outside", started_at: Time.utc(2026, 8, 5, 23), ended_at: Time.utc(2026, 8, 5, 23, 1))
    before = Hive::UsageDb.aggregate(scope: {}, now: NOW)
    assert_equal 100, before[:total][:"30d"][:input]
    Hive::UsageDb.compact!(now: NOW)
    assert_equal before, Hive::UsageDb.aggregate(scope: {}, now: NOW)
  end

  private

  def record(id, **overrides)
    started_at = NOW - 10 * 86_400
    Hive::UsageDb.record!(**{
      session_id: id, agent: "codex", model: "sol", actual_provider: "openai",
      actual_model: "sol", project_slug: "hive", task_slug: "task", stage: "4-execute",
      started_at: started_at, ended_at: started_at + 60,
      input: 100, output: 25, cached: 0
    }.merge(overrides))
  end
end
