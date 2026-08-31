require "test_helper"
require "hive/patrol/launch_budget"

class PatrolLaunchBudgetTest < Minitest::Test
  include HiveTestHelper

  Profile = Struct.new(:name)
  NOW = Time.utc(2026, 8, 20, 12)

  def setup
    @root = tracked_tmp_dir("hive-test-patrol-budget")
    @database = Hive::RuntimeControlPlane::Database.new(
      path: File.join(@root, "runtime.sqlite3")
    ).migrate!
    @usage = usage_store
  end

  def teardown
    @database&.disconnect
  end

  def test_engines_have_independent_daily_lanes_and_restart_does_not_refund
    ordinary = budget(engine: :ordinary, limit: 2)
    architecture = budget(engine: :architecture, limit: 2)
    2.times { |index| assert acquire(ordinary, "patrol-review", id: "o-#{index}") }

    refute acquire(ordinary, "patrol-review", id: "o-3")
    assert_equal 2, architecture.remaining_launches
    assert_equal 0, budget(engine: :ordinary, limit: 2).remaining_launches
  end

  def test_reservation_is_idempotent_and_mode_changes_only_headroom
    high = budget(engine: :ordinary, limit: 8)
    6.times { |index| assert acquire(high, "patrol-review", id: "launch-#{index}") }
    assert acquire(high, "patrol-review", id: "launch-1")

    assert_equal 0, budget(engine: :ordinary, limit: 4).remaining_launches
    assert_equal 10, budget(engine: :ordinary, limit: 16).remaining_launches
  end

  def test_utc_day_reset_keeps_old_rows_without_reusing_allowance
    assert acquire(budget(engine: :ordinary, now: NOW, limit: 1), "patrol-review", id: "day-one")
    tomorrow = NOW + 86_400
    assert acquire(
      budget(engine: :ordinary, now: tomorrow, limit: 1),
      "patrol-review", at: tomorrow, id: "day-two"
    )

    assert_equal 0, budget(engine: :ordinary, now: NOW, limit: 1).remaining_launches
    rows = @database.read { |db| db[:patrol_allowances].where(kind: "ordinary").count }
    assert_equal 2, rows
  end

  def test_provider_hold_survives_restart_and_midnight_but_is_lane_scoped
    before_midnight = Time.utc(2026, 8, 20, 23, 50)
    retry_at = before_midnight + 1800
    subject = budget(engine: :ordinary, now: before_midnight)
    assert subject.park!(retry_at: retry_at, reason: "token_limit")

    after_midnight = before_midnight + 900
    restarted = budget(engine: :ordinary, now: after_midnight)
    assert_equal "provider_backoff", restarted.allowance_snapshot.fetch(:status)
    assert_equal 4, budget(engine: :architecture, now: after_midnight).remaining_launches
    assert_equal 4, budget(engine: :ordinary, now: retry_at).remaining_launches
  end

  def test_missing_lane_starts_empty_without_consulting_usage_history
    usage = usage_store
    usage.define_singleton_method(:patrol_discovery_seed) do |**|
      raise "runtime allowance must not reconstruct legacy state"
    end
    subject = budget(engine: :ordinary, usage_db: usage)

    assert_equal "available", subject.allowance_snapshot.fetch(:status)
    assert_equal 4, subject.remaining_launches
  end

  def test_capacity_reads_do_not_create_an_empty_lane
    subject = budget(engine: :ordinary)
    @database.define_singleton_method(:transaction) do |*|
      raise "capacity read attempted a write transaction"
    end

    assert_equal 4, subject.remaining_launches
    assert_equal "available", subject.allowance_snapshot.fetch(:status)
  end

  def test_project_identity_is_resolved_from_the_registered_observed_path
    ensure_project("stable-project")
    @database.transaction do |db|
      db[:projects].where(project_id: "stable-project").update(
        observed_path: @root, state_root_path: File.join(@root, ".hive-state")
      )
    end
    subject = Hive::Patrol::LaunchBudget.new(
      @root,
      cfg: { "patrol" => { "scheduled_discovery_launches_per_engine_per_day" => 1 } },
      project_name: "telemetry-name", engine: :ordinary,
      usage_db: @usage, database: @database, clock: -> { NOW }
    )

    assert acquire(subject, "patrol-review", id: "stable-id")
    row = @database.read { |db| db[:patrol_allowances].where(kind: "ordinary").first }
    assert_equal "stable-project", row.fetch(:project_id)
  end

  def test_reservation_safety_bound_fails_closed_without_mutating_the_lane
    ensure_project("project-1")
    ids = Array.new(Hive::Patrol::LaunchBudget::MAX_RESERVATIONS_PER_LANE) do |index|
      "r#{index}"
    end
    timestamp = Hive::RuntimeControlPlane::Codec.dump_time(NOW)
    @database.transaction do |db|
      db[:patrol_allowances].insert(
        project_id: "project-1", kind: "ordinary", window_key: "2026-08-20",
        used: ids.length, limit_value: ids.length + 1, revision: 0,
        reservation_ids_json: Hive::RuntimeControlPlane::Codec.dump_json(ids),
        updated_at: timestamp
      )
    end
    subject = budget(engine: :ordinary, limit: ids.length + 1)

    refute acquire(subject, "patrol-review", id: "overflow")
    row = @database.read { |db| db[:patrol_allowances].where(kind: "ordinary").first }
    assert_equal ids.length, row.fetch(:used)
    assert_equal 0, row.fetch(:revision)
    assert_equal "allowance_store_unavailable", subject.resource_exhaustion.fetch(:reason)
  end

  def test_non_discovery_stages_record_telemetry_without_charging_allowance
    subject = budget(engine: :ordinary, limit: 2)
    assert acquire(subject, "patrol-fix")
    assert subject.record!(
      result: { status: :ok, usage: {} }, profile: Profile.new(:codex),
      stage: "patrol-fix", started_at: NOW
    )
    assert_equal 2, subject.remaining_launches
    assert_equal 2, @usage.recorded.length
  end

  def test_multiprocess_contention_never_exceeds_limit
    readers = []
    children = 12.times.map do |index|
      reader, writer = IO.pipe
      readers << reader
      Hive::RuntimeControlPlane::ProcessGuard.fork do
        reader.close
        result = acquire(budget(engine: :ordinary, limit: 4), "patrol-review", id: "p-#{index}")
        writer.write(result ? "1" : "0")
        writer.close
      end.tap { writer.close }
    end
    results = readers.map(&:read)
    children.each { |pid| Process.wait(pid) }

    assert_equal 4, results.count("1")
    assert_equal 8, results.count("0")
    assert_equal 0, budget(engine: :ordinary, limit: 4).remaining_launches
  ensure
    readers.each { |reader| reader.close unless reader.closed? }
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

  private

  def budget(engine:, now: NOW, limit: 4, project_id: "project-1", usage_db: @usage)
    ensure_project(project_id)
    Hive::Patrol::LaunchBudget.new(
      @root,
      cfg: { "patrol" => { "scheduled_discovery_launches_per_engine_per_day" => limit } },
      project_id: project_id, project_name: "demo", engine: engine,
      usage_db: usage_db, database: @database, clock: -> { now }
    )
  end

  def acquire(subject, stage, at: NOW, id: nil)
    subject.acquire(
      profile: Profile.new(:codex), stage: stage, started_at: at,
      reservation_id: id
    )
  end

  def ensure_project(project_id)
    timestamp = Hive::RuntimeControlPlane::Codec.dump_time(NOW)
    @database.transaction do |db|
      installation = db[:installations].get(:installation_id)
      db[:projects].insert_conflict.insert(
        project_id: project_id, installation_id: installation,
        registration_id: project_id, name: project_id,
        observed_path: File.join(@root, project_id),
        state_root_path: File.join(@root, project_id, ".hive-state"),
        active: 1, registered_at: timestamp, last_observed_at: timestamp
      )
    end
  end

  def usage_store
    store = Struct.new(:recorded).new([])
    store.define_singleton_method(:record!) do |**attributes|
      recorded << attributes
      true
    end
    store
  end
end
