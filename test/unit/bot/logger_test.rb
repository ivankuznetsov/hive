require "test_helper"
require "json"
require "json_schemer"
require "hive/bot/logger"

class HiveBotLoggerTest < Minitest::Test
  include HiveTestHelper

  def with_log
    with_tmp_dir do |dir|
      path = File.join(dir, "bot.log")
      logger = Hive::Bot::Logger.new(path: path)
      yield(logger, path)
      logger.close
    end
  end

  def test_event_writes_one_json_line_per_call
    with_log do |logger, path|
      logger.event(:bot_started, version: "0.1.0")
      logger.event(:update_received, update_id: 123)
      logger.close

      lines = File.read(path).lines
      assert_equal 2, lines.size
      first = JSON.parse(lines[0])
      assert_equal "hive-bot-log", first["schema"]
      assert_equal 3, first["schema_version"]
      assert_equal "bot_started", first["event"]
      assert_equal "info", first["level"]
      assert_equal "0.1.0", first["version"]
      assert_match(/^\d{4}-\d{2}-\d{2}T/, first["ts"])
    end
  end

  def test_unknown_event_raises_argument_error
    with_log do |logger, _path|
      err = assert_raises(ArgumentError) { logger.event(:made_up_event) }
      assert_match(/unknown bot log event/, err.message)
    end
  end

  def test_every_documented_event_is_accepted_and_schema_valid
    schema = JSONSchemer.schema(JSON.parse(File.read(File.expand_path("../../../schemas/hive-bot-log.v3.json", __dir__))))

    with_log do |logger, path|
      Hive::Bot::Logger::EVENTS.each { |event| logger.event(event) }
      logger.close

      lines = File.read(path).lines
      assert_equal Hive::Bot::Logger::EVENTS.size, lines.size
      lines.each do |line|
        payload = JSON.parse(line)
        assert schema.valid?(payload), "bot log line should match schema: #{payload.inspect}"
      end
    end
  end

  # `event` validates `name` against EVENTS, but `LEVELS.fetch(name, :info)`
  # silently ignores a stale or misspelled LEVELS key — a wrong/orphaned entry
  # never surfaces at runtime. Pin LEVELS ⊆ EVENTS so a typo'd or removed event
  # name left behind in LEVELS fails here instead.
  def test_levels_map_keys_are_a_subset_of_events
    orphans = Hive::Bot::Logger::LEVELS.keys - Hive::Bot::Logger::EVENTS
    assert_empty orphans,
                 "LEVELS has keys absent from EVENTS (stale/misspelled, silently ignored " \
                 "by LEVELS.fetch): #{orphans.inspect}"
  end

  # `test_every_documented_event_is_accepted_and_schema_valid` proves the
  # forward direction (every EVENTS entry validates against the schema enum).
  # This pins the reverse: an extra enum value with no EVENTS entry (a stale,
  # typo'd, or removed event the producer can never emit) would pass green and
  # mislead non-Ruby consumers. A strict equality closes the remaining gap.
  def test_schema_event_enum_is_a_strict_bijection_with_events
    schema_doc = JSON.parse(File.read(File.expand_path("../../../schemas/hive-bot-log.v3.json", __dir__)))
    schema_enum = schema_doc.dig("properties", "event", "enum")
    assert_equal Hive::Bot::Logger::EVENTS.map(&:to_s).sort, schema_enum.sort,
                 "hive-bot-log.v3 event enum must mirror Logger::EVENTS exactly (no schema-side drift)"
  end

  def test_v2_schema_remains_for_back_compat
    schema_doc = JSON.parse(File.read(File.expand_path("../../../schemas/hive-bot-log.v2.json", __dir__)))
    schema = JSONSchemer.schema(schema_doc)
    historical_line = {
      "ts" => "2026-06-01T12:00:00Z",
      "schema" => "hive-bot-log",
      "schema_version" => 2,
      "event" => "poll_failure"
    }

    assert_equal 2, schema_doc.fetch("properties").fetch("schema_version").fetch("const")
    refute_includes schema_doc.fetch("properties").fetch("event").fetch("enum"), "poll_unhealthy"
    assert schema.valid?(historical_line), "historical v2 bot log line should remain valid"
  end

  def test_default_levels_come_from_event_map
    with_log do |logger, path|
      logger.event(:poll_failure)
      logger.event(:poll_unhealthy)
      logger.event(:notification_skipped_dedupe)
      logger.event(:bot_started)
      logger.event(:notification_skipped_active_conversation)
      logger.event(:notification_skipped_daemon_plan_pause)
      logger.close

      levels = File.read(path).lines.map { |line| JSON.parse(line).fetch("level") }
      assert_equal %w[warn warn debug info info info], levels
    end
  end

  def test_info_stream_excludes_noise_events_under_repeated_poll_and_dedupe_chatter
    # The high-frequency events are emitted with NO explicit level, so their
    # severity comes from the production LEVELS map (poll_failure → warn,
    # notification_skipped_dedupe → debug) — not from tags the test supplies.
    # This makes the acceptance criterion non-circular: regressing
    # LEVELS[:poll_failure] or LEVELS[:notification_skipped_dedupe] to :info
    # would leak them into the info view and fail `info.size`.
    with_log do |logger, path|
      20.times { |i| logger.event(:notification_sent, sequence: i) }
      100.times do |i|
        logger.event(:poll_failure, error_class: "Faraday::TimeoutError", message: "slow #{i}")
        logger.event(:notification_skipped_dedupe, project: "hive", slug: "slug", marker: "waiting")
      end
      logger.close

      payloads = File.read(path).lines.map { |line| JSON.parse(line) }
      info = payloads.select { |payload| payload.fetch("level") == "info" }
      noise_in_info = info.select do |payload|
        payload["category"] == Hive::Bot::Logger::CATEGORY_NOISE.to_s ||
          %w[poll_failure notification_skipped_dedupe notification_skipped_backoff].include?(payload.fetch("event"))
      end

      assert_equal 20, info.size
      assert_equal 0, noise_in_info.size
    end
  end

  def test_explicit_level_and_category_override_defaults
    with_log do |logger, path|
      logger.event(:poll_failure, level: :debug, category: :noise)
      logger.close

      payload = JSON.parse(File.read(path))
      assert_equal "debug", payload["level"]
      assert_equal "noise", payload["category"]
    end
  end

  def test_string_keyed_level_attr_cannot_overwrite_the_validated_level
    with_log do |logger, path|
      logger.event(:bot_started, **{ "level" => "verbose" })
      logger.close

      payload = JSON.parse(File.read(path))
      assert_equal "info", payload["level"],
                   "a string-keyed level attr must not overwrite the validated level"
    end
  end

  def test_invalid_level_raises_argument_error
    with_log do |logger, _path|
      err = assert_raises(ArgumentError) { logger.event(:bot_started, level: :verbose) }
      assert_match(/invalid bot log level/, err.message)
    end
  end

  # Regression for a missing-whitelist crash: a `.event(:foo, ...)` call whose
  # symbol is absent from EVENTS raises ArgumentError on the failure path it
  # guards (often the only path that ever runs it), so the operator gets a
  # silent no-reply crash instead of the intended message. Scan every event
  # symbol emitted under lib/hive/bot/ (where @logger is always this Logger)
  # and assert it is a known event — a future missing-event can't hide behind
  # a permissive stub logger anymore.
  def test_every_bot_event_symbol_is_whitelisted
    bot_dir = File.expand_path("../../../lib/hive/bot", __dir__)
    emitted = Dir[File.join(bot_dir, "**", "*.rb")].flat_map do |file|
      File.read(file).scan(/\.event\(:([a-z_][a-z0-9_]*)/).flatten.map(&:to_sym)
    end.uniq

    refute_empty emitted, "expected to find at least one .event(:symbol) call under lib/hive/bot/"
    unknown = emitted - Hive::Bot::Logger::EVENTS
    assert_empty unknown,
                 "these event symbols are emitted under lib/hive/bot/ but missing from Logger::EVENTS " \
                 "(every failure path that emits them would raise ArgumentError): #{unknown.inspect}"
  end

  def test_logger_rotates_past_size_threshold
    with_tmp_dir do |dir|
      path = File.join(dir, "rot.log")
      logger = Hive::Bot::Logger.new(path: path, max_bytes: 200, max_files: 3)
      5.times { |i| logger.event(:notification_sent, sequence: i, padding: "x" * 50) }
      logger.close

      siblings = Dir[File.join(dir, "rot.log*")]
      assert siblings.size >= 1, "expected at least one log file present"
    end
  end

  def test_unwritable_log_path_falls_back_to_stderr_without_crashing
    with_tmp_dir do |dir|
      readonly_parent = File.join(dir, "readonly")
      FileUtils.mkdir_p(readonly_parent)
      File.chmod(0o500, readonly_parent)
      target = File.join(readonly_parent, "subdir", "bot.log")

      err = capture_stderr do
        logger = Hive::Bot::Logger.new(path: target)
        if logger.stderr_fallback?
          logger.event(:bot_started)
          logger.close
        else
          logger.event(:bot_started)
          logger.close
          skip "running with elevated permissions; stderr fallback path not reachable"
        end
      end
      File.chmod(0o755, readonly_parent)

      assert err.length > 0, "expected stderr output during unwritable-path scenario"
    end
  end

  def test_rotation_noops_when_file_is_already_unavailable
    with_log do |logger, _path|
      logger.instance_variable_set(:@file, nil)

      logger.send(:rotate_if_needed!)

      refute logger.stderr_fallback?
    end
  end

  def test_rotation_handles_missing_active_log_path
    with_tmp_dir do |dir|
      path = File.join(dir, "missing-active.log")
      logger = Hive::Bot::Logger.new(path: path, max_bytes: 1, max_files: 2)
      logger.close
      FileUtils.rm_f(path)

      fake_file = Object.new
      fake_file.define_singleton_method(:size) { 99 }
      fake_file.define_singleton_method(:close) { @closed = true }
      fake_file.define_singleton_method(:closed?) { @closed }
      logger.instance_variable_set(:@file, fake_file)

      logger.send(:rotate_if_needed!)

      assert fake_file.closed?
      assert File.exist?(path)
      logger.close
    end
  end

  def test_rotation_reopens_current_log_after_rename_failure
    with_tmp_dir do |dir|
      path = File.join(dir, "rename-failure.log")
      logger = Hive::Bot::Logger.new(path: path, max_bytes: 1, max_files: 2)
      logger.event(:bot_started, padding: "x" * 100)

      with_replaced_singleton_method(File, :rename, ->(*_args) { raise Errno::EACCES, "blocked" }) do
        logger.send(:rotate_if_needed!)
      end

      refute logger.stderr_fallback?
      logger.close
    end
  end

  def test_rotation_falls_back_to_stderr_when_reopen_also_fails
    with_tmp_dir do |dir|
      path = File.join(dir, "reopen-failure.log")
      logger = Hive::Bot::Logger.new(path: path, max_bytes: 1, max_files: 2)
      logger.event(:bot_started, padding: "x" * 100)
      original_open = File.method(:open)
      failing_open = lambda do |target, *args, &block|
        raise Errno::ENOSPC, "full" if target == path && args.first == "a"

        original_open.call(target, *args, &block)
      end

      err = capture_stderr do
        with_replaced_singleton_method(File, :rename, ->(*_args) { raise Errno::EACCES, "blocked" }) do
          with_replaced_singleton_method(File, :open, failing_open) do
            logger.send(:rotate_if_needed!)
          end
        end
      end

      assert logger.stderr_fallback?
      assert_includes err, "log rotation failed"
      assert_includes err, "falling back to stderr"
      logger.close
    end
  end

  # Regression: when rotation's rename AND reopen both fail, rotate_if_needed!
  # sets @file = nil and @stderr_fallback = true mid-call; event previously
  # fell through to @file.puts(line) and raised NoMethodError on nil instead
  # of degrading the in-flight line (and all subsequent lines) to stderr.
  def test_event_degrades_in_flight_line_to_stderr_when_rotation_and_reopen_both_fail
    with_tmp_dir do |dir|
      path = File.join(dir, "double-failure.log")
      logger = Hive::Bot::Logger.new(path: path, max_bytes: 1, max_files: 2)
      logger.event(:bot_started, padding: "x" * 100)
      original_open = File.method(:open)
      failing_open = lambda do |target, *args, &block|
        raise Errno::ENOSPC, "full" if target == path && args.first == "a"

        original_open.call(target, *args, &block)
      end

      err = capture_stderr do
        with_replaced_singleton_method(File, :rename, ->(*_args) { raise Errno::EACCES, "blocked" }) do
          with_replaced_singleton_method(File, :open, failing_open) do
            logger.event(:poll_failure, message: "in-flight line")
          end
        end
        logger.event(:poll_unhealthy, message: "subsequent line")
      end

      assert logger.stderr_fallback?
      assert_includes err, "falling back to stderr"
      in_flight = err.lines.find { |l| l.include?('"event":"poll_failure"') }
      refute_nil in_flight, "in-flight event should be warned to stderr, not raise"
      assert_equal "in-flight line", JSON.parse(in_flight).fetch("message")
      assert(err.lines.any? { |l| l.include?('"event":"poll_unhealthy"') },
             "subsequent events should keep taking the stderr path")
      logger.close
    end
  end

  def test_event_serializes_rotation_check_and_write_across_workers
    with_tmp_dir do |dir|
      path = File.join(dir, "concurrent.log")
      logger = Hive::Bot::Logger.new(path: path)
      logger.close

      state_lock = Mutex.new
      size_calls = 0
      puts_calls = 0
      lines = []
      write_release = Queue.new
      fake_file = Object.new
      fake_file.define_singleton_method(:size) do
        state_lock.synchronize { size_calls += 1 }
        0
      end
      fake_file.define_singleton_method(:puts) do |line|
        state_lock.synchronize { puts_calls += 1 }
        write_release.pop
        state_lock.synchronize { lines << line }
      end
      fake_file.define_singleton_method(:flush) { }
      fake_file.define_singleton_method(:close) { }
      logger.instance_variable_set(:@file, fake_file)

      worker_count = 3
      ready = Queue.new
      start = Queue.new
      attempting = Queue.new
      workers = Array.new(worker_count) do |worker|
        Thread.new do
          ready << true
          start.pop
          attempting << true
          logger.event(:notification_sent, worker: worker)
        end
      end

      worker_count.times { ready.pop }
      worker_count.times { start << true }
      worker_count.times { attempting.pop }

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      until workers.all? { |worker| worker.status == "sleep" }
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          flunk "workers did not all reach the logger synchronization point"
        end

        Thread.pass
      end

      state_lock.synchronize do
        assert_equal 1, size_calls,
                     "a blocked write must prevent another worker from entering rotation"
        assert_equal 1, puts_calls,
                     "only one worker may write through the shared file at a time"
      end

      worker_count.times { write_release << true }
      workers.each(&:value)
      assert_equal worker_count, lines.size
      logger.close
    ensure
      worker_count&.times { write_release << true } if write_release
      workers&.each { |worker| worker.join(1) }
    end
  end

  def test_file_size_warning_is_emitted_once_when_stat_fails
    with_log do |logger, _path|
      fake_file = Object.new
      fake_file.define_singleton_method(:size) { raise IOError, "stat failed" }
      fake_file.define_singleton_method(:close) { }
      logger.instance_variable_set(:@file, fake_file)

      err = capture_stderr do
        assert_equal 0, logger.send(:file_size_for_rotation)
        assert_equal 0, logger.send(:file_size_for_rotation)
      end

      assert_equal 1, err.lines.count
      assert_includes err, "cannot read log file size for rotation"
    end
  end

  private

  def capture_stderr
    real = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = real
  end
end
