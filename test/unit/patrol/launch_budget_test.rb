require "test_helper"
require "hive/patrol/launch_budget"

class PatrolLaunchBudgetTest < Minitest::Test
  include HiveTestHelper

  Profile = Struct.new(:name)
  NOW = Time.utc(2026, 8, 20, 12)

  def setup
    @old_path = Hive::UsageDb.path
  end

  def teardown
    Hive::UsageDb.path = @old_path
  end

  def config(limit = 4, mode: nil)
    {
      "patrol" => {
        "scheduled_discovery_launches_per_engine_per_day" => limit
      }.tap { |patrol| patrol["mode"] = mode if mode }
    }
  end

  def budget(root, engine:, project_id: "project-1", project_name: "demo",
             now: NOW, limit: 4, **options)
    Hive::Patrol::LaunchBudget.new(
      root, cfg: config(limit), project_id: project_id,
      project_name: project_name, engine: engine, clock: -> { now }, **options
    )
  end

  def acquire(subject, stage, at: NOW, id: nil)
    subject.acquire(
      profile: Profile.new(:codex), stage: stage, started_at: at,
      reservation_id: id
    )
  end

  def finish(subject, stage, at: NOW, usage: {})
    subject.record!(
      result: { status: :ok, usage: usage }, profile: Profile.new(:codex),
      stage: stage, started_at: at
    )
  end

  def test_ordinary_and_architecture_have_independent_exact_lanes
    with_tmp_dir do |dir|
      Hive::UsageDb.path = File.join(dir, "usage.db")
      ordinary = budget(dir, engine: :ordinary, limit: 2)
      architecture = budget(dir, engine: :architecture, limit: 2)
      2.times do |index|
        assert acquire(ordinary, "patrol-review", id: "ordinary-#{index}")
        finish(ordinary, "patrol-review")
      end

      refute acquire(ordinary, "patrol-review", id: "ordinary-3")
      assert_equal 2, architecture.remaining_launches
      ordinary_snapshot = ordinary.allowance_snapshot
      assert_equal(
        { limit: 2, used: 2, remaining: 0, status: "exhausted" },
        ordinary_snapshot.slice(:limit, :used, :remaining, :status)
      )
      2.times do |index|
        assert acquire(architecture, "refactor-patrol-review", id: "architecture-#{index}")
        finish(architecture, "refactor-patrol-review")
      end
      refute acquire(architecture, "refactor-patrol-review", id: "architecture-3")
    end
  end

  def test_reservation_survives_restart_before_token_recording
    with_tmp_dir do |dir|
      Hive::UsageDb.path = File.join(dir, "usage.db")
      assert acquire(budget(dir, engine: :ordinary, limit: 1), "patrol-review", id: "launch-1")

      restarted = budget(dir, engine: :ordinary, limit: 1)
      assert_equal 0, restarted.remaining_launches
      assert_equal "daily_agent_spawn_limit", restarted.resource_exhaustion.fetch(:reason)
    end
  end

  def test_telemetry_failure_does_not_decide_admission
    with_tmp_dir do |dir|
      store = Object.new
      store.define_singleton_method(:path) { File.join(dir, "unavailable", "usage.db") }
      store.define_singleton_method(:patrol_discovery_seed) do |**|
        { available: true, ordinary: { count: 0, ambiguous: 0 },
          architecture: { count: 0, ambiguous: 0 } }
      end
      store.define_singleton_method(:record!) { |**| false }
      subject = budget(dir, engine: :ordinary, limit: 1, usage_db: store)

      _out, err = capture_io do
        assert acquire(subject, "patrol-review", id: "launch-1")
        refute finish(subject, "patrol-review")
      end
      assert_match(/continuing without token telemetry/, err)
      assert_equal 0, subject.remaining_launches
    end
  end

  def test_transient_upgrade_seed_failure_retries_without_parking_the_day
    with_tmp_dir do |dir|
      calls = 0
      store = Object.new
      store.define_singleton_method(:path) { File.join(dir, "usage.db") }
      store.define_singleton_method(:patrol_discovery_seed) do |**|
        calls += 1
        if calls == 1
          { available: false, ordinary: { count: 0, ambiguous: 0 },
            architecture: { count: 0, ambiguous: 0 } }
        else
          { available: true, ordinary: { count: 0, ambiguous: 0 },
            architecture: { count: 0, ambiguous: 0 } }
        end
      end
      subject = budget(dir, engine: :ordinary, usage_db: store)

      first = subject.allowance_snapshot
      assert_equal "unavailable", first.fetch(:status)
      assert_equal 0, first.fetch(:remaining)

      recovered = subject.allowance_snapshot
      assert_equal "available", recovered.fetch(:status)
      assert_equal 4, recovered.fetch(:remaining)
      assert_equal 2, calls
    end
  end

  def test_fix_review_and_action_telemetry_do_not_consume_discovery
    with_tmp_dir do |dir|
      Hive::UsageDb.path = File.join(dir, "usage.db")
      subject = budget(dir, engine: :ordinary, limit: 2)
      %w[patrol-fix refactor-patrol-fix patrol-fix-review].each do |stage|
        assert acquire(subject, stage)
        finish(subject, stage)
      end
      assert_equal 2, subject.remaining_launches

      post_merge = budget(
        dir, engine: :architecture, limit: 2, charge_discovery: false
      )
      assert acquire(post_merge, "refactor-patrol-review")
      finish(post_merge, "refactor-patrol-review")
      assert_equal 2, budget(dir, engine: :architecture, limit: 2).remaining_launches
    end
  end

  def test_mode_down_and_up_change_headroom_without_reset
    with_tmp_dir do |dir|
      Hive::UsageDb.path = File.join(dir, "usage.db")
      high = budget(dir, engine: :ordinary, limit: 8)
      6.times { |index| assert acquire(high, "patrol-review", id: "h-#{index}") }
      assert_equal 2, high.remaining_launches
      assert_equal 0, budget(dir, engine: :ordinary, limit: 4).remaining_launches
      assert_equal 10, budget(dir, engine: :ordinary, limit: 16).remaining_launches
    end
  end

  def test_off_mode_does_not_grant_discovery_allowance
    with_tmp_dir do |dir|
      Hive::UsageDb.path = File.join(dir, "usage.db")
      subject = Hive::Patrol::LaunchBudget.new(
        dir,
        cfg: config(8, mode: "off"),
        project_id: "project-1",
        project_name: "demo",
        engine: :ordinary,
        clock: -> { NOW }
      )

      refute acquire(subject, "patrol-review", id: "disabled")
      assert_equal 0, subject.remaining_launches
      assert_equal "daily_agent_spawn_limit", subject.resource_exhaustion.fetch(:reason)
    end
  end

  def test_observed_utc_dates_are_retained_across_forward_jump_and_rollback
    with_tmp_dir do |dir|
      Hive::UsageDb.path = File.join(dir, "usage.db")
      day_one = NOW
      day_three = NOW + (2 * 86_400)
      assert acquire(budget(dir, engine: :ordinary, now: day_one, limit: 1), "patrol-review", at: day_one, id: "d1")
      assert acquire(budget(dir, engine: :ordinary, now: day_three, limit: 1), "patrol-review", at: day_three, id: "d3")

      rolled_back = budget(dir, engine: :ordinary, now: day_one, limit: 1)
      assert_equal 0, rolled_back.remaining_launches
      assert_equal "daily_agent_spawn_limit", rolled_back.resource_exhaustion.fetch(:reason)
      assert_equal %w[2026-08-20.json 2026-08-22.json], Dir.children(
        "#{Hive::UsageDb.path}.patrol-discovery-allowances/dates"
      ).sort
    end
  end

  def test_stable_project_ids_survive_moves_and_separate_same_basenames
    with_tmp_dir do |dir|
      Hive::UsageDb.path = File.join(dir, "usage.db")
      first_path = File.join(dir, "one", "app")
      moved_path = File.join(dir, "moved", "app")
      other_path = File.join(dir, "two", "app")
      assert acquire(budget(first_path, engine: :ordinary, project_id: "stable", limit: 1), "patrol-review", id: "one")
      assert_equal 0, budget(moved_path, engine: :ordinary, project_id: "stable", limit: 1).remaining_launches
      assert_equal 1, budget(
        other_path, engine: :ordinary, project_id: "other",
        project_name: "other-project", limit: 1
      ).remaining_launches
    end
  end

  def test_upgrade_seed_is_per_engine_and_excludes_fixes
    with_tmp_dir do |dir|
      Hive::UsageDb.path = File.join(dir, "usage.db")
      %w[patrol-review refactor-patrol-review patrol-fix refactor-patrol-fix].each do |stage|
        Hive::UsageDb.record!(
          agent: "codex", model: nil, project_slug: "demo", task_slug: stage,
          stage: stage, started_at: NOW, ended_at: NOW,
          input: 1, output: 1, cached: 0
        )
      end

      assert_equal 3, budget(dir, engine: :ordinary).remaining_launches
      assert_equal 3, budget(dir, engine: :architecture).remaining_launches
    end
  end

  def test_ambiguous_legacy_attribution_parks_only_its_lane_until_next_day
    with_tmp_dir do |dir|
      Hive::UsageDb.path = File.join(dir, "usage.db")
      Hive::UsageDb.record!(
        agent: "codex", model: nil, project_slug: "demo", task_slug: "patrol",
        stage: "patrol-unknown", started_at: NOW, ended_at: NOW,
        input: 0, output: 0, cached: 0
      )
      ordinary = budget(dir, engine: :ordinary)
      assert_equal 0, ordinary.remaining_launches
      assert_equal "legacy_attribution_ambiguous", ordinary.resource_exhaustion.fetch(:reason)
      assert_equal 4, budget(dir, engine: :architecture).remaining_launches
      assert_equal 4, budget(dir, engine: :ordinary, now: NOW + 86_400).remaining_launches
    end
  end

  def test_provider_hold_survives_restart_and_midnight_and_parks_only_one_lane
    with_tmp_dir do |dir|
      Hive::UsageDb.path = File.join(dir, "usage.db")
      before_midnight = Time.utc(2026, 8, 20, 23, 50)
      retry_at = before_midnight + 1800
      subject = budget(dir, engine: :ordinary, now: before_midnight)
      assert subject.park!(retry_at: retry_at, reason: "token_limit")

      after_midnight = before_midnight + 900
      restarted = budget(dir, engine: :ordinary, now: after_midnight)
      assert_equal 0, restarted.remaining_launches
      assert_equal retry_at.iso8601(6), restarted.resource_exhaustion.fetch(:retry_at)
      assert_equal 4, budget(dir, engine: :architecture, now: after_midnight).remaining_launches
      assert_equal 4, budget(dir, engine: :ordinary, now: retry_at).remaining_launches
    end
  end

  def test_atomic_reservations_never_exceed_lane_limit
    with_tmp_dir do |dir|
      Hive::UsageDb.path = File.join(dir, "usage.db")
      results = 12.times.map do |index|
        Thread.new do
          acquire(
            budget(dir, engine: :ordinary, limit: 4), "patrol-review",
            id: "thread-#{index}"
          )
        end
      end.map(&:value)
      assert_equal 4, results.count(true)
      assert_equal 8, results.count(false)
    end
  end

  def test_corrupt_or_symlinked_ledger_fails_closed
    with_tmp_dir do |dir|
      Hive::UsageDb.path = File.join(dir, "usage.db")
      root = "#{Hive::UsageDb.path}.patrol-discovery-allowances"
      dates = File.join(root, "dates")
      day = File.join(dates, "2026-08-20.json")
      FileUtils.mkdir_p(dates)
      File.write(day, "{}")
      subject = budget(dir, engine: :ordinary)
      assert_equal 0, subject.remaining_launches
      assert_equal "allowance_store_unavailable", subject.resource_exhaustion.fetch(:reason)

      File.delete(day)
      File.symlink("/dev/null", day)
      assert_equal 0, budget(dir, engine: :ordinary).remaining_launches
    end
  end

  def test_daily_exhaustion_backoff_reaches_next_utc_boundary
    now = Time.utc(2026, 8, 20, 12, 30)
    assert_equal 41_400, Hive::Patrol::LaunchBudget.resource_exhaustion_backoff_sec(
      [ "daily_agent_spawn_limit" ], now: now, fallback: 60
    )
    assert_equal 60, Hive::Patrol::LaunchBudget.resource_exhaustion_backoff_sec(
      [ "token_limit" ], now: now, fallback: 60
    )
  end
end
