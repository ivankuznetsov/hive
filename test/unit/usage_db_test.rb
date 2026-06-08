require "test_helper"
require "hive/usage_db"

class UsageDbTest < Minitest::Test
  include HiveTestHelper

  def setup
    @old_path = Hive::UsageDb.path
    @old_env = ENV["HIVE_USAGE_DB_PATH"]
  end

  def teardown
    Hive::UsageDb.path = @old_path
    @old_env.nil? ? ENV.delete("HIVE_USAGE_DB_PATH") : ENV["HIVE_USAGE_DB_PATH"] = @old_env
  end

  def with_usage_db
    with_tmp_dir do |dir|
      Hive::UsageDb.path = File.join(dir, "usage.db")
      yield
    end
  end

  def record(agent: "claude", project_slug: "alpha", task_slug: "task-a",
             stage: "2-brainstorm", started_at: Time.utc(2026, 5, 24, 10),
             input: 100, output: 50, cached: 10)
    Hive::UsageDb.record!(
      agent: agent,
      model: "test-model",
      project_slug: project_slug,
      task_slug: task_slug,
      stage: stage,
      started_at: started_at,
      ended_at: started_at + 60,
      input: input,
      output: output,
      cached: cached
    )
  end

  def usage_at(aggregate, agent, bucket)
    aggregate.fetch(:agents).fetch(agent).fetch(bucket)
  end

  def patrol_at(aggregate, bucket)
    aggregate.fetch(:patrol).fetch(bucket)
  end

  def test_record_followed_by_aggregate_counts_today_rolling_and_all
    with_usage_db do
      now = Time.utc(2026, 5, 24, 12)
      record(started_at: Time.utc(2026, 5, 24, 11), input: 1200, output: 300, cached: 40)

      aggregate = Hive::UsageDb.aggregate(scope: {}, now: now)

      %i[today 7d 30d all].each do |bucket|
        assert_equal({ input: 1200, output: 300, cached: 40 }, usage_at(aggregate, :claude, bucket))
        assert_equal({ input: 1200, output: 300, cached: 40 }, aggregate.fetch(:total).fetch(bucket))
        assert_equal({ input: 0, output: 0, cached: 0 }, patrol_at(aggregate, bucket))
      end
    end
  end

  def test_project_scope_excludes_other_projects
    with_usage_db do
      now = Time.utc(2026, 5, 24, 12)
      record(project_slug: "alpha", input: 10, output: 5, cached: 1)
      record(project_slug: "beta", input: 999, output: 999, cached: 999)

      aggregate = Hive::UsageDb.aggregate(scope: { project_slug: "alpha" }, now: now)

      assert_equal({ input: 10, output: 5, cached: 1 }, usage_at(aggregate, :claude, :all))
      assert_equal({ input: 10, output: 5, cached: 1 }, aggregate.fetch(:total).fetch(:all))
    end
  end

  def test_task_scope_excludes_other_tasks
    with_usage_db do
      now = Time.utc(2026, 5, 24, 12)
      record(task_slug: "task-a", input: 22, output: 11, cached: 3)
      record(task_slug: "task-b", input: 999, output: 999, cached: 999)

      aggregate = Hive::UsageDb.aggregate(scope: { task_slug: "task-a" }, now: now)

      assert_equal({ input: 22, output: 11, cached: 3 }, usage_at(aggregate, :claude, :all))
      assert_equal({ input: 22, output: 11, cached: 3 }, aggregate.fetch(:total).fetch(:all))
    end
  end

  def test_rolling_windows_use_supplied_now
    with_usage_db do
      now = Time.utc(2026, 5, 24, 12)
      record(started_at: now - (6 * 24 * 60 * 60), input: 6, output: 1, cached: 0)
      record(started_at: now - (8 * 24 * 60 * 60), input: 8, output: 1, cached: 0)
      record(started_at: now - (31 * 24 * 60 * 60), input: 31, output: 1, cached: 0)

      aggregate = Hive::UsageDb.aggregate(scope: {}, now: now)

      assert_equal 0, usage_at(aggregate, :claude, :today).fetch(:input)
      assert_equal 6, usage_at(aggregate, :claude, :"7d").fetch(:input)
      assert_equal 14, usage_at(aggregate, :claude, :"30d").fetch(:input)
      assert_equal 45, usage_at(aggregate, :claude, :all).fetch(:input)
    end
  end

  def test_missing_db_returns_zero_tree_without_creating_file
    with_tmp_dir do |dir|
      path = File.join(dir, "usage.db")
      Hive::UsageDb.path = path

      aggregate = Hive::UsageDb.aggregate(scope: {}, now: Time.utc(2026, 5, 24, 12))

      assert_equal({ input: 0, output: 0, cached: 0 }, usage_at(aggregate, :claude, :all))
      refute File.exist?(path)
    end
  end

  def test_env_path_overrides_default_path
    with_tmp_dir do |dir|
      Hive::UsageDb.path = nil
      ENV["HIVE_USAGE_DB_PATH"] = File.join(dir, "custom.db")

      assert_equal File.join(dir, "custom.db"), Hive::UsageDb.path
    end
  end

  def test_record_with_broken_path_warns_and_does_not_raise
    with_tmp_dir do |dir|
      Hive::UsageDb.path = dir

      _out, err = capture_io do
        result = record
        refute result
      end

      assert_match(/usage record failed/, err)
    end
  end

  def test_schema_creation_is_idempotent
    with_usage_db do
      record(input: 1, output: 1, cached: 1)
      record(input: 2, output: 2, cached: 2)

      aggregate = Hive::UsageDb.aggregate(scope: {}, now: Time.utc(2026, 5, 24, 12))

      assert_equal({ input: 3, output: 3, cached: 3 }, usage_at(aggregate, :claude, :all))
    end
  end

  def test_aggregate_returns_patrol_bucket_for_patrol_stage_rows
    with_usage_db do
      now = Time.utc(2026, 5, 24, 12)
      record(stage: "patrol-review", input: 10, output: 5, cached: 1, started_at: now - 3600)
      record(agent: "codex", stage: "patrol-fix", input: 20, output: 7, cached: 2, started_at: now - (8 * 24 * 60 * 60))
      record(stage: "2-brainstorm", input: 100, output: 50, cached: 10, started_at: now - 3600)
      record(project_slug: "beta", stage: "patrol-review", input: 999, output: 999, cached: 999, started_at: now - 3600)

      aggregate = Hive::UsageDb.aggregate(scope: { project_slug: "alpha" }, now: now)

      assert_equal({ input: 10, output: 5, cached: 1 }, patrol_at(aggregate, :today))
      assert_equal({ input: 10, output: 5, cached: 1 }, patrol_at(aggregate, :"7d"))
      assert_equal({ input: 30, output: 12, cached: 3 }, patrol_at(aggregate, :"30d"))
      assert_equal({ input: 30, output: 12, cached: 3 }, patrol_at(aggregate, :all))
      assert_equal({ input: 130, output: 62, cached: 13 }, aggregate.fetch(:total).fetch(:all),
                   "TOTAL remains the real per-agent sum and does not add the patrol row twice")
    end
  end

  def test_aggregate_with_broken_path_warns_and_returns_zero_tree
    with_tmp_dir do |dir|
      Hive::UsageDb.path = dir

      _out, err = capture_io do
        aggregate = Hive::UsageDb.aggregate(scope: {}, now: Time.utc(2026, 5, 24, 12))
        assert_equal({ input: 0, output: 0, cached: 0 }, usage_at(aggregate, :claude, :all))
      end

      assert_match(/usage aggregate failed/, err)
    end
  end

  def test_iso8601_returns_original_text_when_parse_fails
    assert_equal "not-a-time", Hive::UsageDb.iso8601("not-a-time")
  end
end
