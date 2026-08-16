require "test_helper"
require "sqlite3"
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
             input: 100, output: 50, cached: 10, attempt_id: nil,
             session_id: nil, task_generation: nil)
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
      cached: cached,
      attempt_id: attempt_id, session_id: session_id,
      task_generation: task_generation, source: session_id && "runtime_receipt"
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

  def test_grok_is_present_in_zero_aggregate_and_recorded_totals
    with_usage_db do
      now = Time.utc(2026, 5, 24, 12)
      record(agent: "grok", started_at: now - 60, input: 12, output: 4, cached: 0)

      aggregate = Hive::UsageDb.aggregate(scope: {}, now: now)

      assert_equal({ input: 12, output: 4, cached: 0 }, usage_at(aggregate, :grok, :all))
    end
  end

  def test_opencode_persists_nested_route_and_nil_versus_zero_usage
    with_usage_db do
      Hive::UsageDb.record!(
        agent: "opencode",
        model: "anthropic/claude-sonnet-4-5-20250929",
        requested_route: "anthropic/claude-sonnet-4-5",
        actual_route: "anthropic/claude-sonnet-4-5-20250929",
        project_slug: "alpha",
        task_slug: "task-a",
        stage: "4-execute",
        started_at: Time.utc(2026, 8, 12, 12),
        ended_at: Time.utc(2026, 8, 12, 12, 1),
        input: nil,
        output: 0,
        cached: nil,
        cache_read: nil,
        cache_write: 0,
        reasoning: nil,
        cost: 0.0
      )

      db = SQLite3::Database.new(Hive::UsageDb.path)
      db.results_as_hash = true
      row = db.get_first_row("SELECT * FROM token_usage WHERE agent = 'opencode'")

      assert_equal "anthropic", row.fetch("requested_backend")
      assert_equal "claude-sonnet-4-5", row.fetch("requested_model")
      assert_equal "anthropic", row.fetch("actual_backend")
      assert_equal "claude-sonnet-4-5-20250929", row.fetch("actual_model")
      assert_equal 0, row.fetch("input_available")
      assert_equal 1, row.fetch("output_available")
      assert_equal 0, row.fetch("cache_read_available")
      assert_equal 1, row.fetch("cache_write_available")
      assert_equal 0, row.fetch("reasoning_available")
      assert_equal 1, row.fetch("cost_available")
      assert_equal 0.0, row.fetch("cost")
    ensure
      db&.close
    end
  end

  def test_session_persists_billing_and_disjoint_usage_evidence_without_guessing
    with_usage_db do
      Hive::UsageDb.record!(
        agent: "opencode", harness: "opencode",
        model: "anthropic/claude-sonnet-4-5",
        requested_route: "anthropic/claude-sonnet-4-5",
        actual_route: "anthropic/claude-sonnet-4-5-20250929",
        billing_route: "subscription",
        billing_evidence_source: "provider_account_config",
        project_slug: "alpha", task_slug: "task-a", stage: "4-execute",
        started_at: Time.utc(2026, 8, 12, 12),
        ended_at: Time.utc(2026, 8, 12, 12, 1),
        input: nil, output: 0, cached: nil,
        cache_read: nil, cache_write: 0, reasoning: nil,
        input_includes_cache_read: false,
        input_includes_cache_write: false,
        output_includes_reasoning: nil,
        provider_reported_cost: 0.0,
        attempt_id: "attempt-1", session_id: "session-1",
        task_generation: 3, source: "runtime_receipt"
      )

      session = Hive::UsageDb.exact_attempt(
        attempt_id: "attempt-1", task_generation: 3
      ).fetch(:sessions).fetch(0)
      assert_equal "opencode", session.fetch(:harness)
      assert_equal "subscription", session.fetch(:billing_route)
      assert_equal "provider_account_config", session.fetch(:billing_evidence_source)
      assert_equal false, session.fetch(:input_includes_cache_read)
      assert_equal false, session.fetch(:input_includes_cache_write)
      assert_nil session[:output_includes_reasoning]
      assert_equal 0.0, session.fetch(:provider_reported_cost)
      assert_equal 0, session.fetch(:cache_write)
      assert_equal false, session.fetch(:cache_read_available)
    end
  end

  def test_aggregate_preserves_unknown_usage_in_agent_and_total_buckets
    with_usage_db do
      now = Time.utc(2026, 8, 12, 12)
      Hive::UsageDb.record!(
        agent: "opencode", model: "anthropic/model", project_slug: "alpha",
        task_slug: "task-a", stage: "4-execute", started_at: now - 60,
        ended_at: now, input: nil, output: 0, cached: nil
      )

      aggregate = Hive::UsageDb.aggregate(scope: {}, now: now)
      usage = usage_at(aggregate, :opencode, :all)

      assert_equal 0, usage.fetch(:input)
      assert_equal false, usage.fetch(:input_available)
      refute usage.key?(:output_available), "measured zero must remain distinguishable from unknown"
      assert_equal false, usage.fetch(:cached_available)
      assert_equal false, aggregate.dig(:total, :all, :input_available)
      assert_equal false, aggregate.dig(:total, :all, :cached_available)
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

  def test_existing_usage_schema_is_migrated_without_losing_legacy_rows
    with_usage_db do
      db = SQLite3::Database.new(Hive::UsageDb.path)
      db.execute_batch(<<~SQL)
        CREATE TABLE token_usage (
          id TEXT PRIMARY KEY, agent TEXT NOT NULL, model TEXT,
          project_slug TEXT, task_slug TEXT, stage TEXT,
          started_at TEXT NOT NULL, ended_at TEXT,
          input INTEGER NOT NULL DEFAULT 0,
          output INTEGER NOT NULL DEFAULT 0,
          cached INTEGER NOT NULL DEFAULT 0
        );
        INSERT INTO token_usage (
          id, agent, started_at, input, output, cached
        ) VALUES ('legacy', 'codex', '2026-08-12T00:00:00Z', 1, 2, 3);
      SQL
      db.close
      db = nil

      record(agent: "opencode", input: 4, output: 5, cached: 6)

      db = SQLite3::Database.new(Hive::UsageDb.path)
      db.results_as_hash = true
      legacy = db.get_first_row("SELECT * FROM token_usage WHERE id = 'legacy'")
      current = db.get_first_row("SELECT * FROM token_usage WHERE agent = 'opencode'")
      assert_equal 1, legacy.fetch("input_available")
      assert_equal 0, legacy.fetch("cache_read_available")
      assert_equal 4, current.fetch("input")
      assert current.key?("requested_backend")
    ensure
      db&.close
    end
  end

  def test_legacy_schema_migrates_transactionally_and_rows_remain_unattributed
    with_usage_db do
      require "sqlite3"
      db = SQLite3::Database.new(Hive::UsageDb.path)
      db.execute_batch(Hive::UsageDb::LEGACY_SCHEMA_SQL)
      db.execute(
        "INSERT INTO token_usage (id, agent, model, project_slug, task_slug, stage, " \
        "started_at, ended_at, input, output, cached) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [ "legacy-1", "claude", "legacy-model", "alpha", "task-a", "4-execute",
          "2026-05-24T10:00:00Z", "2026-05-24T10:01:00Z", 10, 5, 1 ]
      )
      db.close

      record(
        agent: "codex", input: 20, output: 7, cached: 2,
        attempt_id: "attempt-1", session_id: "session-1", task_generation: 3
      )

      db = SQLite3::Database.new(Hive::UsageDb.path)
      columns = db.table_info("token_usage").map { |row| row["name"] || row[1] }
      assert_includes columns, "attempt_id"
      assert_includes columns, "session_id"
      assert_includes columns, "task_generation"
      assert_includes columns, "source"
      assert_equal Hive::UsageDb::SCHEMA_VERSION, db.get_first_value("PRAGMA user_version")
      db.close

      exact = Hive::UsageDb.exact_attempt(attempt_id: "attempt-1", task_generation: 3)
      assert exact.fetch(:available)
      assert_equal 1, exact.fetch(:sessions).length
      assert_equal({ input: 20, output: 7, cached: 2 }, exact.fetch(:totals))
      assert_equal 1, exact.fetch(:unattributed_count)
      assert_equal "legacy-model", exact.fetch(:unattributed).first.fetch(:model)
    end
  end

  def test_session_record_is_idempotently_upserted_without_double_counting
    with_usage_db do
      common = {
        agent: "codex", model: "gpt-test", project_slug: "alpha",
        task_slug: "task-a", stage: "4-execute",
        started_at: Time.utc(2026, 5, 24, 10), ended_at: Time.utc(2026, 5, 24, 10, 1),
        attempt_id: "attempt-1", session_id: "session-1", task_generation: 3,
        source: "runtime_receipt"
      }
      assert Hive::UsageDb.record!(**common, input: 10, output: 2, cached: 1)
      assert Hive::UsageDb.record!(**common, input: 12, output: 4, cached: 2)

      exact = Hive::UsageDb.exact_attempt(attempt_id: "attempt-1", task_generation: 3)
      assert_equal 1, exact.fetch(:sessions).length
      assert_equal({ input: 12, output: 4, cached: 2 }, exact.fetch(:totals))
      assert_equal "session-1", exact.fetch(:sessions).first.fetch(:session_id)
    end
  end

  def test_concurrent_schema_migrators_and_session_writers_converge
    with_usage_db do
      ready = Queue.new
      release = Queue.new
      threads = 2.times.map do |index|
        Thread.new do
          ready << true
          release.pop
          Hive::UsageDb.record!(
            agent: "codex", model: "gpt-test", project_slug: "alpha",
            task_slug: "task-a", stage: "4-execute",
            started_at: Time.utc(2026, 5, 24, 10), ended_at: Time.utc(2026, 5, 24, 10, 1),
            input: 10 + index, output: 2, cached: 1,
            attempt_id: "attempt-1", session_id: "session-#{index}",
            task_generation: 3, source: "runtime_receipt"
          )
        end
      end
      2.times { ready.pop }
      2.times { release << true }
      assert threads.map(&:value).all?

      exact = Hive::UsageDb.exact_attempt(attempt_id: "attempt-1", task_generation: 3)
      assert_equal 2, exact.fetch(:sessions).length
      assert_equal 21, exact.dig(:totals, :input)
    end
  end

  def test_session_identity_cannot_move_between_attempts
    with_usage_db do
      common = {
        agent: "codex", model: "gpt-test", project_slug: "alpha",
        task_slug: "task-a", stage: "4-execute",
        started_at: Time.utc(2026, 5, 24, 10), ended_at: Time.utc(2026, 5, 24, 10, 1),
        input: 10, output: 2, cached: 1, session_id: "session-1",
        task_generation: 3, source: "runtime_receipt"
      }
      assert Hive::UsageDb.record!(**common, attempt_id: "attempt-1")
      _out, _err = capture_io do
        refute Hive::UsageDb.record!(**common, attempt_id: "attempt-2")
      end

      assert_equal 1,
                   Hive::UsageDb.exact_attempt(
                     attempt_id: "attempt-1", task_generation: 3
                   ).fetch(:sessions).length
      assert_empty Hive::UsageDb.exact_attempt(
        attempt_id: "attempt-2", task_generation: 3
      ).fetch(:sessions)
    end
  end

  def test_exact_attempt_marks_missing_or_failed_storage_unavailable_not_zero
    with_tmp_dir do |dir|
      Hive::UsageDb.path = File.join(dir, "missing.db")
      missing = Hive::UsageDb.exact_attempt(attempt_id: "attempt-1")
      refute missing.fetch(:available)
      assert_nil missing.fetch(:totals)

      Hive::UsageDb.path = dir
      _out, _err = capture_io do
        broken = Hive::UsageDb.exact_attempt(attempt_id: "attempt-1")
        refute broken.fetch(:available)
        assert_nil broken.fetch(:totals)
      end
    end
  end

  def test_exact_attempt_scopes_legacy_rows_by_project_and_task
    with_usage_db do
      record(project_slug: "alpha", task_slug: "task-a", input: 10)
      record(project_slug: "alpha", task_slug: "task-b", input: 20)
      record(project_slug: "beta", task_slug: "task-a", input: 30)

      exact = Hive::UsageDb.exact_attempt(
        attempt_id: "missing", project_slug: "alpha", task_slug: "task-a"
      )
      assert exact.fetch(:available)
      assert_equal 1, exact.fetch(:unattributed_count)
      assert_equal "alpha", exact.fetch(:unattributed).first.fetch(:project_slug)
      assert_equal "task-a", exact.fetch(:unattributed).first.fetch(:task_slug)
    end
  end

  def test_exact_attempt_corrupt_store_is_reported_as_unavailable
    with_tmp_dir do |dir|
      Hive::UsageDb.path = File.join(dir, "usage.db")
      File.write(Hive::UsageDb.path, "not a sqlite database")

      _out, err = capture_io do
        exact = Hive::UsageDb.exact_attempt(attempt_id: "attempt-1")
        refute exact.fetch(:available)
        assert_equal "read_failed", exact.fetch(:reason)
      end
      assert_match(/exact attempt usage failed/, err)
    end
  end

  def test_aggregate_returns_patrol_bucket_for_patrol_stage_rows
    with_usage_db do
      now = Time.utc(2026, 5, 24, 12)
      record(stage: "patrol-review", input: 10, output: 5, cached: 1, started_at: now - 3600)
      record(stage: "refactor-patrol-review", input: 4, output: 2, cached: 1, started_at: now - 3600)
      record(agent: "codex", stage: "patrol-fix", input: 20, output: 7, cached: 2, started_at: now - (8 * 24 * 60 * 60))
      record(stage: "2-brainstorm", input: 100, output: 50, cached: 10, started_at: now - 3600)
      record(project_slug: "beta", stage: "patrol-review", input: 999, output: 999, cached: 999, started_at: now - 3600)

      aggregate = Hive::UsageDb.aggregate(scope: { project_slug: "alpha" }, now: now)

      assert_equal({ input: 14, output: 7, cached: 2 }, patrol_at(aggregate, :today))
      assert_equal({ input: 14, output: 7, cached: 2 }, patrol_at(aggregate, :"7d"))
      assert_equal({ input: 34, output: 14, cached: 4 }, patrol_at(aggregate, :"30d"))
      assert_equal({ input: 34, output: 14, cached: 4 }, patrol_at(aggregate, :all))
      assert_equal({ input: 134, output: 64, cached: 14 }, aggregate.fetch(:total).fetch(:all),
                   "TOTAL remains the real per-agent sum and does not add the patrol row twice")
    end
  end

  def test_patrol_activity_counts_metered_and_unmetered_launches_across_patrol_types
    with_usage_db do
      now = Time.utc(2026, 5, 24, 12)
      record(stage: "patrol-review", input: 10, output: 5, cached: 1, started_at: now - 60)
      record(stage: "refactor-patrol-review", input: 0, output: 0, cached: 7, started_at: now - 45)
      record(stage: "refactor-patrol-fix-unmetered", input: 0, output: 0, cached: 0, started_at: now - 30)
      record(stage: "2-brainstorm", input: 999, output: 999, cached: 999, started_at: now - 30)

      activity = Hive::UsageDb.patrol_activity(
        scope: { project_slug: "alpha" }, now: now
      )

      assert_equal 10, activity.fetch(:input)
      assert_equal true, activity.fetch(:available)
      assert_equal 5, activity.fetch(:output)
      assert_equal 8, activity.fetch(:cached)
      assert_equal 15, activity.fetch(:tokens)
      assert_equal 3, activity.fetch(:agent_spawns)
      assert_equal 1, activity.fetch(:unmetered_spawns)
      assert_equal 1, activity.fetch(:ordinary_agent_spawns)
      assert_equal 2, activity.fetch(:architecture_agent_spawns)
      assert_equal 1, activity.fetch(:architecture_review_spawns)
      assert_equal 0, activity.fetch(:ordinary_unmetered_spawns)
      assert_equal 1, activity.fetch(:architecture_unmetered_spawns)
    end
  end

  def test_patrol_activity_marks_an_unavailable_store_instead_of_claiming_zero_usage
    with_tmp_dir do |dir|
      Hive::UsageDb.path = dir

      _out, err = capture_io do
        activity = Hive::UsageDb.patrol_activity(scope: {}, now: Time.utc(2026, 5, 24, 12))

        assert_equal false, activity.fetch(:available)
        assert_equal 0, activity.fetch(:tokens)
      end

      assert_match(/patrol usage aggregate failed/, err)
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
