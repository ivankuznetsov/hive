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
    @previous_usage_database = Hive::UsageDb.instance_variable_get(:@database)
    Hive::UsageDb.database = @database
    @usage = Hive::UsageDb
  end

  def teardown
    Hive::UsageDb.database = @previous_usage_database
    @database&.disconnect
  end

  def test_engines_have_independent_daily_lanes_and_restart_does_not_refund
    ordinary = budget(engine: :ordinary, limit: 2)
    architecture = budget(engine: :architecture, limit: 2)
    2.times { |index| assert acquire(ordinary, "patrol-review", id: "o-#{index}") }

    refute acquire(ordinary, "patrol-review", id: "o-3")
    assert_match(/2\/2 launches today/, ordinary.exhaustion_message)
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
    rows = @database.read do |db|
      db[:token_usage].where(source: "patrol_discovery_launch").count
    end
    assert_equal 2, rows
  end

  def test_allowance_is_derived_from_existing_token_history
    3.times do |index|
      Hive::UsageDb.reserve_patrol_discovery!(
        session_id: "history-#{index}", agent: "codex", project_slug: "demo",
        stage: "patrol-review", started_at: NOW, limit: 4, database: @database
      )
    end

    snapshot = budget(engine: :ordinary).allowance_snapshot
    assert_equal "available", snapshot.fetch(:status)
    assert_equal 3, snapshot.fetch(:used)
    assert_equal 1, snapshot.fetch(:remaining)
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
    row = @database.read do |db|
      db[:token_usage].where(session_id: "stable-id").first
    end
    assert_equal "telemetry-name", row.fetch(:project_slug)
  end

  def test_usage_updates_the_reservation_row_instead_of_inserting_a_second_row
    subject = budget(engine: :ordinary)
    assert acquire(subject, "patrol-review", id: "stable-id")
    assert subject.record!(
      result: { status: :ok, usage: { input: 7, output: 3, cached: 1 } },
      profile: Profile.new(:codex), stage: "patrol-review", started_at: NOW
    )

    rows = @database.read { |db| db[:token_usage].where(session_id: "stable-id").all }
    assert_equal 1, rows.length
    assert_equal 7, rows.first.fetch(:input)
    assert_equal "patrol-review", rows.first.fetch(:stage)
    assert rows.first.fetch(:ended_at)
  end

  def test_non_discovery_stages_record_telemetry_without_charging_allowance
    subject = budget(engine: :ordinary, limit: 2)
    assert acquire(subject, "patrol-fix")
    assert subject.record!(
      result: { status: :ok, usage: {} }, profile: Profile.new(:codex),
      stage: "patrol-fix", started_at: NOW
    )
    assert_equal 2, subject.remaining_launches
    assert_equal 1, @database.read { |db| db[:token_usage].count }
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

  def test_off_mode_has_no_discovery_headroom
    subject = Hive::Patrol::LaunchBudget.new(
      @root, cfg: { "patrol" => { "mode" => "off" } },
      project_id: "project-1", project_name: "demo", engine: :ordinary,
      usage_db: @usage, database: @database, clock: -> { NOW }
    )
    ensure_project("project-1")

    assert_equal 0, subject.remaining_launches
  end

  def test_allowance_fails_closed_when_token_history_is_unavailable
    broken = Object.new
    broken.define_singleton_method(:read) { raise IOError, "read failed" }
    broken.define_singleton_method(:transaction) { raise IOError, "write failed" }
    subject = Hive::Patrol::LaunchBudget.new(
      @root, cfg: { "patrol" => {} }, project_id: "project-1",
      project_name: "demo", engine: :ordinary, usage_db: @usage,
      database: broken, clock: -> { NOW }
    )

    assert_equal "unavailable", subject.allowance_snapshot.fetch(:status)
    assert_equal "usage_store_unavailable", subject.resource_exhaustion.fetch(:reason)
  end

  def test_unknown_exhaustion_message_and_failed_telemetry_are_nonfatal
    subject = budget(engine: :ordinary)
    assert_match(/blocked \(unknown\)/, subject.exhaustion_message)

    usage = Object.new
    usage.define_singleton_method(:record!) { |**| raise IOError, "telemetry down" }
    unmetered = budget(engine: :ordinary, usage_db: usage)
    _out, err = capture_io do
      assert acquire(unmetered, "patrol-fix")
    end
    assert_match(/patrol usage reservation failed: telemetry down/, err)
  end

  def test_unregistered_project_identity_fails_closed
    subject = Hive::Patrol::LaunchBudget.new(
      File.join(@root, "missing"), cfg: { "patrol" => {} },
      project_name: "missing", engine: :ordinary,
      usage_db: @usage, database: @database, clock: -> { NOW }
    )

    snapshot = subject.allowance_snapshot
    assert_equal "unavailable", snapshot.fetch(:status)
    assert_equal "usage_store_unavailable", subject.resource_exhaustion.fetch(:reason)
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
end
