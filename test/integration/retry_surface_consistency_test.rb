require "test_helper"
require "json_schemer"
require "hive/attempts/store"
require "hive/bot/status_watcher"
require "hive/commands/status"
require "hive/daemon/retry_coordinator"
require "hive/daemon/status_consumer"
require "hive/tui/snapshot"
require "hive/web/status_feed"
require_relative "../support/retry_coordinator_helpers"

class RetrySurfaceConsistencyTest < Minitest::Test
  include HiveTestHelper
  include RetryCoordinatorTestHelpers

  NOW = Time.utc(2026, 7, 17, 16, 0, 0)

  StaticStatus = Struct.new(:payload) do
    def json_payload(_projects) = payload
  end

  def test_status_daemon_tui_bot_and_web_copy_the_same_retry_object
    with_tmp_dir do |root|
      slug = "surface-retry-260717-abcd"
      hive_state = File.join(root, ".hive-state")
      task_dir = File.join(hive_state, "stages", "4-execute", slug)
      FileUtils.mkdir_p(task_dir)
      File.write(File.join(task_dir, "task.md"), "# Task\n\n<!-- ERROR reason=exit_code exit_code=1 -->\n")
      store = Hive::Attempts::Store.new(root: File.join(root, "attempts"))
      attempt = create_failed_retry_attempt(
        store, id: "surface-failed", now: NOW, project: "demo", slug: slug
      )
      coordinator = Hive::Daemon::RetryCoordinator.new(
        task_folder: task_dir, attempt_store: store, clock: -> { NOW }
      )
      record = coordinator.report_failure(
        **retry_failure_args(attempt, code: "agent_died", terminal_event_id: "surface-terminal")
      ).to_h

      payload = Hive::Commands::Status.new(json: true).json_payload([
        { "name" => "demo", "path" => root, "hive_state_path" => hive_state }
      ])
      status_row = payload.dig("projects", 0, "tasks", 0)
      assert_equal record, status_row.fetch("retry")

      schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-status"))))
      assert schema.valid?(payload), schema.validate(payload).map { |error| error["error"] }.inspect

      tui_row = Hive::Tui::Snapshot.from_payload(payload).rows.fetch(0)
      daemon_row = Hive::Daemon::StatusConsumer.new.send(:extract_rows, payload).fetch(0)
      bot_row = Hive::Bot::StatusWatcher.new.send(:extract_rows, payload, now: NOW).fetch(0)
      web_row = Hive::Web::StatusFeed.new(status_command: StaticStatus.new(payload))
                .snapshot.dig("projects", 0, "tasks", 0)

      assert_equal record, tui_row.retry
      assert_equal record, daemon_row.retry
      assert_equal record, bot_row.retry
      assert_equal record, web_row.fetch("retry")
      assert_equal "cooldown", tui_row.retry.fetch("state")
      refute_equal "ready", daemon_row.retry.fetch("state")
    end
  end
end
