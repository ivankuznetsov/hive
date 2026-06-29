require "test_helper"
require "hive/daemon/recoverable_error_healer"
require "hive/daemon/status_consumer"
require "hive/markers"

class HiveDaemonRecoverableErrorHealerTest < Minitest::Test
  include HiveTestHelper

  Row = Hive::Daemon::StatusConsumer::Row
  NOW = Time.utc(2026, 6, 29, 12, 0, 0)

  class FakeController
    attr_reader :observed

    def initialize(running: false)
      @running = running
      @observed = []
    end

    def running_task?(project:, slug:)
      @running
    end

    def observe_state_file_mtime(project:, slug:, mtime:)
      @observed << { project: project, slug: slug, mtime: mtime }
    end
  end

  class FakeLogger
    attr_reader :events

    def initialize
      @events = []
    end

    def event(name, **attrs)
      @events << [ name, attrs ]
    end
  end

  class FakeProbe
    attr_accessor :result
    attr_reader :calls, :ticks

    def initialize(ok: true)
      @result = { ok: ok, probes: [ { name: "fake", ok: ok } ] }
      @calls = []
      @ticks = []
    end

    def start_tick(tick)
      @ticks << tick
    end

    def probe(category)
      @calls << category
      @result
    end
  end

  class FakeSignal
    attr_accessor :fingerprint

    def initialize(fingerprint = "fp-1")
      @fingerprint = fingerprint
    end

    def fingerprint(**)
      @fingerprint
    end

    def changed_or_fallback?(current_fingerprint:, last_fingerprint:, last_attempt_at:, now:)
      last_fingerprint.to_s.empty? || current_fingerprint != last_fingerprint
    end
  end

  class FakeRequestQueue
    attr_reader :requests

    def initialize
      @requests = []
    end

    def write_request!(**kwargs)
      @requests << kwargs
      "request-1"
    end
  end

  def setup
    @logger = FakeLogger.new
    @controller = FakeController.new
    @probe = FakeProbe.new(ok: true)
    @signal = FakeSignal.new
    @queue = FakeRequestQueue.new
  end

  def healer(config: { "daemon" => { "auto_retry" => { "enabled" => true } } })
    Hive::Daemon::RecoverableErrorHealer.new(
      controller: @controller,
      logger: @logger,
      config: config,
      health_probe: @probe,
      health_signal: @signal,
      request_queue: @queue
    )
  end

  def with_error_row(stage: "4-execute", attrs: nil, workflow: "coding")
    with_tmp_dir do |dir|
      state_file = File.join(dir, "task.md")
      attrs ||= {
        "reason" => "implementer_failed",
        "provider" => "codex",
        "message" => "401 Missing bearer/basic auth"
      }
      Hive::Markers.set(state_file, :error, attrs)
      row = Row.new(
        project: "p", slug: "s", stage: stage, workflow: workflow,
        marker: "error", marker_attrs: Hive::Markers.current(state_file).attrs,
        folder: dir, state_file: state_file, state_file_mtime: File.mtime(state_file),
        action: "error", suggested_command: nil, claude_pid_alive: nil,
        live_task_lock: nil, diagnostic: nil
      )
      yield row, state_file, dir
    end
  end

  def stub_safe(value = [ true, "safe" ], &block)
    with_replaced_singleton_method(Hive::Daemon::AutoRetrySafety, :safe_to_retry?, ->(_row) { value }, &block)
  end

  def test_codex_auth_probe_success_clears_marker_and_audits
    with_error_row do |row, state_file, dir|
      stub_safe do
        healer.heal([ row ], now: NOW)
      end

      assert_equal :none, Hive::Markers.current(state_file).name
      assert_equal [ :codex_auth ], @probe.calls
      assert_equal 1, @controller.observed.size
      assert File.exist?(File.join(dir, "events.jsonl"))
      assert @logger.events.any? { |name, attrs| name == :auto_retry && attrs[:action] == "cleared" }
    end
  end

  def test_unknown_implementer_failure_is_not_cleared
    attrs = { "reason" => "implementer_failed", "provider" => "codex", "message" => "exit_code=1 compile" }
    with_error_row(attrs: attrs) do |row, state_file, _dir|
      stub_safe do
        healer.heal([ row ], now: NOW)
      end

      assert_equal :error, Hive::Markers.current(state_file).name
      assert_empty @probe.calls
      assert @logger.events.any? { |name, attrs| name == :auto_retry_skipped && attrs[:action] == "unknown_reason" }
    end
  end

  def test_probe_failure_records_fingerprint_and_suppresses_unchanged_reprobe
    @probe.result = { ok: false, probes: [ { name: "smoke", ok: false } ] }
    h = healer
    with_error_row do |row, state_file, _dir|
      stub_safe do
        h.heal([ row ], now: NOW)
        h.heal([ row ], now: NOW + 30)
      end

      assert_equal :error, Hive::Markers.current(state_file).name
      assert_equal [ :codex_auth ], @probe.calls
      assert @logger.events.any? { |name, attrs| name == :auto_retry_skipped && attrs[:action] == "probe_failed" }
    end
  end

  def test_unsafe_work_area_is_not_cleared
    with_error_row do |row, state_file, _dir|
      stub_safe([ false, "worktree dirty" ]) do
        healer.heal([ row ], now: NOW)
      end

      assert_equal :error, Hive::Markers.current(state_file).name
      assert_empty @probe.calls
      assert @logger.events.any? { |name, attrs| name == :auto_retry_skipped && attrs[:action] == "unsafe_work_area" }
    end
  end

  def test_second_retry_waits_for_backoff
    h = healer
    with_error_row do |row, state_file, _dir|
      stub_safe do
        h.heal([ row ], now: NOW)
        Hive::Markers.set(state_file, :error, row.marker_attrs.merge("marker_id" => nil))
        row.marker_attrs = Hive::Markers.current(state_file).attrs
        @signal.fingerprint = "fp-2"
        h.heal([ row ], now: NOW + 60)
      end

      assert_equal :error, Hive::Markers.current(state_file).name
      assert @logger.events.any? { |name, attrs| name == :auto_retry_skipped && attrs[:action] == "backoff" }
    end
  end

  def test_exhausts_after_two_clears
    h = healer
    with_error_row do |row, state_file, _dir|
      stub_safe do
        h.heal([ row ], now: NOW)
        2.times do |idx|
          Hive::Markers.set(state_file, :error, row.marker_attrs.merge("marker_id" => nil))
          row.marker_attrs = Hive::Markers.current(state_file).attrs
          @signal.fingerprint = "fp-#{idx + 2}"
          h.heal([ row ], now: NOW + ((idx + 1) * 1900))
        end
      end

      assert_equal :error, Hive::Markers.current(state_file).name
      exhausted = @logger.events.select { |name, _attrs| name == :auto_retry_exhausted }
      assert_equal 1, exhausted.size
    end
  end

  def test_kill_switch_disables_behavior_silently
    config = { "daemon" => { "auto_retry" => { "enabled" => false } } }
    with_error_row do |row, state_file, _dir|
      stub_safe do
        healer(config: config).heal([ row ], now: NOW)
      end

      assert_equal :error, Hive::Markers.current(state_file).name
      assert_empty @probe.calls
      assert_empty @logger.events
    end
  end

  def test_plan_stage_clear_requeues_plan_rerun
    attrs = { "reason" => "claude_launch_failed" }
    with_error_row(stage: "3-plan", attrs: attrs) do |row, state_file, _dir|
      stub_safe do
        healer.heal([ row ], now: NOW)
      end

      assert_equal :none, Hive::Markers.current(state_file).name
      assert_equal 1, @queue.requests.size
      assert_equal [ "hive", "plan", "s", "--project", "p", "--from", "3-plan" ],
                   @queue.requests.first.fetch(:argv)
    end
  end

  def test_skips_clearing_while_task_running
    @controller = FakeController.new(running: true)
    with_error_row do |row, state_file, _dir|
      stub_safe do
        healer.heal([ row ], now: NOW)
      end

      assert_equal :error, Hive::Markers.current(state_file).name
      assert_empty @probe.calls
    end
  end

  def test_skips_row_with_live_task_lock
    with_error_row do |row, state_file, _dir|
      row.live_task_lock = true
      stub_safe do
        healer.heal([ row ], now: NOW)
      end

      assert_equal :error, Hive::Markers.current(state_file).name
      assert_empty @probe.calls
    end
  end

  def test_skips_legacy_layout_projects
    with_error_row do |row, state_file, _dir|
      stub_safe do
        healer.heal([ row ], now: NOW, legacy_layout_projects: { "p" => true })
      end

      assert_equal :error, Hive::Markers.current(state_file).name
      assert_empty @probe.calls
    end
  end

  def test_nil_state_file_mtime_skips_clear_to_avoid_baseline_stranding
    with_error_row do |row, state_file, _dir|
      row.state_file_mtime = nil
      stub_safe do
        healer.heal([ row ], now: NOW)
      end

      assert_equal :error, Hive::Markers.current(state_file).name
    end
  end

  def test_unexpected_error_before_clear_logs_auto_retry_failed
    with_error_row do |row, state_file, _dir|
      @signal.define_singleton_method(:fingerprint) { |**| raise "boom" }
      stub_safe do
        healer.heal([ row ], now: NOW)
      end

      assert_equal :error, Hive::Markers.current(state_file).name
      assert @logger.events.any? { |name, attrs|
        name == :auto_retry_failed && attrs[:error].to_s.include?("boom")
      }
    end
  end

  def test_requeue_failure_after_clear_logs_heal_requeue_failed
    attrs = { "reason" => "claude_launch_failed" }
    @queue.define_singleton_method(:write_request!) { |**| raise "queue down" }
    with_error_row(stage: "3-plan", attrs: attrs) do |row, state_file, _dir|
      stub_safe do
        healer.heal([ row ], now: NOW)
      end

      # The clear already succeeded; a failed requeue must not be relabeled a
      # heal/auto-retry failure — it logs heal_requeue_failed with remediation.
      assert_equal :none, Hive::Markers.current(state_file).name
      assert @logger.events.any? { |name, _attrs| name == :auto_retry }
      assert @logger.events.any? { |name, attrs|
        name == :heal_requeue_failed && attrs[:remediation].to_s.include?("--from 3-plan")
      }
      refute @logger.events.any? { |name, _attrs| name == :auto_retry_failed }
    end
  end

  def test_unknown_reason_keeps_daemon_audit_but_suppresses_task_event
    attrs = { "reason" => "implementer_failed", "provider" => "codex", "message" => "exit_code=1 compile" }
    with_error_row(attrs: attrs) do |row, _state_file, dir|
      stub_safe do
        healer.heal([ row ], now: NOW)
      end

      refute File.exist?(File.join(dir, "events.jsonl")), "non-allowlisted reason must not write a task-timeline event"
      assert @logger.events.any? { |name, attrs| name == :auto_retry_skipped && attrs[:action] == "unknown_reason" }
    end
  end
end
