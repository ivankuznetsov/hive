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

  def config(**overrides)
    {
      "patrol" => {
        "max_tokens_per_cycle" => 100,
        "max_tokens_per_day" => 200,
        "max_agent_spawns_per_cycle" => 2,
        "max_agent_spawns_per_day" => 3,
        "max_budget_usd_per_agent" => 10
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

  def record(budget, now, usage)
    budget.record!(
      result: { status: :ok, usage: usage }, profile: Profile.new(:codex),
      stage: "patrol-review", started_at: now - 1
    )
  end

  def test_cycle_token_limit_stops_the_next_spawn
    with_budget do |budget, _dir, now|
      assert budget.acquire
      record(budget, now, input: 70, output: 20, cached: 10)

      refute budget.acquire
      assert_equal "cycle_token_limit", budget.last_exhaustion.fetch(:reason)
      assert_match(/cycle=100\/100 tokens/, budget.exhaustion_message)
    end
  end

  def test_unmetered_launches_are_recorded_and_bounded_by_spawn_limit
    with_budget(config(max_agent_spawns_per_cycle: 1)) do |budget, dir, now|
      assert budget.acquire
      record(budget, now, input: 0, output: 0, cached: 0)

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
      record(budget, now, input: 1, output: 0, cached: 0)

      next_cycle = Hive::Patrol::TokenBudget.new(
        dir, cfg: config(max_agent_spawns_per_day: 1), clock: -> { now }
      )
      refute next_cycle.acquire
      assert_equal "daily_agent_spawn_limit", next_cycle.last_exhaustion.fetch(:reason)
    end
  end

  def test_per_agent_dollar_cap_takes_the_lower_value
    with_budget do |budget|
      assert_equal 10.0, budget.max_budget_usd(100)
      assert_equal 5.0, budget.max_budget_usd(5)
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
