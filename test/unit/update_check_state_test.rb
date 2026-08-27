require "test_helper"
require "tmpdir"
require "hive/update_check/state"

class UpdateCheckStateTest < Minitest::Test
  include HiveTestHelper

  class RecordingLogger
    attr_reader :events
    def initialize = @events = []
    def event(name, **attrs) = @events << [ name, attrs ]
  end

  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "update_check.json")
    @now = Time.utc(2026, 5, 27, 12, 0, 0)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def state
    Hive::UpdateCheck::State.new(path: @path)
  end

  def test_due_when_never_checked
    assert state.due?(@now)
  end

  def test_not_due_within_window
    s = state
    s.record_check!(@now)
    refute state.due?(@now + 3600, window: 86_400), "should not be due an hour after a check"
  end

  def test_due_after_window_elapses
    s = state
    s.record_check!(@now)
    assert state.due?(@now + 90_000, window: 86_400), "should be due once the window has elapsed"
  end

  def test_should_notify_once_per_version
    s = state
    assert s.should_notify?("0.1.7")
    s.record_notified!("0.1.7")
    refute state.should_notify?("0.1.7"), "must not re-notify the same version after a restart"
    assert state.should_notify?("0.1.8"), "a newer version is notifiable again"
  end

  def test_nudge_roundtrip_and_clear
    s = state
    s.set_nudge(latest: "0.1.7", channel: "brew", command: "brew upgrade ivankuznetsov/hive/hive")
    n = state.nudge
    assert_equal "0.1.7", n.latest
    assert_equal "brew", n.channel
    assert_equal "brew upgrade ivankuznetsov/hive/hive", n.command

    s.clear_nudge!
    assert_nil state.nudge
  end

  def test_nudge_nil_when_unset
    assert_nil state.nudge
  end

  def test_corrupt_file_degrades_to_empty
    File.write(@path, "{ not valid json")
    s = state
    assert s.due?(@now), "corrupt state should behave as a fresh (due) state"
    assert_nil s.nudge
  end

  def test_newer_schema_is_read_but_not_overwritten
    # Forward-compat: a newer hive wrote schema_version 99. An older process
    # must read recognized keys but never write back (no downgrade churn
    # during a rolling micro-release upgrade).
    File.write(@path, JSON.generate({ "schema_version" => 99, "last_notified_version" => "9.9.9",
                                       "nudge" => { "latest" => "9.9.9", "channel" => "brew",
                                                    "command" => "brew upgrade x" } }))
    s = state
    assert_equal "9.9.9", s.nudge.latest, "recognized keys from a newer file are still read"
    refute s.should_notify?("9.9.9"), "the newer file's notified-version is honored"

    s.record_check!(@now) # write suspended — must not rewrite the newer file
    on_disk = JSON.parse(File.read(@path))
    assert_equal 99, on_disk["schema_version"], "older process must not downgrade a newer-schema file"
    assert_nil on_disk["last_check_at"], "suspended write left the newer file untouched"
  end

  def test_non_integer_schema_degrades_to_empty
    File.write(@path, JSON.generate({ "schema_version" => "two", "last_notified_version" => "9.9.9" }))
    assert state.should_notify?("0.1.7"), "a non-integer schema_version is corrupt → reset to empty"
  end

  def test_clear_nudge_is_idempotent
    s = state
    assert_nil s.nudge
    s.clear_nudge! # already nil — must not raise
    assert_nil state.nudge
  end

  def test_persists_across_instances
    state.record_check!(@now)
    refute state.due?(@now + 10, window: 86_400), "check timestamp must survive a reload"
  end

  def test_due_exactly_at_window_boundary
    s = state
    s.record_check!(@now)
    assert state.due?(@now + 86_400, window: 86_400),
           "due? uses >= so a check is due exactly one window later (no off-by-one drift)"
  end

  def test_cross_process_writes_do_not_clobber_each_other
    # The whole reason every op re-reads disk: the daemon writes `nudge` while
    # the bot writes `last_notified_version`, each from its own instance. A
    # stale in-memory copy in either would erase the other's key. Interleave
    # three separate instances against one file, then assert all keys survive.
    daemon = state
    bot = state

    daemon.set_nudge(latest: "0.1.7", channel: "brew", command: "brew upgrade x")
    bot.record_notified!("0.1.7")   # bot must not erase the daemon's nudge
    daemon.record_check!(@now)       # daemon must not erase the bot's notified-version

    fresh = state
    assert fresh.nudge, "nudge (daemon-written) must survive the bot's write"
    assert_equal "0.1.7", fresh.nudge.latest
    refute fresh.should_notify?("0.1.7"), "notified-version (bot-written) must survive the daemon's write"
    refute fresh.due?(@now + 10, window: 86_400), "check timestamp must survive too"
  end

  def test_older_schema_degrades_to_empty
    File.write(@path, JSON.generate({ "schema_version" => 0, "last_notified_version" => "9.9.9" }))
    assert state.should_notify?("0.1.7"), "an older schema_version is reset to empty"
  end

  def test_malformed_last_check_at_is_treated_as_never_checked
    File.write(@path, JSON.generate({ "schema_version" => 1, "last_check_at" => "not-a-date" }))
    assert state.due?(@now), "an unparseable timestamp degrades to never-checked, never raises"
  end

  def test_stale_orphan_tmp_is_swept_but_fresh_one_kept
    stale = File.join(@dir, ".update_check.json.1.1.tmp")
    fresh = File.join(@dir, ".update_check.json.2.2.tmp")
    File.write(stale, "old")
    File.write(fresh, "in-flight")
    File.utime(Time.now - 300, Time.now - 300, stale)
    Hive::UpdateCheck::State.new(path: @path)
    refute File.exist?(stale), "stragglers older than the stale window are swept"
    assert File.exist?(fresh), "a fresh tmp may be a live process's in-flight write — keep it"
  end

  def test_observation_only_initialization_keeps_stale_orphan_tmp
    stale = File.join(@dir, ".update_check.json.1.1.tmp")
    File.write(stale, "old")
    File.utime(Time.now - 300, Time.now - 300, stale)

    Hive::UpdateCheck::State.new(
      path: @path,
      cleanup_orphans: false
    )

    assert File.exist?(stale),
           "an observation-only state read must not clean stale tmp files"
  end

  def test_dangling_symlink_tmp_does_not_abort_sweep
    link = File.join(@dir, ".update_check.json.x.tmp")
    File.symlink(File.join(@dir, "no-such-target"), link)
    # File.mtime on the dangling link raises ENOENT — the per-entry rescue
    # must skip it without aborting construction.
    Hive::UpdateCheck::State.new(path: @path)
  end

  def test_glob_failure_during_sweep_is_logged
    logger = RecordingLogger.new
    with_replaced_singleton_method(Dir, :glob, ->(*_a, **_k) { raise IOError, "synthetic glob failure" }) do
      Hive::UpdateCheck::State.new(path: @path, logger: logger)
    end
    assert(logger.events.any? { |name, _| name == :update_check_tmp_sweep_error })
  end

  def test_unwritable_state_dir_degrades_without_raising
    logger = RecordingLogger.new
    afile = File.join(@dir, "afile")
    File.write(afile, "x")
    # Parent of the path is a regular file → mkdir_p raises ENOTDIR in both
    # acquire_lock and persist_locked!; both rescues must fire, no crash.
    s = Hive::UpdateCheck::State.new(path: File.join(afile, "sub", "update_check.json"), logger: logger)
    s.record_check!(@now)
    assert(logger.events.any? { |name, _| name == :update_check_state_lock_error })
    assert(logger.events.any? { |name, _| name == :update_check_state_write_error })
  end

  def test_unreadable_file_degrades_without_raising_and_without_clobbering
    logger = RecordingLogger.new
    state.record_notified!("9.9.9")
    File.chmod(0o000, @path)
    s = Hive::UpdateCheck::State.new(path: @path, logger: logger)
    # Fresh instance has no last-known state, so it behaves as empty — but a
    # mutation must NOT persist that emptied view over the unreadable file.
    assert s.should_notify?("0.1.7"), "an unreadable file degrades to last-known (here: empty), never raises"
    s.record_check!(@now)
    File.chmod(0o644, @path)
    on_disk = JSON.parse(File.read(@path))
    assert_equal "9.9.9", on_disk["last_notified_version"], "read error must not reset shared state on disk"
    assert_nil on_disk["last_check_at"], "write must be suspended while the file is unreadable"
    assert(logger.events.any? { |name, _| name == :update_check_state_read_error })
  ensure
    File.chmod(0o644, @path) if @path && File.exist?(@path)
  end

  def test_transient_read_error_does_not_reset_shared_state
    # Patrol regression: a good file {last_check_at:T, last_notified_version:
    # "1.2.4", nudge:N}; File.read raises Errno::EIO during record_check!'s
    # load!. handle_corrupt! used to empty @data and the subsequent
    # persist_locked! renamed that emptied state over the intact file,
    # permanently losing the bot's de-dupe key and the daemon's nudge.
    logger = RecordingLogger.new
    s = Hive::UpdateCheck::State.new(path: @path, logger: logger)
    s.record_notified!("1.2.4")
    s.set_nudge(latest: "1.2.4", channel: "brew", command: "brew upgrade x")

    with_replaced_singleton_method(File, :read, ->(*_a, **_k) { raise Errno::EIO }) do
      s.record_check!(@now) # read fails mid-read-modify-write; write must be suspended
    end

    on_disk = JSON.parse(File.read(@path))
    assert_equal "1.2.4", on_disk["last_notified_version"], "transient EIO must not erase the de-dupe key"
    assert on_disk["nudge"], "transient EIO must not erase the nudge payload"
    assert_nil on_disk["last_check_at"], "the tick's timestamp is dropped rather than persisted from reset state"
    assert(logger.events.any? { |name, _| name == :update_check_state_read_error })
    refute(logger.events.any? { |name, _| name == :update_check_state_write_error })

    # Next successful load! clears the suspend flag; normal operation resumes.
    s.record_check!(@now + 3600)
    on_disk = JSON.parse(File.read(@path))
    assert_equal (@now + 3600).utc.iso8601, on_disk["last_check_at"]
    assert_equal "1.2.4", on_disk["last_notified_version"]
    assert on_disk["nudge"], "recovered writes must preserve earlier keys"
  end

  def test_release_lock_swallows_errors
    bad = Object.new
    def bad.flock(_mode) = raise(IOError, "boom")
    state.send(:release_lock, bad) # must not raise
  end

  def test_flock_failure_closes_the_already_open_lock_fd
    opened = nil
    original_open = File.method(:open)
    failing_open = lambda do |*args, **kwargs, &blk|
      handle = original_open.call(*args, **kwargs, &blk)
      if args.first.to_s.end_with?(".lock")
        opened = handle
        def handle.flock(_mode)
          raise Errno::ENOLCK # open succeeded; acquiring the lock failed
        end
      end
      handle
    end
    logger = RecordingLogger.new
    s = Hive::UpdateCheck::State.new(path: @path, logger: logger)
    with_replaced_singleton_method(File, :open, failing_open) do
      s.record_check!(@now) # must degrade to best-effort, not raise
    end
    assert opened, "the lock file was opened before flock raised"
    assert_predicate opened, :closed?,
                     "a failed flock must close the fd it already opened — no leak per op"
    assert(logger.events.any? { |name, _| name == :update_check_state_lock_error })
  end

  def test_flock_failure_swallows_a_secondary_close_error
    handle = Object.new
    def handle.flock(_mode) = raise(Errno::ENOLCK)
    def handle.close = raise(IOError, "synthetic close failure")

    original_open = File.method(:open)
    failing_open = lambda do |*args, **kwargs, &block|
      if args.first.to_s.end_with?(".lock")
        handle
      else
        original_open.call(*args, **kwargs, &block)
      end
    end
    logger = RecordingLogger.new
    s = Hive::UpdateCheck::State.new(path: @path, logger: logger)

    with_replaced_singleton_method(File, :open, failing_open) do
      s.record_check!(@now)
    end

    assert(logger.events.any? { |name, _| name == :update_check_state_lock_error })
  end

  def test_fsync_dir_swallows_errors
    state.send(:fsync_dir, File.join(@dir, "does-not-exist")) # Dir.open raises → nil
  end
end
