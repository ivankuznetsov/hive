require "test_helper"
require "hive/tui/bubble_model"
require "hive/usage_db"

class TuiUsageFooterTest < Minitest::Test
  include HiveTestHelper

  def setup
    @old_usage_path = Hive::UsageDb.path
  end

  def teardown
    Hive::UsageDb.path = @old_usage_path
  end

  def row
    Hive::Tui::Snapshot::Row.new(
      project_name: "demo",
      stage: "2-brainstorm",
      slug: "task-one",
      folder: "/tmp/demo/.hive-state/stages/2-brainstorm/task-one",
      state_file: "/tmp/demo/.hive-state/stages/2-brainstorm/task-one/brainstorm.md",
      marker: "complete",
      attrs: {},
      mtime: "2026-05-24T12:00:00Z",
      age_seconds: 0,
      claude_pid: nil,
      claude_pid_alive: nil,
      action_key: "ready_to_plan",
      action_label: "Ready to plan",
      suggested_command: "hive plan task-one --from 2-brainstorm",
      next_action: nil,
      diagnostic: nil
    )
  end

  def snapshot
    project = Hive::Tui::Snapshot::ProjectView.new(
      name: "demo",
      path: "/tmp/demo",
      hive_state_path: "/tmp/demo/.hive-state",
      error: nil,
      rows: [ row ].freeze
    ).freeze
    Hive::Tui::Snapshot.new(generated_at: "2026-05-24T12:00:00Z", projects: [ project ])
  end

  def test_footer_reads_task_scoped_usage_from_db
    with_tmp_dir do |dir|
      Hive::UsageDb.path = File.join(dir, "usage.db")
      Hive::UsageDb.record!(
        agent: "claude",
        model: "model",
        project_slug: "demo",
        task_slug: "task-one",
        stage: "2-brainstorm",
        started_at: Time.now.utc,
        ended_at: Time.now.utc,
        input: 1_500,
        output: 100,
        cached: 0
      )

      model = Hive::Tui::Model.initial.with(
        snapshot: snapshot,
        cursor: [ 0, 0 ],
        pane_focus: :right,
        cols: 180
      )
      bubble = Hive::Tui::BubbleModel.new(hive_model: model)

      out = bubble.send(:default_footer, 180)

      assert_includes out, "today 1.5k/100/0"
      assert_includes out, " • all 1.5k/100/0 • tokens"
      refute_includes out, "30d"
      assert_includes out, "[Tab] switch"
    end
  end
end
