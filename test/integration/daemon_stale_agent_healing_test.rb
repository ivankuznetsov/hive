require "test_helper"
require "hive/daemon/stale_agent_healer"
require "hive/daemon/status_consumer"

class DaemonStaleAgentHealingTest < Minitest::Test
  include HiveTestHelper
  NOW = Time.utc(2026, 7, 17, 12, 0, 0)

  class Controller
    def initialize(running_slug: nil) = @running_slug = running_slug
    def running_task?(project:, slug:) = slug == @running_slug
  end

  def test_dead_agent_becomes_terminal_evidence_without_queue_or_process_interruption
    with_tmp_dir do |dir|
      state_file = File.join(dir, "task.md")
      Hive::Markers.set(state_file, :agent_working, pid: 99_999_999)
      unrelated = File.join(dir, "unrelated.alive")
      File.write(unrelated, "alive")
      events = []
      logger = Object.new
      logger.define_singleton_method(:event) { |name, **attrs| events << [ name, attrs ] }
      queue = Object.new
      queue.define_singleton_method(:write_request!) { |**| flunk("must not enqueue") }
      healer = Hive::Daemon::StaleAgentHealer.new(
        controller: Controller.new(running_slug: "other-task"), logger: logger,
        request_queue: queue, attempt_dispatcher: Object.new, grace_sec: 300
      )
      row = Hive::Daemon::StatusConsumer::Row.new(
        project: "p", slug: "failed-task", stage: "4-execute", marker: "agent_working",
        marker_attrs: {}, folder: dir, state_file: state_file,
        state_file_mtime: NOW - 600, claude_pid_alive: false, live_task_lock: false
      )

      healer.heal([ row ], now: NOW)

      marker = Hive::Markers.current(state_file)
      assert_equal :error, marker.name
      assert_equal "agent_died", marker.attrs["reason"]
      assert_equal "alive", File.read(unrelated)
      assert events.any? { |name, attrs| name == :agent_reconciled && attrs[:route] == "coordinator" }
    end
  end
end
