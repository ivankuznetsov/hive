require "test_helper"
require "tmpdir"
require "hive/task_meta"
require "hive/daemon/display_name_backfiller"
require "hive/daemon/status_consumer"

# Backfiller's job: for tasks whose meta.yml display_name is nil/empty,
# fire-and-forget `hive generate-name <folder>` exactly once per tick
# per task, bounded by max_per_tick, never re-spawning an inflight
# folder, and logging-without-spawning under dry_run. It must never
# raise out of #backfill. These tests pin those branches with an
# injected fake spawn so no real subprocess is started.
class HiveDaemonDisplayNameBackfillerTest < Minitest::Test
  include HiveTestHelper

  Row = Hive::Daemon::StatusConsumer::Row

  class FakeLogger
    attr_reader :events
    def initialize
      @events = []
    end

    def event(name, **attrs)
      @events << [ name, attrs ]
    end
  end

  # Records each spawn call's folder and hands back monotonically
  # increasing fake pids so inflight tracking can be exercised without
  # touching Process.spawn.
  class FakeSpawn
    attr_reader :calls

    # `pid` defaults to a genuinely-live pid (the test process itself)
    # so the backfiller's liveness-based reap keeps it inflight, exactly
    # as a still-running generate-name child would. Pass return_pid:
    # false to simulate a failed spawn.
    def initialize(return_pid: true, pid: Process.pid)
      @calls = []
      @pid = pid
      @return_pid = return_pid
    end

    def call(folder)
      @calls << folder
      return nil unless @return_pid

      @pid
    end
  end

  NOW = Time.utc(2026, 6, 8, 12, 0, 0)

  def setup
    @logger = FakeLogger.new
  end

  def make_task_folder(display_name:, slug: "my-slug")
    dir = Dir.mktmpdir("hive-backfill")
    @dirs ||= []
    @dirs << dir
    Hive::TaskMeta.write(dir, id: 1, slug: slug, display_name: display_name)
    dir
  end

  def teardown
    Array(@dirs).each { |d| FileUtils.remove_entry(d) if File.directory?(d) }
  end

  def make_row(folder, project: "p", slug: "s", stage: "4-execute")
    Row.new(
      project: project, slug: slug, stage: stage,
      marker: "agent_working", marker_attrs: {}, folder: folder,
      state_file: File.join(folder, "task.md"), state_file_mtime: NOW,
      action: "working", suggested_command: nil,
      claude_pid_alive: true, live_task_lock: nil, diagnostic: nil
    )
  end

  def backfiller(spawn:, dry_run: false, max_per_tick: 2)
    Hive::Daemon::DisplayNameBackfiller.new(
      logger: @logger, dry_run: dry_run, spawn: spawn, max_per_tick: max_per_tick
    )
  end

  def backfill_events
    @logger.events.select { |name, _| name == :display_name_backfill }
  end

  def test_spawns_only_for_missing_display_name
    missing = make_task_folder(display_name: nil)
    present = make_task_folder(display_name: "Already Named")
    spawn = FakeSpawn.new
    rows = [ make_row(missing, slug: "missing"), make_row(present, slug: "present") ]

    backfiller(spawn: spawn).backfill(rows, now: NOW)

    assert_equal [ missing ], spawn.calls,
                 "should spawn generate-name only for the task with a missing display_name"
    events = backfill_events
    assert_equal 1, events.size, "expected one display_name_backfill event"
    assert_equal "missing", events.first[1][:slug]
    refute_nil events.first[1][:pid], "real spawn must record a pid"
  end

  def test_treats_empty_string_display_name_as_missing
    blank = make_task_folder(display_name: "   ")
    spawn = FakeSpawn.new
    backfiller(spawn: spawn).backfill([ make_row(blank) ], now: NOW)

    assert_equal [ blank ], spawn.calls,
                 "whitespace-only display_name must count as missing"
  end

  def test_respects_max_per_tick
    folders = Array.new(3) { make_task_folder(display_name: nil) }
    spawn = FakeSpawn.new
    rows = folders.each_with_index.map { |f, i| make_row(f, slug: "s#{i}") }

    backfiller(spawn: spawn, max_per_tick: 2).backfill(rows, now: NOW)

    assert_equal 2, spawn.calls.size, "max_per_tick must bound spawns to 2"
    assert_equal 2, backfill_events.size
  end

  def test_does_not_respawn_inflight_folder
    folder = make_task_folder(display_name: nil)
    spawn = FakeSpawn.new
    bf = backfiller(spawn: spawn, max_per_tick: 5)

    # First tick spawns and records inflight; meta still missing on the
    # second tick (generate-name hasn't landed yet), but the inflight
    # pid is still "alive" so we must not spawn again.
    bf.backfill([ make_row(folder) ], now: NOW)
    bf.backfill([ make_row(folder) ], now: NOW)

    assert_equal 1, spawn.calls.size,
                 "a folder already inflight must not be re-spawned on the next tick"
  end

  def test_dry_run_logs_without_spawning
    folder = make_task_folder(display_name: nil)
    spawn = FakeSpawn.new
    backfiller(spawn: spawn, dry_run: true).backfill([ make_row(folder) ], now: NOW)

    assert_empty spawn.calls, "dry_run must not spawn"
    events = backfill_events
    assert_equal 1, events.size
    assert_equal true, events.first[1][:dry_run]
    assert_nil events.first[1][:pid]
  end

  def test_spawn_returning_nil_is_not_tracked_and_retries
    folder = make_task_folder(display_name: nil)
    spawn = FakeSpawn.new(return_pid: false)
    bf = backfiller(spawn: spawn, max_per_tick: 5)

    # A spawn that fails (returns nil) must not be recorded inflight, so
    # the next tick retries it.
    bf.backfill([ make_row(folder) ], now: NOW)
    bf.backfill([ make_row(folder) ], now: NOW)

    assert_equal 2, spawn.calls.size,
                 "a failed spawn (nil pid) must be retried on the next tick"
    assert_empty backfill_events,
                 "a failed spawn must not emit a backfill event"
  end

  def test_blank_folder_row_is_skipped
    row = make_row("", slug: "no-folder")
    spawn = FakeSpawn.new
    backfiller(spawn: spawn).backfill([ row ], now: NOW)

    assert_empty spawn.calls, "rows without a folder must be skipped, not crash"
  end

  def test_backfill_never_raises_on_bad_row
    # A row whose folder accessor explodes must degrade to a no-op tick,
    # not propagate out of backfill.
    bad = Object.new
    def bad.respond_to?(_) = true
    def bad.folder = raise("boom")

    spawn = FakeSpawn.new
    assert_silent do
      backfiller(spawn: spawn).backfill([ bad ], now: NOW)
    end
    assert_empty spawn.calls
  end
end
