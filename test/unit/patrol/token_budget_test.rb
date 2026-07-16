require "test_helper"
require "hive/digest"
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

  def config(**overrides)
    {
      "patrol" => {
        "max_tokens_per_cycle" => 100,
        "max_tokens_per_day" => 200,
        "max_tokens_per_agent" => 60,
        "max_agent_spawns_per_cycle" => 2,
        "max_agent_spawns_per_day" => 3,
        "max_budget_usd_per_agent" => 10,
        "architecture_budget_multiplier" => 2
      }.merge(overrides.transform_keys(&:to_s))
    }
  end

  def with_budget(cfg = config)
    with_tmp_dir do |dir|
      Hive::UsageDb.path = File.join(dir, "usage.db")
      now = Time.utc(2026, 7, 16, 12)
      budget = Hive::Patrol::TokenBudget.new(dir, cfg: cfg, clock: -> { now })
      yield budget, dir, now
    end
  end

  def record(budget, now, usage, stage: "patrol-review")
    budget.record!(
      result: { status: :ok, usage: usage }, profile: Profile.new(:codex),
      stage: stage, started_at: now - 1
    )
  end

  def test_cycle_token_limit_stops_the_next_spawn
    with_budget do |budget, _dir, now|
      assert budget.acquire
      record(budget, now, { input: 70, output: 20, cached: 10 })
      snapshot = budget.snapshot
      assert_equal 100, snapshot.dig("cycle", "tokens")
      assert_equal 100, snapshot.dig("today", "tokens")
      assert_equal 2, snapshot.dig("limits", "architecture_budget_multiplier")

      refute budget.acquire
      assert_equal "cycle_token_limit", budget.last_exhaustion.fetch(:reason)
      assert_match(/cycle=100\/100 tokens/, budget.exhaustion_message)
    end
  end

  def test_unmetered_launches_are_recorded_and_bounded_by_spawn_limit
    with_budget(config(max_agent_spawns_per_cycle: 1)) do |budget, dir, now|
      assert budget.acquire
      record(budget, now, { input: 0, output: 0, cached: 0 })

      refute budget.acquire
      assert_equal "cycle_agent_spawn_limit", budget.last_exhaustion.fetch(:reason)
      activity = Hive::UsageDb.patrol_activity(
        scope: { project_slug: File.basename(dir) }, now: now
      )
      assert_equal 1, activity.fetch(:unmetered_spawns)
    end
  end

  def test_daily_spawn_limit_is_shared_across_budget_instances
    with_budget(config(max_agent_spawns_per_day: 1)) do |budget, dir, now|
      assert budget.acquire
      record(budget, now, { input: 1, output: 0, cached: 0 })

      next_cycle = Hive::Patrol::TokenBudget.new(
        dir, cfg: config(max_agent_spawns_per_day: 1), clock: -> { now }
      )
      refute next_cycle.acquire
      assert_equal "daily_agent_spawn_limit", next_cycle.last_exhaustion.fetch(:reason)
    end
  end

  def test_only_one_patrol_agent_can_hold_project_budget_headroom_in_flight
    with_budget do |budget, dir, now|
      concurrent = Hive::Patrol::TokenBudget.new(
        dir, cfg: config, clock: -> { now }
      )

      assert budget.acquire(stage: "patrol-review")
      refute concurrent.acquire(stage: "refactor-patrol-review")
      assert_equal "agent_in_flight", concurrent.last_exhaustion.fetch(:reason)

      record(budget, now, { input: 40, output: 0, cached: 0 })
      assert concurrent.acquire(stage: "refactor-patrol-review")
      record(
        concurrent, now, { input: 10, output: 0, cached: 0 },
        stage: "refactor-patrol-review"
      )
    end
  end

  def test_per_agent_budget_equivalent_cap_takes_the_lower_value
    with_budget do |budget|
      assert_equal 10.0, budget.max_budget_usd(100)
      assert_equal 5.0, budget.max_budget_usd(5)
    end
  end

  def test_per_agent_token_limit_is_explicit_and_architecture_gets_a_larger_allowance
    with_budget do |budget|
      assert_equal 60, budget.max_tokens(stage: "patrol-review")
      assert_equal 120, budget.max_tokens(stage: "refactor-patrol-review")
    end
  end

  def test_per_agent_token_limit_is_clamped_to_remaining_cycle_and_daily_budgets
    with_budget(config(max_tokens_per_cycle: 100, max_tokens_per_day: 150)) do |budget, _dir, now|
      assert budget.acquire(stage: "patrol-review")
      record(budget, now, { input: 55, output: 0, cached: 0 })

      assert_equal 45, budget.max_tokens(stage: "patrol-fix")
      assert_equal 95, budget.max_tokens(stage: "refactor-patrol-review")
    end

    with_budget(config(max_tokens_per_cycle: 200, max_tokens_per_day: 100)) do |budget, _dir, now|
      assert budget.acquire(stage: "patrol-review")
      record(budget, now, { input: 70, output: 0, cached: 0 })

      assert_equal 30, budget.max_tokens(stage: "patrol-fix")
      assert_equal 30, budget.max_tokens(stage: "refactor-patrol-review")
    end
  end

  def test_architecture_gets_doubled_cycle_and_spawn_limits_but_not_a_looser_native_budget_guard
    with_budget(config(max_tokens_per_day: 300, max_agent_spawns_per_cycle: 4)) do |budget, _dir, now|
      assert budget.acquire(stage: "patrol-review")
      record(budget, now, { input: 70, output: 20, cached: 10 })
      refute budget.acquire(stage: "patrol-fix")

      assert budget.acquire(stage: "refactor-patrol-review")
      record(
        budget, now, { input: 70, output: 20, cached: 10 },
        stage: "refactor-patrol-review"
      )
      refute budget.acquire(stage: "refactor-patrol-fix")
      assert_equal "cycle_token_limit", budget.last_exhaustion.fetch(:reason)
      assert_match(/cycle=200\/200 tokens/, budget.exhaustion_message)
      assert_equal 10.0, budget.max_budget_usd(100, stage: "refactor-patrol-review")
      assert_equal 10.0, budget.max_budget_usd(15, stage: "refactor-patrol-review")
      assert_equal 10, budget.max_budget_usd("invalid", stage: "refactor-patrol-review")
    end
  end

  def test_architecture_still_shares_daily_token_and_spawn_limits
    with_budget(config(max_tokens_per_day: 150, max_agent_spawns_per_cycle: 4)) do |budget, _dir, now|
      assert budget.acquire(stage: "patrol-review")
      record(budget, now, { input: 100, output: 0, cached: 0 })
      assert budget.acquire(stage: "refactor-patrol-review")
      record(
        budget, now, { input: 50, output: 0, cached: 0 },
        stage: "refactor-patrol-review"
      )

      refute budget.acquire(stage: "refactor-patrol-review")
      assert_equal "daily_token_limit", budget.last_exhaustion.fetch(:reason)
    end

    with_budget(config(max_agent_spawns_per_cycle: 1, max_agent_spawns_per_day: 2)) do |budget, _dir, now|
      assert budget.acquire(stage: "patrol-review")
      record(budget, now, { input: 1, output: 0, cached: 0 })
      refute budget.acquire(stage: "patrol-fix")
      assert budget.acquire(stage: "refactor-patrol-review")
      record(
        budget, now, { input: 1, output: 0, cached: 0 },
        stage: "refactor-patrol-review"
      )

      refute budget.acquire(stage: "refactor-patrol-fix")
      assert_equal "daily_agent_spawn_limit", budget.last_exhaustion.fetch(:reason)
    end
  end

  def test_architecture_fix_usage_falls_back_to_configured_agent_name
    cfg = config.merge(
      "refactor_patrol" => { "auto_fix" => { "agent" => "pi" } }
    )
    with_budget(cfg) do |budget, dir, now|
      assert budget.acquire(stage: "refactor-patrol-fix")
      budget.record!(
        result: { status: :ok, usage: { input: 1, output: 2, cached: 3 } },
        profile: Object.new, stage: "refactor-patrol-fix", started_at: now - 1
      )

      require "sqlite3"
      db = SQLite3::Database.new(Hive::UsageDb.path)
      assert_equal "pi", db.get_first_value("SELECT agent FROM token_usage")
      assert_equal File.basename(dir), db.get_first_value("SELECT project_slug FROM token_usage")
    ensure
      db&.close
    end
  end

  def test_unavailable_usage_store_fails_closed_before_spawn
    with_tmp_dir do |dir|
      Hive::UsageDb.path = dir
      budget = Hive::Patrol::TokenBudget.new(dir, cfg: config)

      _out, _err = capture_io { refute budget.acquire }

      assert_equal "usage_store_unavailable", budget.last_exhaustion.fetch(:reason)
    end
  end
end
