require "test_helper"
require "tmpdir"
require "json"
require "hive/daemon/dispatch_baselines"

class DaemonDispatchBaselinesTest < Minitest::Test
  include HiveTestHelper

  class RecordingLogger
    attr_reader :events
    def initialize = @events = []
    def event(name, **attrs) = @events << [ name, attrs ]
  end

  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "daemon_dispatch_baselines.json")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def store
    Hive::Daemon::DispatchBaselines.new(path: @path)
  end

  def test_roundtrips_a_multi_entry_map_with_microsecond_mtimes
    # Construct with explicit µs (7th arg) so the input has no Float fuzz
    # — then `assert_equal` pins exact iso8601(6) → Time.parse round-trip.
    # A regression from `iso8601(6)` to e.g. `iso8601(3)` (millisecond) or
    # bare `iso8601` (whole second) would flip this to inequality.
    t1 = Time.utc(2026, 5, 27, 20, 48, 58, 123_456)
    t2 = Time.utc(2026, 5, 27, 21, 9, 21, 654_321)
    map = { %w[writero add-x-260527-ab12] => t1, %w[xbookmark use-y-260527-cd34] => t2 }

    store.write(map)
    loaded = store.load

    assert_equal 2, loaded.size
    assert_equal t1, loaded[%w[writero add-x-260527-ab12]]
    assert_equal t2, loaded[%w[xbookmark use-y-260527-cd34]]
  end

  def test_empty_map_roundtrips_to_empty
    store.write({})
    assert_empty store.load
  end

  def test_missing_file_loads_empty
    assert_empty store.load
  end

  def test_truncated_json_loads_empty_without_raising
    File.write(@path, '{"schema_version":1,"baselines":[{"project":"a"')
    assert_empty store.load
  end

  def test_non_hash_root_loads_empty
    File.write(@path, "[1, 2, 3]")
    assert_empty store.load
  end

  def test_missing_schema_version_loads_empty
    File.write(@path, JSON.generate("baselines" => []))
    assert_empty store.load
  end

  def test_entry_with_unparseable_mtime_is_dropped_others_kept
    File.write(@path, JSON.generate(
      "schema_version" => 1,
      "baselines" => [
        { "project" => "p", "slug" => "good", "mtime" => Time.utc(2026, 5, 27).iso8601(6) },
        { "project" => "p", "slug" => "bad", "mtime" => "not-a-timestamp" },
        { "project" => "p", "slug" => "missing-mtime" }
      ]
    ))
    loaded = store.load
    assert_equal [ %w[p good] ], loaded.keys
  end

  def test_newer_schema_version_loads_empty_and_suspends_writes
    # A newer hive wrote this; read nothing we don't recognize and never
    # clobber it on a subsequent write (downgrade protection).
    original = JSON.generate("schema_version" => 999, "baselines" => [])
    File.write(@path, original)

    s = store
    assert_empty s.load
    s.write({ %w[p s] => Time.now })

    assert_equal original, File.read(@path), "must not overwrite a newer-schema file"
  end

  def test_write_is_atomic_and_leaves_no_tmp_litter
    store.write({ %w[p s] => Time.utc(2026, 5, 27) })

    assert_empty Dir.glob(File.join(@dir, ".daemon_dispatch_baselines.json*.tmp")),
                 "atomic write must clean up its tempfile"
    assert_path_exists @path
  end

  def test_nil_path_is_a_no_op
    s = Hive::Daemon::DispatchBaselines.new(path: nil)
    s.write({ %w[p s] => Time.now })
    assert_empty s.load
  end

  def test_write_failure_degrades_without_raising
    # A read-only state dir must degrade (log + continue), never crash a tick.
    ro = File.join(@dir, "ro")
    FileUtils.mkdir_p(ro)
    File.chmod(0o500, ro)
    s = Hive::Daemon::DispatchBaselines.new(path: File.join(ro, "baselines.json"))

    s.write({ %w[p s] => Time.utc(2026, 5, 27) }) # must not raise

    refute_path_exists File.join(ro, "baselines.json")
  ensure
    File.chmod(0o700, ro) if ro && File.exist?(ro)
  end

  def test_older_schema_version_loads_empty
    File.write(@path, JSON.generate("schema_version" => 0, "baselines" => []))
    assert_empty store.load
  end

  def test_stale_orphan_tmp_is_swept_but_fresh_one_kept
    stale = File.join(@dir, ".daemon_dispatch_baselines.json.1.1.tmp")
    fresh = File.join(@dir, ".daemon_dispatch_baselines.json.2.2.tmp")
    File.write(stale, "x")
    File.write(fresh, "y")
    # Pin both mtimes explicitly so the test doesn't depend on the wall clock
    # between writes and sweep (a slow CI could otherwise let the "fresh"
    # file age past STALE_TMP_SEC and flake the assertion).
    File.utime(Time.now - 120, Time.now - 120, stale)
    File.utime(Time.now - 1, Time.now - 1, fresh)

    store # construction triggers clean_orphaned_tmp_files!

    refute_path_exists stale, "a stale orphan tmp must be swept on construction"
    assert_path_exists fresh, "a fresh tmp may be a live in-flight write — keep it"
  end

  def test_dangling_symlink_tmp_does_not_abort_sweep_of_other_orphans
    # Real stale orphan: must be swept. Plus a dangling symlink whose
    # File.mtime raises ENOENT — the per-entry rescue must swallow that and
    # the loop MUST continue to the real orphan. A regression that re-raised
    # or early-returned after the symlink would leave the real orphan in
    # place, so we assert the real one's absence (not just no-raise).
    real = File.join(@dir, ".daemon_dispatch_baselines.json.real.tmp")
    File.write(real, "x")
    File.utime(Time.now - 120, Time.now - 120, real)
    link = File.join(@dir, ".daemon_dispatch_baselines.json.x.tmp")
    File.symlink(File.join(@dir, "does-not-exist"), link)

    store

    refute_path_exists real, "the sweep must continue past a bad orphan and reap the real one"
  end

  def test_glob_failure_during_sweep_is_logged
    logger = RecordingLogger.new
    with_replaced_singleton_method(Dir, :glob, ->(*_a, **_k) { raise IOError, "synthetic glob failure" }) do
      Hive::Daemon::DispatchBaselines.new(path: @path, logger: logger)
    end
    assert(logger.events.any? { |name, _| name == :daemon_dispatch_baselines_tmp_sweep_error },
           "a sweep failure must be logged, not silently leak tmp files")
  end

  def test_release_lock_closes_the_handle_even_when_flock_raises
    # Both halves matter: the rescue is the must-not-raise contract, AND
    # `close` must still be attempted so an FD doesn't leak each time flock
    # misbehaves (one write per task-lifecycle event would accumulate fast).
    s = store
    closed = false
    bad = Object.new
    bad.define_singleton_method(:flock) { |_mode| raise(IOError, "boom") }
    bad.define_singleton_method(:close) { closed = true }

    s.send(:release_lock, bad) # must not raise

    assert closed, "flock failure must NOT bypass close — FDs would otherwise leak over daemon lifetime"
  end

  def test_release_lock_closes_the_handle_on_happy_path
    s = store
    closed = false
    handle = Object.new
    handle.define_singleton_method(:flock) { |_mode| }
    handle.define_singleton_method(:close) { closed = true }

    s.send(:release_lock, handle)

    assert closed, "release_lock must close the handle on the happy path so FDs don't leak"
  end

  def test_release_lock_swallows_close_errors_too
    # The second-stage close rescue covers the case where flock succeeds but
    # close itself raises (e.g. EIO on the lockfile FD).
    s = store
    handle = Object.new
    handle.define_singleton_method(:flock) { |_mode| }
    handle.define_singleton_method(:close) { raise(IOError, "close blew up") }

    s.send(:release_lock, handle) # must not raise
    assert true
  end

  def test_lock_failure_degrades_when_state_path_parent_is_a_file
    # Parent of the path is a regular file → mkdir_p raises ENOTDIR in
    # acquire_lock; the rescue must fire and write degrades without raising.
    file_as_parent = File.join(@dir, "not-a-dir")
    File.write(file_as_parent, "x")
    logger = RecordingLogger.new
    s = Hive::Daemon::DispatchBaselines.new(path: File.join(file_as_parent, "baselines.json"), logger: logger)

    s.write({ %w[p s] => Time.utc(2026, 5, 27) }) # must not raise

    assert(logger.events.any? { |name, _| name == :daemon_dispatch_baselines_lock_error })
  end
end
