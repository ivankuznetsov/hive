require "test_helper"
require "hive/daemon/stale_agent_healer"
require "hive/daemon/status_consumer"

class HiveDaemonStaleAgentHealerTest < Minitest::Test
  include HiveTestHelper
  Row = Hive::Daemon::StatusConsumer::Row
  NOW = Time.utc(2026, 7, 17, 12, 0, 0)

  class Controller
    def initialize(running = false) = @running = running
    def running_task?(**) = @running
  end

  class Logger
    attr_reader :events
    def initialize = @events = []
    def event(name, **attrs) = @events << [ name, attrs ]
  end

  def test_dead_pid_is_terminalized_without_marker_clear_or_dispatch
    with_tmp_dir do |dir|
      state_file = File.join(dir, "task.md")
      Hive::Markers.set(state_file, :agent_working)
      logger = Logger.new
      healer = Hive::Daemon::StaleAgentHealer.new(
        controller: Controller.new, logger: logger, grace_sec: 300,
        request_queue: Object.new, attempt_dispatcher: Object.new
      )
      row = build_row(state_file, claude_pid_alive: false)

      healer.heal([ row ], now: NOW)

      marker = Hive::Markers.current(state_file)
      assert_equal :error, marker.name
      assert_equal "agent_died", marker.attrs["reason"]
      assert logger.events.any? { |name, attrs| name == :agent_reconciled && attrs[:route] == "coordinator" }
    end
  end

  def test_orphan_grace_is_observation_only_then_writes_terminal_evidence
    with_tmp_dir do |dir|
      state_file = File.join(dir, "task.md")
      Hive::Markers.set(state_file, :agent_working)
      healer = Hive::Daemon::StaleAgentHealer.new(
        controller: Controller.new, logger: Logger.new, grace_sec: 300
      )

      healer.heal([ build_row(state_file, claude_pid_alive: nil, mtime: NOW - 299) ], now: NOW)
      assert_equal :agent_working, Hive::Markers.current(state_file).name

      healer.heal([ build_row(state_file, claude_pid_alive: nil, mtime: NOW - 300) ], now: NOW)
      marker = Hive::Markers.current(state_file)
      assert_equal :error, marker.name
      assert_equal "agent_orphaned", marker.attrs["reason"]
    end
  end

  def test_lost_attempt_processing_preserves_work_but_never_dispatches
    processed = []
    processor = Object.new
    processor.define_singleton_method(:process) { |attempt, now:| processed << [ attempt, now ] }
    reporter = Object.new
    reported = []
    reporter.define_singleton_method(:observe) { |attempt| reported << attempt }
    healer = Hive::Daemon::StaleAgentHealer.new(
      controller: Controller.new, logger: Logger.new,
      lost_outcome_processor: processor, failure_reporter: reporter,
      attempt_dispatcher: Object.new
    )
    attempt = Object.new

    healer.heal_attempt_losses([ attempt ], now: NOW)

    assert_equal [ [ attempt, NOW ] ], processed
    assert_equal [ attempt ], reported
  end

  private

  def build_row(state_file, claude_pid_alive:, mtime: NOW - 600)
    Row.new(
      project: "p", slug: "s", stage: "4-execute", marker: "agent_working",
      marker_attrs: {}, folder: File.dirname(state_file), state_file: state_file,
      state_file_mtime: mtime, action: "error", claude_pid_alive: claude_pid_alive,
      live_task_lock: false
    )
  end
end
