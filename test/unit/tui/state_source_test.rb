require "test_helper"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/status"
require "hive/tui/state_source"

# StateSource is the only TUI component that touches threads, so these
# tests pin two contracts hard: (1) the polling thread really does land
# a Snapshot in `#current` (using the real registry + real Status
# command — no mocks of the JSON payload), and (2) `#stop` deterministically
# tears the thread down so test teardown never leaks a worker.
class TuiStateSourceTest < Minitest::Test
  include HiveTestHelper

  # Spin until `block` returns truthy or the deadline elapses. Returns
  # the truthy value or nil. Replaces `sleep N` (forbidden by project
  # rules; flaky and hides timing issues) with an explicit poll.
  def wait_for(deadline_seconds: 2.0, interval: 0.02)
    deadline = Time.now + deadline_seconds
    loop do
      result = yield
      return result if result
      return nil if Time.now > deadline

      sleep interval
    end
  end

  def with_seeded_project
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        project = File.basename(dir)
        capture_io { Hive::Commands::New.new(project, "probe").call }
        yield(project, dir)
      end
    end
  end

  def test_start_polls_real_status_and_populates_current
    with_seeded_project do |project, _dir|
      source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
      source.start
      begin
        snapshot = wait_for { source.current }
        refute_nil snapshot, "current should be populated within the deadline"
        assert_operator snapshot.rows.size, :>=, 1, "seeded project must have at least one row"

        first_row = snapshot.rows.first
        assert_match(/probe-/, first_row.slug,
                     "row slug should match the seeded slug pattern")
        assert_equal project, first_row.project_name
      ensure
        source.stop
      end

      refute_includes Thread.list, source.instance_variable_get(:@thread),
                      "stop must drop the polling thread out of Thread.list"
      assert_nil source.last_error, "happy path leaves last_error nil"
    end
  end

  def test_last_error_records_failure_and_clears_on_subsequent_success
    with_seeded_project do |_project, _dir|
      # Inject a one-shot raise into `Status#json_payload` via a
      # prepended module. We capture the call count on a sentinel so the
      # next call after the raise falls through to the real implementation,
      # producing a successful poll that should clear @last_error.
      raised = false
      patch = Module.new do
        define_method(:json_payload) do |projects|
          unless raised
            raised = true
            raise StandardError, "synthetic refresh failure"
          end
          super(projects)
        end
      end
      Hive::Commands::Status.prepend(patch)

      begin
        source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
        source.start
        begin
          err = wait_for { source.last_error }
          refute_nil err, "first poll's failure must populate last_error"
          assert_match(/synthetic refresh failure/, err.message)

          # Subsequent successful poll: current becomes non-nil and
          # last_error clears.
          snapshot = wait_for { source.current }
          refute_nil snapshot, "successful poll after failure must populate current"
          cleared = wait_for { source.last_error.nil? }
          assert cleared, "last_error must clear after a successful poll"
        ensure
          source.stop
        end
      ensure
        # Flip the toggle so any leftover call into the prepended patch
        # falls through to `super(projects)` — equivalent to a no-op.
        # MRI has no `unprepend`, so the prepended Module remains on
        # `Hive::Commands::Status.ancestors`. That's an acceptable leak
        # because the patch is now inert (raised==true short-circuits
        # the raise branch on every subsequent call) and each test that
        # injects a fresh Module gets its own ancestor entry rather
        # than mutating ours.
        raised = true
      end
    end
  end

  def test_stalled_when_current_seen_at_older_than_threshold
    source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
    source.instance_variable_set(:@current_seen_at, Time.now - 6.0)
    assert source.stalled?, "snapshot 6s old must be stalled at default 5s threshold"

    source.instance_variable_set(:@current_seen_at, Time.now - 1.0)
    refute source.stalled?, "snapshot 1s old must not be stalled"
  end

  def test_stalled_in_boot_state_with_no_successful_poll
    source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
    assert source.stalled?, "boot state (no successful poll) counts as stalled"
  end

  def test_stop_is_safe_when_start_was_never_called
    source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
    # Should not raise.
    source.stop
  end

  # Renderer reads `last_error` and `stalled?` together when poll
  # failures persist; pin that both stay reachable via the public
  # surface (no instance-variable peeking) after a refresh fault.
  def test_stalled_and_last_error_are_both_reachable_when_poll_fails
    raised = false
    keep_raising = true
    patch = Module.new do
      define_method(:json_payload) do |projects|
        if keep_raising
          raised = true
          raise StandardError, "synthetic refresh failure"
        end
        super(projects)
      end
    end
    Hive::Commands::Status.prepend(patch)

    begin
      with_seeded_project do |_project, _dir|
        source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
        source.start
        begin
          err = wait_for { source.last_error }
          refute_nil err, "poll failure must populate last_error"
          assert source.stalled?, "no successful poll yet — must report stalled"
          assert_match(/synthetic refresh failure/, err.message)
          assert raised
        ensure
          source.stop
        end
      end
    ensure
      # See sibling test — MRI has no `unprepend`. Flip `keep_raising`
      # so any future call through the prepended Module falls through
      # to `super(projects)` (a no-op). The empty/no-op Module remains
      # on the ancestor chain; that's the documented acceptable leak.
      keep_raising = false
    end
  end

  def test_refresh_once_skips_status_parse_when_mtime_fingerprint_is_unchanged
    with_seeded_project do |_project, _dir|
      calls = 0
      patch = Module.new do
        define_method(:json_payload) do |projects|
          calls += 1
          super(projects)
        end
      end
      Hive::Commands::Status.prepend(patch)

      source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
      source.send(:refresh_once)
      first = source.current
      source.send(:refresh_once)

      assert_equal 1, calls, "unchanged mtimes should reuse the cached snapshot"
      assert_same first, source.current
    end
  end

  def test_refresh_once_reparses_when_state_file_mtime_changes
    with_seeded_project do |_project, _dir|
      calls = 0
      patch = Module.new do
        define_method(:json_payload) do |projects|
          calls += 1
          super(projects)
        end
      end
      Hive::Commands::Status.prepend(patch)

      source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
      source.send(:refresh_once)
      state_file = source.current.rows.first.state_file
      File.utime(Time.now + 5, Time.now + 5, state_file)
      source.send(:refresh_once)

      assert_equal 2, calls, "state-file mtime changes must invalidate the cached snapshot"
    end
  end

  def test_safe_mtime_returns_nil_when_mtime_raises_on_existing_path
    # state_source.rb 152: the file may vanish (or error) between the
    # File.exist? check and File.mtime. The rescue must degrade to nil
    # rather than propagate out of the fingerprint computation.
    source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)

    Dir.mktmpdir("state-source-safe-mtime") do |dir|
      path = File.join(dir, "vanishing.md")
      File.write(path, "x\n")
      with_replaced_singleton_method(File, :mtime, lambda { |arg|
        raise Errno::ENOENT, arg if arg == path

        File.stat(arg).mtime
      }) do
        assert_nil source.send(:safe_mtime, path),
                   "safe_mtime must return nil when File.mtime raises after File.exist? passed"
      end
    end
  end

  def test_registry_config_path_returns_nil_when_global_config_path_raises
    # state_source.rb 141: mtime_fingerprint_for must keep working even
    # if the registry path lookup blows up (e.g. HOME unset / config
    # subsystem error). The rescue degrades to nil so the registry path
    # is simply dropped from the watched-mtime set instead of crashing
    # the poll thread.
    source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)

    with_replaced_singleton_method(Hive::Config, :global_config_path, lambda {
      raise StandardError, "registry path unavailable"
    }) do
      assert_nil source.send(:registry_config_path),
                 "registry_config_path must degrade to nil when global_config_path raises"
    end
  end

  def test_poll_loop_observes_state_file_change_within_latency_budget
    with_seeded_project do |_project, _dir|
      source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
      source.start
      begin
        first = wait_for(deadline_seconds: 0.5) { source.current }
        refute_nil first

        state_file = first.rows.first.state_file
        File.utime(Time.now + 5, Time.now + 5, state_file)

        changed = wait_for(deadline_seconds: 1.5) { source.current unless source.current.equal?(first) }
        refute_nil changed, "state-file mtime changes must produce a fresh snapshot within 1.5s"
      ensure
        source.stop
      end
    end
  end
end
