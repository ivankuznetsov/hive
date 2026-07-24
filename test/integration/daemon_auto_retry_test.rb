require "test_helper"
require "hive/agent_limit"
require "hive/daemon/dispatcher"
require "hive/daemon/concurrency_controller"
require "hive/daemon/status_consumer"
require "hive/markers"

class DaemonAutoRetryTest < Minitest::Test
  include HiveTestHelper

  T0 = Time.utc(2026, 6, 29, 12, 0, 0)
  Row = Hive::Daemon::StatusConsumer::Row

  class FakeStatusConsumer
    attr_accessor :result

    def fetch
      result || Hive::Daemon::StatusConsumer::Result.new(
        ok: true, rows: [], projects: [], error: nil
      )
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
      @spawned << {
        command: command_string, project: project, slug: slug,
        stage: stage, attrs: attrs
      }
      @next_pid += 1
    end
  end

  class FakeLogger
    attr_reader :events

    def initialize
      @events = []
    end

    def event(name, **attrs)
      raise ArgumentError, "unknown daemon log event #{name.inspect}" unless Hive::Daemon::Logger::EVENTS.include?(name)

      @events << [ name, attrs ]
    end

    def close = nil
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
  end

  def dispatcher(auto_retry: true, project_enabled: true)
    instance = Hive::Daemon::Dispatcher.new(
      config: {
        "daemon" => {
          "auto_retry" => { "enabled" => auto_retry },
          "poll_interval_sec" => 30
        }
      },
      controller: @controller,
      supervisor: @supervisor,
      status_consumer: @status,
      logger: @logger
    )
    instance.define_singleton_method(:project_enabled?) { |_project| project_enabled }
    instance
  end

  def with_error_row(attrs:, stage: "4-execute", workflow: "coding")
    with_tmp_dir do |dir|
      state_file = File.join(dir, "task.md")
      Hive::Markers.set(state_file, :error, attrs)
      row = build_row(
        dir:, state_file:, marker: "error", stage:, workflow:,
        attrs: Hive::Markers.current(state_file).attrs
      )
      yield row, state_file
    end
  end

  def with_review_error_row(attrs:)
    with_tmp_dir do |dir|
      state_file = File.join(dir, "task.md")
      Hive::Markers.set(state_file, :review_error, attrs)
      row = build_row(
        dir:, state_file:, marker: "review_error", stage: "6-review",
        workflow: "coding", attrs: Hive::Markers.current(state_file).attrs,
        action: "recover_review"
      )
      yield row, state_file
    end
  end

  def build_row(dir:, state_file:, marker:, stage:, workflow:, attrs:, action: "error")
    Row.new(
      project: "p", slug: "auto-retry-task", stage:, workflow:,
      marker:, marker_attrs: attrs, folder: dir, state_file:,
      state_file_mtime: T0 - Hive::AgentLimit.retry_cooldown_sec - 1,
      action:, suggested_command: nil, claude_pid_alive: nil,
      live_task_lock: nil, diagnostic: nil
    )
  end

  def set_status_rows(rows)
    @status.result = Hive::Daemon::StatusConsumer::Result.new(
      ok: true, rows:, projects: [], error: nil
    )
  end

  def stub_safe(value = [ true, "safe" ], &block)
    with_replaced_singleton_method(
      Hive::Daemon::AutoRetrySafety,
      :safe_to_retry?,
      ->(_row) { value },
      &block
    )
  end

  def repark(row, state_file, limited_at:)
    Hive::Markers.set(state_file, row.marker, row.marker_attrs.merge("marker_id" => nil))
    row.marker_attrs = Hive::Markers.current(state_file).attrs
    row.state_file_mtime = limited_at
    set_status_rows([ row ])
  end

  def test_one_universal_owner_retries_arbitrary_error_and_review_error_reasons
    with_error_row(
      attrs: { "reason" => "agent_preflight_failed", "message" => "binary not runnable" },
      stage: "3-generate",
      workflow: "bench"
    ) do |row, state_file|
      set_status_rows([ row ])
      stub_safe { dispatcher.tick(now: T0) }

      assert_equal :none, Hive::Markers.current(state_file).name
    end

    with_review_error_row(
      attrs: { "phase" => "fix", "reason" => "fix_tampered", "pass" => "1" }
    ) do |row, state_file|
      set_status_rows([ row ])
      stub_safe { dispatcher.tick(now: T0) }

      assert_equal :none, Hive::Markers.current(state_file).name
    end

    heals = @logger.events.select { |name, _attrs| name == :marker_healed }
    assert_equal 2, heals.size
    refute @logger.events.any? { |name, _attrs| name == :auto_retry_skipped }
  end

  def test_current_work_area_safety_defers_without_making_error_terminal
    with_error_row(attrs: { "reason" => "implementer_failed" }) do |row, state_file|
      set_status_rows([ row ])
      instance = dispatcher

      stub_safe([ false, "worktree dirty" ]) { instance.tick(now: T0) }
      assert_equal :error, Hive::Markers.current(state_file).name

      stub_safe([ true, "worktree clean" ]) { instance.tick(now: T0 + 30) }
      assert_equal :none, Hive::Markers.current(state_file).name
    end
  end

  def test_each_fresh_failure_restarts_cooldown_and_retries_never_exhaust
    with_error_row(attrs: { "reason" => "implementer_failed" }) do |row, state_file|
      set_status_rows([ row ])
      instance = dispatcher

      stub_safe do
        instance.tick(now: T0)
        assert_equal :none, Hive::Markers.current(state_file).name

        second_at = T0 + 60
        repark(row, state_file, limited_at: second_at)
        instance.tick(now: second_at + Hive::AgentLimit.retry_cooldown_sec - 1)
        assert_equal :error, Hive::Markers.current(state_file).name
        instance.tick(now: second_at + Hive::AgentLimit.retry_cooldown_sec)
        assert_equal :none, Hive::Markers.current(state_file).name

        third_at = second_at + Hive::AgentLimit.retry_cooldown_sec + 60
        repark(row, state_file, limited_at: third_at)
        instance.tick(now: third_at + Hive::AgentLimit.retry_cooldown_sec)
        assert_equal :none, Hive::Markers.current(state_file).name
      end

      refute @logger.events.any? { |name, _attrs| name == :auto_retry_exhausted }
    end
  end

  def test_global_kill_switch_and_project_disable_leave_markers_parked
    [
      dispatcher(auto_retry: false, project_enabled: true),
      dispatcher(auto_retry: true, project_enabled: false)
    ].each do |instance|
      with_error_row(attrs: { "reason" => "claude_launch_failed" }) do |row, state_file|
        set_status_rows([ row ])
        stub_safe { instance.tick(now: T0) }

        assert_equal :error, Hive::Markers.current(state_file).name
      end
    end

    refute @logger.events.any? { |name, _attrs| name == :marker_healed }
  end
end
