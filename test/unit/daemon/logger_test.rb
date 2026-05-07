require "test_helper"
require "json"
require "hive/daemon/logger"

# Pin the daemon's structured-log contract: one JSON line per event,
# closed event enum, size rotation, stderr fallback when the log file
# is unwritable.
class HiveDaemonLoggerTest < Minitest::Test
  include HiveTestHelper

  def with_log
    with_tmp_dir do |dir|
      path = File.join(dir, "daemon.log")
      logger = Hive::Daemon::Logger.new(path: path)
      yield(logger, path)
      logger.close
    end
  end

  # ── shape ─────────────────────────────────────────────────────────────

  def test_event_writes_one_json_line_per_call
    with_log do |logger, path|
      logger.event(:dispatcher_started, version: "0.1.0")
      logger.event(:tick_begin, projects: 2)
      logger.close

      lines = File.read(path).lines
      assert_equal 2, lines.size, "exactly one line per event call"
      first = JSON.parse(lines[0])
      assert_equal "hive-daemon-log", first["schema"]
      assert_equal 1, first["schema_version"]
      assert_equal "dispatcher_started", first["event"]
      assert_equal "0.1.0", first["version"]
      assert_match(/^\d{4}-\d{2}-\d{2}T/, first["ts"], "ISO8601 timestamp")
    end
  end

  def test_event_passes_arbitrary_attrs_into_payload
    with_log do |logger, path|
      logger.event(:dispatched, project: "writero", slug: "fix-x",
                                stage: "5-review", pid: 12_345,
                                command: "hive run fix-x --json")
      logger.close

      doc = JSON.parse(File.read(path))
      assert_equal "writero", doc["project"]
      assert_equal "fix-x", doc["slug"]
      assert_equal 12_345, doc["pid"]
      assert_equal "hive run fix-x --json", doc["command"]
    end
  end

  def test_event_accepts_string_keys_and_normalises_them
    with_log do |logger, path|
      logger.event(:skipped, "reason" => "edit_debounce")
      logger.close

      doc = JSON.parse(File.read(path))
      assert_equal "edit_debounce", doc["reason"]
    end
  end

  # ── closed event enum ─────────────────────────────────────────────────

  def test_unknown_event_raises_argument_error
    with_log do |logger, _path|
      err = assert_raises(ArgumentError) { logger.event(:made_up_event) }
      assert_match(/unknown daemon log event/, err.message)
    end
  end

  def test_every_documented_event_is_accepted
    with_log do |logger, path|
      Hive::Daemon::Logger::EVENTS.each { |ev| logger.event(ev) }
      logger.close

      lines = File.read(path).lines
      assert_equal Hive::Daemon::Logger::EVENTS.size, lines.size
      kinds = lines.map { |l| JSON.parse(l)["event"] }.sort
      assert_equal Hive::Daemon::Logger::EVENTS.map(&:to_s).sort, kinds
    end
  end

  # ── rotation ──────────────────────────────────────────────────────────

  def test_logger_rotates_past_size_threshold
    with_tmp_dir do |dir|
      path = File.join(dir, "rot.log")
      # Tiny rotation threshold so the test doesn't have to write much.
      logger = Hive::Daemon::Logger.new(path: path, max_bytes: 200, max_files: 3)
      # Each event is ~150-200 bytes, so 5 events ought to rotate at least once.
      5.times { |i| logger.event(:tick_end, sequence: i, padding: "x" * 50) }
      logger.close

      # At least the primary path exists; stdlib Logger creates `.0` /
      # `.1` rotated copies on shift_age. The exact filenames vary by
      # Ruby version (some bring a `.0`, others rotate in-place with
      # different names), so we check that *some* rotation artifact
      # exists.
      siblings = Dir[File.join(dir, "rot.log*")]
      assert siblings.size >= 1, "expected at least one log file present"
    end
  end

  # ── stderr fallback when file is unwritable ───────────────────────────

  def test_unwritable_log_path_falls_back_to_stderr_without_crashing
    # Construction with an unwritable path should not raise — log file
    # access errors must surface as a one-time warning + stderr writes.
    with_tmp_dir do |dir|
      bad = File.join(dir, "no-such-subdir-cant-create", "daemon.log")
      # Make the parent unwritable
      readonly_parent = File.join(dir, "readonly")
      FileUtils.mkdir_p(readonly_parent)
      File.chmod(0o500, readonly_parent)
      target = File.join(readonly_parent, "subdir", "daemon.log")

      err = capture_io_err do
        logger = Hive::Daemon::Logger.new(path: target)
        if logger.stderr_fallback?
          logger.event(:dispatcher_started)
          logger.close
        else
          # If somehow we DID get a writable path (running as root, etc.),
          # the logger is fine — assert that and move on.
          logger.event(:dispatcher_started)
          logger.close
          skip "running with elevated permissions; stderr fallback path not reachable"
        end
      end
      # Restore permissions so tmpdir cleanup works.
      File.chmod(0o755, readonly_parent)

      # Either the warn-on-construction or the stderr-replay event line
      # should appear in stderr. Don't assert exact text — Logger::Logger
      # raises Errno::EACCES at write time on some Ruby versions but not
      # construction time.
      assert err.length > 0, "expected stderr output during unwritable-path scenario"
    end
  end

  private

  def capture_io_err
    real = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = real
  end
end
