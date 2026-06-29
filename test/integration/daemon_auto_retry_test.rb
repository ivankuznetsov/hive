require "test_helper"
require "hive/daemon/dispatcher"
require "hive/daemon/concurrency_controller"
require "hive/daemon/recoverable_error_healer"
require "hive/daemon/status_consumer"
require "hive/markers"

class DaemonAutoRetryTest < Minitest::Test
  include HiveTestHelper

  T0 = Time.utc(2026, 6, 29, 12, 0, 0)
  Row = Hive::Daemon::StatusConsumer::Row

  class FakeStatusConsumer
    attr_accessor :result

    def fetch
      result || Hive::Daemon::StatusConsumer::Result.new(ok: true, rows: [], projects: [], error: nil)
    end
  end

  class FakeSupervisor
    attr_reader :spawned

    def initialize
      @spawned = []
      @next_pid = 1000
    end

    def reap_all(now: Time.now) = []
    def reap_dry_run(now: Time.now) = []
    def enforce_timeouts(now:) = []
    def terminate_all(grace_sec:) = nil
    def update_timeouts(default_timeout_sec:, verb_timeouts:, kill_grace_sec:) = nil
    def in_flight_count = @spawned.size

    def spawn(command_string:, project:, slug:, stage:, **attrs)
      @spawned << { command: command_string, project: project, slug: slug, stage: stage, attrs: attrs }
      @next_pid += 1
    end
  end

  class FakeLogger
    attr_reader :events

    def initialize
      @events = []
    end

    def event(name, **attrs)
      unless Hive::Daemon::Logger::EVENTS.include?(name)
        raise ArgumentError, "unknown daemon log event in integration fake: #{name.inspect}"
      end
      @events << [ name, attrs ]
    end

    def close = nil
  end

  class FakeProbe
    attr_accessor :ok
    attr_reader :calls

    def initialize(ok: true)
      @ok = ok
      @calls = []
    end

    def start_tick(_tick) = nil

    def probe(category)
      @calls << category
      { ok: ok, probes: [ { name: "fake", ok: ok } ] }
    end
  end

  class FakeSignal
    attr_accessor :fingerprint

    def initialize
      @fingerprint = "fp-1"
    end

    def fingerprint(**) = @fingerprint

    def changed_or_fallback?(current_fingerprint:, last_fingerprint:, last_attempt_at:, now:)
      last_fingerprint.to_s.empty? || current_fingerprint != last_fingerprint
    end
  end

  def setup
    @status = FakeStatusConsumer.new
    @supervisor = FakeSupervisor.new
    @logger = FakeLogger.new
    @controller = Hive::Daemon::ConcurrencyController.new(
      max_concurrent_runs: 3,
      max_concurrent_per_project: 3,
      max_runs_per_day_per_project: 50
    )
    @probe = FakeProbe.new(ok: true)
    @signal = FakeSignal.new
  end

  def dispatcher(config: { "daemon" => { "auto_retry" => { "enabled" => true }, "poll_interval_sec" => 30 } })
    d = Hive::Daemon::Dispatcher.new(
      config: config,
      controller: @controller,
      supervisor: @supervisor,
      status_consumer: @status,
      logger: @logger
    )
    d.define_singleton_method(:project_enabled?) { |_project| true }
    d.instance_variable_set(
      :@recoverable_error_healer,
      Hive::Daemon::RecoverableErrorHealer.new(
        controller: @controller,
        logger: @logger,
        config: config,
        health_probe: @probe,
        health_signal: @signal
      )
    )
    d
  end

  def with_error_row(attrs:)
    with_tmp_dir do |dir|
      state_file = File.join(dir, "task.md")
      Hive::Markers.set(state_file, :error, attrs)
      row = Row.new(
        project: "p", slug: "auto-retry-task", stage: "4-execute", workflow: "coding",
        marker: "error", marker_attrs: Hive::Markers.current(state_file).attrs,
        folder: dir, state_file: state_file, state_file_mtime: File.mtime(state_file),
        action: "error", suggested_command: nil, claude_pid_alive: nil,
        live_task_lock: nil, diagnostic: nil
      )
      yield row, state_file, dir
    end
  end

  def set_status_rows(rows)
    @status.result = Hive::Daemon::StatusConsumer::Result.new(
      ok: true,
      rows: rows,
      projects: [],
      error: nil
    )
  end

  def stub_safe(value = [ true, "safe" ])
    with_replaced_singleton_method(Hive::Daemon::AutoRetrySafety, :safe_to_retry?, ->(_row) { value }) do
      yield
    end
  end

  def test_codex_auth_marker_clears_and_audits_through_dispatcher_tick
    attrs = {
      "reason" => "implementer_failed",
      "provider" => "codex",
      "message" => "401 Missing bearer/basic auth"
    }
    with_error_row(attrs: attrs) do |row, state_file, dir|
      set_status_rows([ row ])
      stub_safe { dispatcher.tick(now: T0) }

      assert_equal :none, Hive::Markers.current(state_file).name
      assert_equal [ :codex_auth ], @probe.calls
      assert @logger.events.any? { |name, _attrs| name == :auto_retry }
      event_types = File.readlines(File.join(dir, "events.jsonl"), chomp: true).map { |line| JSON.parse(line).fetch("event_type") }
      assert_includes event_types, "auto_retry"
    end
  end

  def test_unknown_implementer_failure_stays_parked
    attrs = {
      "reason" => "implementer_failed",
      "provider" => "codex",
      "message" => "exit_code=1 failing tests"
    }
    with_error_row(attrs: attrs) do |row, state_file, _dir|
      set_status_rows([ row ])
      stub_safe { dispatcher.tick(now: T0) }

      assert_equal :error, Hive::Markers.current(state_file).name
      assert_empty @probe.calls
      assert @logger.events.any? { |name, attrs| name == :auto_retry_skipped && attrs[:action] == "unknown_reason" }
    end
  end

  def test_probe_failure_stays_parked_and_audits_skip
    @probe.ok = false
    attrs = { "reason" => "claude_launch_failed" }
    with_error_row(attrs: attrs) do |row, state_file, _dir|
      set_status_rows([ row ])
      stub_safe { dispatcher.tick(now: T0) }

      assert_equal :error, Hive::Markers.current(state_file).name
      assert_equal [ :claude_launcher ], @probe.calls
      assert @logger.events.any? { |name, attrs| name == :auto_retry_skipped && attrs[:action] == "probe_failed" }
    end
  end

  def test_dirty_work_area_stays_parked_without_probe
    attrs = {
      "reason" => "implementer_failed",
      "provider" => "codex",
      "message" => "401 Missing bearer/basic auth"
    }
    with_error_row(attrs: attrs) do |row, state_file, _dir|
      set_status_rows([ row ])
      stub_safe([ false, "worktree dirty" ]) { dispatcher.tick(now: T0) }

      assert_equal :error, Hive::Markers.current(state_file).name
      assert_empty @probe.calls
      assert @logger.events.any? { |name, attrs| name == :auto_retry_skipped && attrs[:action] == "unsafe_work_area" }
    end
  end

  def test_kill_switch_leaves_marker_and_skips_probe_and_audit
    attrs = { "reason" => "claude_launch_failed" }
    config = { "daemon" => { "auto_retry" => { "enabled" => false }, "poll_interval_sec" => 30 } }
    with_error_row(attrs: attrs) do |row, state_file, _dir|
      set_status_rows([ row ])
      stub_safe { dispatcher(config: config).tick(now: T0) }

      assert_equal :error, Hive::Markers.current(state_file).name
      assert_empty @probe.calls
      refute @logger.events.any? { |name, _attrs| %i[auto_retry auto_retry_skipped].include?(name) }
    end
  end
end
