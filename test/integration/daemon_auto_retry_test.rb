require "test_helper"
require "hive/agent_limit"
require "hive/commands/init"
require "hive/daemon/dispatcher"
require "hive/daemon/concurrency_controller"
require "hive/daemon/status_consumer"
require "hive/markers"
require "hive/task_meta"

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
      @unreaped = []
      @next_pid = 1000
    end

    def reap_all(now: Time.now)
      exits = @unreaped
      @unreaped = []
      exits.each { |entry| entry.finished_at = now }
      exits
    end
    def reap_dry_run(now: Time.now) = []
    def enforce_timeouts(now:) = []
    def terminate_all(grace_sec:) = nil
    def update_timeouts(default_timeout_sec:, verb_timeouts:, kill_grace_sec:) = nil
    def in_flight_count = @unreaped.size

    def spawn(command_string:, project:, slug:, stage:, **attrs)
      @next_pid += 1
      @spawned << {
        command: command_string, project: project, slug: slug,
        stage: stage, attrs: attrs
      }
      @unreaped << Hive::Daemon::ChildSupervisor::ChildExit.new(
        pid: @next_pid,
        exit_code: 0,
        project: project,
        slug: slug,
        stage: stage,
        command: command_string,
        state_file_path: attrs[:state_file_path],
        started_at: Time.now,
        finished_at: nil,
        json_envelope: nil,
        request_id: attrs[:request_id],
        dispatch_token: attrs[:dispatch_token]
      )
      @next_pid
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
    recovery_coordinator = Hive::Daemon::RecoveryCoordinator.new(
      state_home: Hive::Paths.state_home,
      safety: ->(row) { Hive::Daemon::AutoRetrySafety.safe_to_retry?(row) }
    )
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
      logger: @logger,
      recovery_coordinator: recovery_coordinator
    )
    instance.define_singleton_method(:project_enabled?) { |_project| project_enabled }
    instance
  end

  def with_error_row(attrs:, stage: "4-execute", workflow: "coding")
    with_retry_row(
      attrs: attrs,
      marker: :error,
      stage: stage,
      workflow: workflow,
      action: "error"
    ) { |row, state_file| yield row, state_file }
  end

  def with_review_error_row(attrs:)
    with_retry_row(
      attrs: attrs,
      marker: :review_error,
      stage: "6-review",
      workflow: "coding",
      action: "recover_review"
    ) { |row, state_file| yield row, state_file }
  end

  def with_retry_row(attrs:, marker:, stage:, workflow:, action:)
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        capture_io { Hive::Commands::Init.new(project_root).call }
        slug = "auto-retry-task"
        folder = File.join(project_root, ".hive-state", "stages", stage, slug)
        FileUtils.mkdir_p(folder)
        Hive::TaskMeta.write(
          folder,
          id: 1,
          slug: slug,
          display_name: "Auto retry task",
          workflow: workflow
        )
        stage_name = stage.split("-", 2).last
        state_file = File.join(
          folder,
          Hive::Workflows::Registry.fetch(workflow.to_sym).state_file_for(stage_name)
        )
        Hive::Markers.set(state_file, marker, attrs)
        observed_at = T0 - Hive::AgentLimit.retry_cooldown_sec - 1
        File.utime(observed_at, observed_at, state_file)
        @current_project = File.basename(project_root)
        row = build_row(
          project: @current_project,
          dir: folder,
          state_file: state_file,
          marker: marker.to_s,
          stage: stage,
          workflow: workflow,
          attrs: Hive::Markers.current(state_file).attrs,
          action: action,
          observed_at: observed_at
        )
        yield row, state_file
      end
    end
  end

  def build_row(project:, dir:, state_file:, marker:, stage:, workflow:, attrs:,
                action: "error", observed_at:)
    Row.new(
      project: project, slug: "auto-retry-task", stage:, workflow:,
      marker:, marker_attrs: attrs, folder: dir, state_file:,
      state_file_mtime: observed_at,
      action:, suggested_command: nil, claude_pid_alive: nil,
      live_task_lock: nil, diagnostic: nil
    )
  end

  def set_status_rows(rows)
    projects = [ @current_project ].compact.map do |name|
      Hive::Daemon::StatusConsumer::ProjectInfo.new(
        name: name,
        legacy_stage_dirs: []
      )
    end
    @status.result = Hive::Daemon::StatusConsumer::Result.new(
      ok: true, rows: rows, projects: projects, error: nil
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
    File.utime(limited_at, limited_at, state_file)
    row.marker_attrs = Hive::Markers.current(state_file).attrs
    row.state_file_mtime = limited_at
    set_status_rows([ row ])
  end

  def run_due_recovery(instance, state_file, now:)
    instance.tick(now: now)
    assert_equal :none, Hive::Markers.current(state_file).name
    instance.tick(now: now + 1)
  end

  def test_one_universal_owner_retries_arbitrary_error_and_review_error_reasons
    with_error_row(
      attrs: { "reason" => "agent_preflight_failed", "message" => "binary not runnable" },
      stage: "3-generate",
      workflow: "bench"
    ) do |row, state_file|
      set_status_rows([ row ])
      stub_safe { run_due_recovery(dispatcher, state_file, now: T0) }
    end

    with_review_error_row(
      attrs: { "phase" => "fix", "reason" => "fix_tampered", "pass" => "1" }
    ) do |row, state_file|
      set_status_rows([ row ])
      stub_safe { run_due_recovery(dispatcher, state_file, now: T0) }
    end

    recoveries = @logger.events.select { |name, _attrs| name == :recovery_requested }
    assert_equal 2, recoveries.size
    refute @logger.events.any? { |name, _attrs| name == :auto_retry_skipped }
  end

  def test_current_work_area_safety_defers_without_making_error_terminal
    with_error_row(attrs: { "reason" => "implementer_failed" }) do |row, state_file|
      set_status_rows([ row ])
      instance = dispatcher

      stub_safe([ false, "worktree dirty" ]) { instance.tick(now: T0) }
      assert_equal :error, Hive::Markers.current(state_file).name

      stub_safe([ true, "worktree clean" ]) do
        run_due_recovery(instance, state_file, now: T0 + 30)
      end
    end
  end

  def test_each_fresh_failure_restarts_cooldown_and_retries_never_exhaust
    with_error_row(attrs: { "reason" => "implementer_failed" }) do |row, state_file|
      set_status_rows([ row ])
      instance = dispatcher

      stub_safe do
        run_due_recovery(instance, state_file, now: T0)

        second_at = T0 + 60
        repark(row, state_file, limited_at: second_at)
        instance.tick(now: second_at + Hive::AgentLimit.retry_cooldown_sec - 1)
        assert_equal :error, Hive::Markers.current(state_file).name
        run_due_recovery(
          instance,
          state_file,
          now: second_at + Hive::AgentLimit.retry_cooldown_sec
        )

        third_at = second_at + Hive::AgentLimit.retry_cooldown_sec + 60
        repark(row, state_file, limited_at: third_at)
        run_due_recovery(
          instance,
          state_file,
          now: third_at + Hive::AgentLimit.retry_cooldown_sec
        )
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
