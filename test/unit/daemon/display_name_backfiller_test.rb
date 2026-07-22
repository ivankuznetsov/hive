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

  def fatal_events
    @logger.events.select { |name, _| name == :fatal }
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
    assert_empty fatal_events,
                 "a benign nil-pid spawn must not log a :fatal event"
  end

  def test_blank_folder_row_is_skipped
    row = make_row("", slug: "no-folder")
    spawn = FakeSpawn.new
    backfiller(spawn: spawn).backfill([ row ], now: NOW)

    assert_empty spawn.calls, "rows without a folder must be skipped, not crash"
  end

  def test_admission_error_row_is_skipped_without_reading_or_spawning
    folder = make_task_folder(display_name: nil)
    row = make_row(folder)
    row.admission_error = Hive::DependencyAdmission::AdmissionError.new(
      reason_code: "dependency_metadata_unreadable",
      offending_ref: row.slug,
      safe_correction: "Repair meta.yml."
    )
    spawn = FakeSpawn.new

    backfiller(spawn: spawn).backfill([ row ], now: NOW)

    assert_empty spawn.calls
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
    # The per-row rescue (consider_row) must surface the swallowed error
    # as a :fatal event rather than failing silently.
    row_fatal = fatal_events.find { |_n, a| a[:message].to_s.include?("row raised") }
    refute_nil row_fatal, "a row whose folder accessor raises must log a per-row :fatal event"
    assert_includes row_fatal[1][:message], "boom"
  end

  # ── reliability: reap, TTL, and rescue coverage ──────────────────────

  # line 116 (Errno::ESRCH): a recorded pid that has already exited must
  # be dropped on the next tick so the folder becomes re-spawnable.
  def test_dead_pid_is_reaped_and_folder_respawns
    folder = make_task_folder(display_name: nil)
    # A genuinely-dead pid: spawn `true` and reap it, so its pid is gone.
    dead_pid = Process.spawn("true")
    Process.wait(dead_pid)
    spawn = FakeSpawn.new(pid: dead_pid)
    bf = backfiller(spawn: spawn, max_per_tick: 5)

    bf.backfill([ make_row(folder) ], now: NOW)
    assert_equal 1, spawn.calls.size, "first tick spawns and records the (now dead) pid inflight"

    # Next tick: pid_alive? hits Errno::ESRCH -> entry dropped -> respawn.
    bf.backfill([ make_row(folder) ], now: NOW + 1)
    assert_equal 2, spawn.calls.size,
                 "a dead inflight pid must be reaped so the folder is re-spawnable"
    assert_empty fatal_events, "reaping a dead pid is normal and must not log :fatal"
  end

  # line 118 (Errno::EPERM): a pid that is alive-but-not-ours must keep
  # the folder inflight (no re-spawn) within the TTL window.
  def test_eperm_pid_keeps_folder_inflight
    folder = make_task_folder(display_name: nil)
    spawn = FakeSpawn.new
    bf = backfiller(spawn: spawn, max_per_tick: 5)
    bf.backfill([ make_row(folder) ], now: NOW)

    # Drive pid_alive? through its real Errno::EPERM branch via Process.kill.
    with_replaced_singleton_method(Process, :kill, ->(*) { raise Errno::EPERM }) do
      bf.backfill([ make_row(folder) ], now: NOW + 1)
    end

    assert_equal 1, spawn.calls.size,
                 "an alive-but-foreign (EPERM) pid must keep the folder inflight, not re-spawn"
  end

  # Part A TTL: an entry that outlives MAX_INFLIGHT_AGE_SEC must be
  # evicted even while pid_alive? still reports true (pid reuse), so the
  # folder is never pinned forever.
  def test_inflight_ttl_evicts_stuck_entry
    folder = make_task_folder(display_name: nil)
    spawn = FakeSpawn.new # pid defaults to Process.pid -> always alive
    bf = backfiller(spawn: spawn, max_per_tick: 5)
    bf.backfill([ make_row(folder) ], now: NOW)
    assert_equal 1, spawn.calls.size

    # Within TTL while alive: still inflight, no re-spawn.
    bf.backfill([ make_row(folder) ], now: NOW + 60)
    assert_equal 1, spawn.calls.size, "within TTL an alive pid stays inflight"

    # Past TTL while still alive: evicted, folder re-spawnable.
    ttl = Hive::Daemon::DisplayNameBackfiller::MAX_INFLIGHT_AGE_SEC
    bf.backfill([ make_row(folder) ], now: NOW + ttl + 1)
    assert_equal 2, spawn.calls.size,
                 "an inflight entry older than MAX_INFLIGHT_AGE_SEC must be evicted and re-spawned"
  end

  # line 108 (reap_inflight inner rescue, now logging per Part B): a
  # non-ESRCH/EPERM error from liveness probing must RETAIN the entry,
  # log :fatal, and not propagate.
  def test_reap_unexpected_error_retains_entry_and_logs
    folder = make_task_folder(display_name: nil)
    spawn = FakeSpawn.new
    bf = backfiller(spawn: spawn, max_per_tick: 5)
    bf.backfill([ make_row(folder) ], now: NOW)

    with_replaced_singleton_method(Process, :kill, ->(*) { raise RuntimeError, "kill boom" }) do
      assert_silent do
        bf.backfill([ make_row(folder) ], now: NOW + 1)
      end
    end

    reap_fatal = fatal_events.find { |_n, a| a[:message].to_s.include?("reap raised") }
    refute_nil reap_fatal, "an unexpected reap error must log a :fatal reap event"
    assert_includes reap_fatal[1][:message], "kill boom"
    # Entry retained (RuntimeError -> rescue returns false -> not deleted):
    # the folder must NOT be re-spawned on this same tick.
    assert_equal 1, spawn.calls.size,
                 "an entry whose liveness probe raised unexpectedly must be retained"
  end

  # line 66 (outer #backfill rescue): force an error that escapes the
  # inner reap rescue so the outer guard catches it. We make @inflight
  # itself raise during delete_if by stubbing it to a value that blows up.
  def test_backfill_outer_rescue_never_raises
    folder = make_task_folder(display_name: nil)
    spawn = FakeSpawn.new
    bf = backfiller(spawn: spawn, max_per_tick: 5)
    bf.backfill([ make_row(folder) ], now: NOW)

    # Replace @inflight with an object whose #delete_if raises outright,
    # so reap_inflight itself raises before its block-level rescue runs
    # (the rescue is on the block, not the method) -> outer rescue fires.
    exploding = Object.new
    def exploding.delete_if(*); raise "inflight boom"; end
    def exploding.key?(*) = false
    bf.instance_variable_set(:@inflight, exploding)

    assert_silent do
      bf.backfill([ make_row(folder) ], now: NOW + 1)
    end
    outer = fatal_events.find { |_n, a| a[:message].to_s.include?("#backfill raised") }
    refute_nil outer, "an error escaping the loop must hit the outer #backfill rescue"
    assert_includes outer[1][:message], "inflight boom"
  end

  # line 133 (display_name_missing? rescue): if the meta read raises
  # (TaskMeta normally swallows errors, but defense-in-depth), the folder
  # must be treated as NOT missing so a flaky read never triggers a spawn.
  def test_unreadable_meta_is_not_treated_as_missing
    folder = make_task_folder(display_name: nil)
    spawn = FakeSpawn.new
    with_replaced_singleton_method(Hive::TaskMeta, :read_for_admission, ->(*) { raise "meta boom" }) do
      backfiller(spawn: spawn).backfill([ make_row(folder) ], now: NOW)
    end

    assert_empty spawn.calls,
                 "a raising meta read must be treated as not-missing (no spawn storm)"
    assert_empty fatal_events,
                 "display_name_missing? swallows its own read error; no :fatal expected"
  end

  # lines 158/161 (backfill_row spawn rescue): an injected spawn that
  # raises must log a :fatal 'spawn raised' event, add no inflight entry,
  # and not propagate.
  def test_spawn_raising_logs_fatal_and_tracks_nothing
    folder = make_task_folder(display_name: nil)
    raising_spawn = ->(_) { raise "boom" }
    bf = backfiller(spawn: raising_spawn, max_per_tick: 5)

    assert_silent do
      bf.backfill([ make_row(folder) ], now: NOW)
    end
    spawn_fatal = fatal_events.find { |_n, a| a[:message].to_s.include?("spawn raised") }
    refute_nil spawn_fatal, "a raising spawn must log a :fatal spawn event"
    assert_includes spawn_fatal[1][:message], "boom"
    assert_empty backfill_events, "a raising spawn must not record a backfill event"

    # No inflight entry: a fresh tick re-attempts the same folder.
    bf.backfill([ make_row(folder) ], now: NOW + 1)
    refute_empty fatal_events
  end

  # lines 189/193 (real spawn_name_generator rescue): with NO injected
  # spawn the backfiller uses its real Process.spawn path; if that raises
  # (Errno::ENOENT) the method returns nil, so no inflight entry is added
  # and backfill does not raise.
  def test_real_spawn_path_swallows_process_spawn_error
    folder = make_task_folder(display_name: nil)
    bf = Hive::Daemon::DisplayNameBackfiller.new(logger: @logger, max_per_tick: 5)

    with_replaced_singleton_method(Process, :spawn, ->(*) { raise Errno::ENOENT, "hive" }) do
      assert_silent do
        bf.backfill([ make_row(folder) ], now: NOW)
      end
    end

    assert_empty backfill_events,
                 "a failed real spawn (nil pid) must not emit a backfill event"
    assert_empty fatal_events,
                 "the real spawn path swallows its own error; no :fatal expected"
    # nil pid means nothing inflight -> next tick re-attempts (and fails
    # the same benign way). We just confirm no raise / no tracking.
    bf.backfill([ make_row(folder) ], now: NOW + 1)
  end

  # line 208 (waiter-thread Errno::ECHILD/ESRCH rescue): the real
  # spawn_name_generator detaches a thread that Process.waits the child;
  # if that wait hits ECHILD/ESRCH (child already reaped) the thread must
  # swallow it. We let the real spawn succeed (fake pid), force the
  # thread's Process.wait to raise ECHILD, and join the thread so the
  # rescue body actually executes within the test.
  def test_real_spawn_waiter_thread_swallows_echild
    folder = make_task_folder(display_name: nil)
    bf = Hive::Daemon::DisplayNameBackfiller.new(logger: @logger, max_per_tick: 5)

    spawned_threads = []
    real_thread_new = Thread.method(:new)
    capture_threads = lambda do |&blk|
      t = real_thread_new.call(&blk)
      spawned_threads << t
      t
    end

    with_replaced_singleton_method(Process, :spawn, ->(*) { Process.pid }) do
      with_replaced_singleton_method(Process, :wait, ->(*) { raise Errno::ECHILD }) do
        with_replaced_singleton_method(Thread, :new, capture_threads) do
          assert_silent do
            bf.backfill([ make_row(folder) ], now: NOW)
          end
        end
        # Join the waiter thread so its ECHILD rescue runs before we assert.
        spawned_threads.each(&:join)
      end
    end

    # The (fake) pid was returned, so the row was recorded as a backfill.
    assert_equal 1, backfill_events.size,
                 "a real spawn returning a pid must record one backfill event"
    refute spawned_threads.any?(&:alive?), "the waiter thread must finish (ECHILD swallowed)"
  end
end
