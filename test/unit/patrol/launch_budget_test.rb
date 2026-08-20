require "test_helper"
require "hive/patrol/launch_budget"

class PatrolLaunchBudgetTest < Minitest::Test
  include HiveTestHelper

  Profile = Struct.new(:name)

  def setup
    @old_path = Hive::UsageDb.path
  end

  def teardown
    Hive::UsageDb.path = @old_path
  end

  def config(max_agent_spawns_per_day: 2)
    { "patrol" => { "max_agent_spawns_per_day" => max_agent_spawns_per_day } }
  end

  def with_budget(cfg = config, now: Time.utc(2026, 8, 20, 12))
    with_tmp_dir do |dir|
      Hive::UsageDb.path = File.join(dir, "usage.db")
      budget = Hive::Patrol::LaunchBudget.new(dir, cfg: cfg, clock: -> { now })
      yield budget, dir, now
    end
  end

  def record(budget, now, stage:, usage: {})
    budget.record!(
      result: { status: :ok, usage: usage }, profile: Profile.new(:codex),
      stage: stage, started_at: now - 1
    )
  end

  def acquire(budget, now, stage: "patrol-review")
    budget.acquire(
      profile: Profile.new(:codex), stage: stage, started_at: now
    )
  end

  def test_daily_limit_is_shared_by_ordinary_and_architecture_patrol
    with_budget do |ordinary, dir, now|
      assert acquire(ordinary, now)
      record(
        ordinary, now, stage: "patrol-review",
        usage: { input: 1, output: 1, cached: 0 }
      )

      architecture = Hive::Patrol::LaunchBudget.new(
        dir, cfg: config, clock: -> { now }
      )
      assert acquire(architecture, now, stage: "refactor-patrol-review")
      record(architecture, now, stage: "refactor-patrol-review")

      next_cycle = Hive::Patrol::LaunchBudget.new(
        dir, cfg: config, clock: -> { now }
      )
      refute acquire(next_cycle, now)
      assert_equal "daily_agent_spawn_limit", next_cycle.last_exhaustion.fetch(:reason)
      assert_equal(
        { reason: "daily_agent_spawn_limit", limit: 2, observed: 2 },
        next_cycle.resource_exhaustion
      )
    end
  end

  def test_limit_counts_unmetered_launches_without_using_token_totals
    with_budget(config(max_agent_spawns_per_day: 1)) do |budget, _dir, now|
      assert acquire(budget, now)
      record(budget, now, stage: "patrol-review")

      assert_equal 0, budget.remaining_launches
      assert_equal "daily_agent_spawn_limit", budget.resource_exhaustion.fetch(:reason)
      refute acquire(budget, now)
      assert_match(/1\/1 launches today/, budget.exhaustion_message)
      refute_respond_to budget, :max_tokens
    end
  end

  def test_daily_limit_resets_at_the_next_utc_day
    now = Time.utc(2026, 8, 20, 23, 59)
    with_budget(config(max_agent_spawns_per_day: 1), now: now) do |budget, dir, _|
      assert acquire(budget, now, stage: "patrol-fix")
      record(budget, now, stage: "patrol-fix")

      tomorrow = now + 120
      next_day = Hive::Patrol::LaunchBudget.new(
        dir, cfg: config(max_agent_spawns_per_day: 1), clock: -> { tomorrow }
      )
      assert acquire(next_day, tomorrow, stage: "refactor-patrol-fix")
      record(next_day, tomorrow, stage: "refactor-patrol-fix")
    end
  end

  def test_daily_exhaustion_backoff_reaches_the_next_utc_day
    now = Time.utc(2026, 8, 20, 12, 30)

    assert_equal 41_400, Hive::Patrol::LaunchBudget.resource_exhaustion_backoff_sec(
      [ "daily_agent_spawn_limit" ], now: now, fallback: 60
    )
    assert_equal 60, Hive::Patrol::LaunchBudget.resource_exhaustion_backoff_sec(
      [ "agent_in_flight" ], now: now, fallback: 60
    )
    assert_equal 30, Hive::Patrol::LaunchBudget.resource_exhaustion_backoff_sec(
      [ "daily_agent_spawn_limit" ], now: Time.utc(2026, 8, 20, 23, 59, 30),
      fallback: 3600
    )
  end

  def test_only_one_patrol_agent_can_hold_the_project_lock
    with_budget do |budget, dir, now|
      concurrent = Hive::Patrol::LaunchBudget.new(dir, cfg: config, clock: -> { now })

      assert acquire(budget, now)
      refute acquire(concurrent, now)
      assert_equal "agent_in_flight", concurrent.last_exhaustion.fetch(:reason)

      record(budget, now, stage: "patrol-review")
      assert acquire(concurrent, now, stage: "refactor-patrol-review")
      record(concurrent, now, stage: "refactor-patrol-review")
    end
  end

  def test_projects_with_the_same_basename_do_not_share_a_lock
    with_tmp_dir do |dir|
      Hive::UsageDb.path = File.join(dir, "usage.db")
      first = File.join(dir, "one", "project")
      second = File.join(dir, "two", "project")
      budgets = [ [ first, "one" ], [ second, "two" ] ].map do |root, name|
        Hive::Patrol::LaunchBudget.new(
          root, cfg: config(max_agent_spawns_per_day: 1), project_name: name
        )
      end

      now = Time.utc(2026, 8, 20, 12)
      assert acquire(budgets.fetch(0), now)
      record(budgets.fetch(0), now, stage: "patrol-review")
      assert_equal 1, budgets.fetch(1).remaining_launches
      assert acquire(budgets.fetch(1), now)
      record(budgets.fetch(1), now, stage: "patrol-review")
    end
  end

  def test_reservation_survives_controller_loss_before_final_record
    with_budget(config(max_agent_spawns_per_day: 1)) do |budget, dir, now|
      assert acquire(budget, now)
      budget.send(:release_launch_lock)

      restarted = Hive::Patrol::LaunchBudget.new(
        dir, cfg: config(max_agent_spawns_per_day: 1), clock: -> { now }
      )
      refute acquire(restarted, now)
      assert_equal "daily_agent_spawn_limit", restarted.last_exhaustion.fetch(:reason)
    end
  end

  def test_final_telemetry_failure_keeps_the_reserved_launch_counted
    with_tmp_dir do |dir|
      Hive::UsageDb.path = File.join(dir, "usage.db")
      calls = 0
      flaky_store = Object.new
      flaky_store.define_singleton_method(:path) { Hive::UsageDb.path }
      flaky_store.define_singleton_method(:patrol_activity) do |**args|
        Hive::UsageDb.patrol_activity(**args)
      end
      flaky_store.define_singleton_method(:record!) do |**args|
        calls += 1
        calls == 2 ? false : Hive::UsageDb.record!(**args)
      end
      now = Time.utc(2026, 8, 20, 12)
      budget = Hive::Patrol::LaunchBudget.new(
        dir, cfg: config(max_agent_spawns_per_day: 1), usage_db: flaky_store,
        clock: -> { now }
      )

      assert acquire(budget, now)
      _out, _err = capture_io do
        refute record(budget, now, stage: "patrol-review")
      end

      restarted = Hive::Patrol::LaunchBudget.new(
        dir, cfg: config(max_agent_spawns_per_day: 1), usage_db: flaky_store,
        clock: -> { now }
      )
      refute acquire(restarted, now)
      assert_equal "daily_agent_spawn_limit", restarted.last_exhaustion.fetch(:reason)
    end
  end

  def test_reservation_rejection_fails_closed_and_releases_the_lock
    with_tmp_dir do |dir|
      store = Object.new
      store.define_singleton_method(:path) { File.join(dir, "usage.db") }
      store.define_singleton_method(:patrol_activity) do |**|
        { available: true, agent_spawns: 0 }
      end
      store.define_singleton_method(:record!) { |**| false }
      budget = Hive::Patrol::LaunchBudget.new(dir, cfg: config, usage_db: store)

      refute acquire(budget, Time.now.utc)
      assert_equal "usage_store_unavailable", budget.last_exhaustion.fetch(:reason)
      assert_nil budget.instance_variable_get(:@launch_lock)
    end
  end

  def test_reservation_exception_fails_closed_and_reports_the_error
    with_tmp_dir do |dir|
      store = Object.new
      store.define_singleton_method(:path) { File.join(dir, "usage.db") }
      store.define_singleton_method(:patrol_activity) do |**|
        { available: true, agent_spawns: 0 }
      end
      store.define_singleton_method(:record!) { |**| raise IOError, "disk unavailable" }
      budget = Hive::Patrol::LaunchBudget.new(dir, cfg: config, usage_db: store)

      _out, err = capture_io { refute acquire(budget, Time.now.utc) }

      assert_equal "usage_store_unavailable", budget.last_exhaustion.fetch(:reason)
      assert_match(/launch reservation failed: disk unavailable/, err)
      assert_nil budget.instance_variable_get(:@launch_lock)
    end
  end

  def test_unavailable_activity_has_no_remaining_capacity
    with_tmp_dir do |dir|
      store = Object.new
      store.define_singleton_method(:path) { File.join(dir, "usage.db") }
      store.define_singleton_method(:patrol_activity) do |**|
        { available: false, agent_spawns: 0 }
      end
      budget = Hive::Patrol::LaunchBudget.new(dir, cfg: config, usage_db: store)

      assert_equal 0, budget.remaining_launches
      assert_equal "usage_store_unavailable", budget.last_exhaustion.fetch(:reason)
      assert_equal "patrol agent launch blocked (usage_store_unavailable)",
                   budget.exhaustion_message
    end
  end

  def test_architecture_fix_uses_the_configured_fix_agent_without_a_profile_name
    with_tmp_dir do |dir|
      agents = []
      store = Object.new
      store.define_singleton_method(:path) { File.join(dir, "usage.db") }
      store.define_singleton_method(:patrol_activity) do |**|
        { available: true, agent_spawns: 0 }
      end
      store.define_singleton_method(:record!) do |**args|
        agents << args.fetch(:agent)
        true
      end
      cfg = config.merge(
        "refactor_patrol" => { "auto_fix" => { "agent" => "grok" } }
      )
      budget = Hive::Patrol::LaunchBudget.new(dir, cfg: cfg, usage_db: store)
      profile = Object.new
      now = Time.utc(2026, 8, 20, 12)

      assert budget.acquire(
        profile: profile, stage: "refactor-patrol-fix", started_at: now
      )
      assert budget.record!(
        result: { status: :ok }, profile: profile,
        stage: "refactor-patrol-fix", started_at: now
      )
      assert_equal [ "grok", "grok" ], agents
    end
  end

  def test_usage_store_failure_blocks_remaining_launches_in_the_cycle
    with_tmp_dir do |dir|
      Hive::UsageDb.path = dir
      budget = Hive::Patrol::LaunchBudget.new(dir, cfg: config)

      refute acquire(budget, Time.now.utc)
      assert_equal "usage_store_unavailable", budget.last_exhaustion.fetch(:reason)
    end
  end

  def test_launch_lock_open_failure_fails_closed_before_spawn
    with_budget do |budget|
      with_replaced_singleton_method(File, :open, ->(*) { raise Errno::EACCES }) do
        refute acquire(budget, Time.now.utc)
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
