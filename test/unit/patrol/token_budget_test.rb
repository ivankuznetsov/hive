require "test_helper"
require "hive/patrol/token_budget"

class PatrolTokenBudgetTest < Minitest::Test
  include HiveTestHelper

  Profile = Struct.new(:name)

  def setup
    @old_path = Hive::UsageDb.path
  end

  def teardown
    Hive::UsageDb.path = @old_path
  end

  def config(max_tokens_per_agent: 100)
    { "patrol" => { "max_tokens_per_agent" => max_tokens_per_agent } }
  end

  def with_budget(cfg = config)
    with_tmp_dir do |dir|
      Hive::UsageDb.path = File.join(dir, "usage.db")
      now = Time.utc(2026, 7, 16, 12)
      budget = Hive::Patrol::TokenBudget.new(dir, cfg: cfg, clock: -> { now })
      yield budget, dir, now
    end
  end

  def record(budget, now, usage, stage: "patrol-review", profile: Profile.new(:codex))
    budget.record!(
      result: { status: :ok, usage: usage }, profile: profile,
      stage: stage, started_at: now - 1
    )
  end

  def test_default_is_a_high_per_agent_emergency_ceiling
    with_budget({ "patrol" => {} }) do |budget|
      assert_equal 100_000_000, budget.max_tokens
    end
  end

  def test_one_ceiling_applies_to_every_patrol_stage
    with_budget(config(max_tokens_per_agent: 123_456)) do |budget|
      assert_equal 123_456, budget.max_tokens

      %w[patrol-review patrol-fix refactor-patrol-review refactor-patrol-fix].each do |stage|
        assert budget.acquire(minimum_tokens: 123_456), stage
        record(budget, Time.utc(2026, 7, 16, 12), { input: 1, output: 0, cached: 0 }, stage: stage)
      end
    end
  end

  def test_launch_is_refused_only_when_its_initial_context_exceeds_the_ceiling
    with_budget(config(max_tokens_per_agent: 100)) do |budget|
      refute budget.acquire(minimum_tokens: 101)
      assert_equal "insufficient_launch_headroom", budget.last_exhaustion.fetch(:reason)
      assert_equal(
        { reason: "insufficient_launch_headroom", limit: 100, observed: 101 },
        budget.resource_exhaustion
      )
      assert_match(/required=101 tokens, available=100/, budget.exhaustion_message)

      assert budget.acquire(minimum_tokens: 100),
             "a rejected launch must release the project lock"
    end
  end

  def test_only_one_patrol_agent_can_hold_the_project_lock
    with_budget do |budget, dir, now|
      concurrent = Hive::Patrol::TokenBudget.new(dir, cfg: config, clock: -> { now })

      assert budget.acquire
      refute concurrent.acquire
      assert_equal "agent_in_flight", concurrent.last_exhaustion.fetch(:reason)
      assert_equal(
        { reason: "agent_in_flight", limit: 1, observed: 1 },
        concurrent.resource_exhaustion
      )
      assert_equal "patrol agent launch blocked (agent_in_flight)", concurrent.exhaustion_message

      record(budget, now, { input: 40, output: 0, cached: 0 })
      assert concurrent.acquire
      record(concurrent, now, { input: 10, output: 0, cached: 0 }, stage: "refactor-patrol-review")
    end
  end

  def test_projects_with_the_same_basename_do_not_share_a_lock
    with_tmp_dir do |dir|
      Hive::UsageDb.path = File.join(dir, "usage.db")
      first = File.join(dir, "one", "project")
      second = File.join(dir, "two", "project")
      budgets = [ first, second ].map do |root|
        Hive::Patrol::TokenBudget.new(root, cfg: config)
      end

      assert budgets.all?(&:acquire)
    ensure
      budgets&.each do |budget|
        budget.record!(
          result: {}, profile: Profile.new(:codex), stage: "patrol-review",
          started_at: Time.now.utc
        )
      end
    end
  end

  def test_metered_and_unmetered_launches_remain_usage_telemetry
    with_budget do |budget, dir, now|
      assert budget.acquire
      record(budget, now, { input: 4, output: 3, cached: 2 })

      assert budget.acquire
      record(
        budget, now, { input: 0, output: 0, cached: 0 },
        stage: "refactor-patrol-review"
      )

      activity = Hive::UsageDb.patrol_activity(
        scope: { project_slug: File.basename(dir) }, now: now
      )
      assert_equal 7, activity.fetch(:tokens)
      assert_equal 2, activity.fetch(:agent_spawns)
      assert_equal 1, activity.fetch(:unmetered_spawns)
      assert_equal 1, activity.fetch(:ordinary_agent_spawns)
      assert_equal 1, activity.fetch(:architecture_agent_spawns)
    end
  end

  def test_architecture_fix_usage_falls_back_to_configured_agent_name
    cfg = config.merge(
      "refactor_patrol" => { "auto_fix" => { "agent" => "pi" } }
    )
    with_budget(cfg) do |budget, dir, now|
      assert budget.acquire
      record(
        budget, now, { input: 1, output: 2, cached: 3 },
        stage: "refactor-patrol-fix", profile: Object.new
      )

      require "sqlite3"
      db = SQLite3::Database.new(Hive::UsageDb.path)
      assert_equal "pi", db.get_first_value("SELECT agent FROM token_usage")
      assert_equal File.basename(dir), db.get_first_value("SELECT project_slug FROM token_usage")
    ensure
      db&.close
    end
  end

  def test_usage_store_failure_does_not_become_an_admission_gate
    with_tmp_dir do |dir|
      Hive::UsageDb.path = dir
      budget = Hive::Patrol::TokenBudget.new(dir, cfg: config)

      assert budget.acquire
      _out, _err = capture_io do
        refute record(budget, Time.now.utc, { input: 1, output: 0, cached: 0 })
      end

      assert budget.acquire,
             "best-effort telemetry failure must still release the project lock"
    end
  end

  def test_launch_lock_open_failure_fails_closed_before_spawn
    with_budget do |budget|
      with_replaced_singleton_method(File, :open, ->(*) { raise Errno::EACCES }) do
        refute budget.acquire
      end

      assert_equal "launch_lock_unavailable", budget.last_exhaustion.fetch(:reason)
    end
  end

  def test_launch_lock_release_closes_handle_when_unlock_fails
    with_budget do |budget|
      closed = false
      handle = Object.new
      handle.define_singleton_method(:flock) { |_| raise IOError, "unlock failed" }
      handle.define_singleton_method(:close) { closed = true }
      budget.instance_variable_set(:@launch_lock, handle)

      assert_nil budget.send(:release_launch_lock)
      assert closed
      assert_nil budget.instance_variable_get(:@launch_lock)
    end
  end
end
