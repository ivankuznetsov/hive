require "test_helper"
require "hive/tui/bubble_model"
require "hive/usage_db"

class TuiTokenStatsTest < Minitest::Test
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

  def test_opens_task_scoped_matrix_and_closes_back_to_grid
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
        input: 2_000,
        output: 300,
        cached: 10
      )
      Hive::UsageDb.record!(
        agent: "codex",
        model: "model",
        project_slug: "demo",
        task_slug: "task-one",
        stage: "patrol-review",
        started_at: Time.now.utc,
        ended_at: Time.now.utc,
        input: 50,
        output: 5,
        cached: 1
      )
      model = Hive::Tui::Model.initial(cols: 120, rows: 30).with(
        snapshot: snapshot,
        cursor: [ 0, 0 ],
        pane_focus: :right
      )
      bubble = Hive::Tui::BubbleModel.new(hive_model: model)

      bubble.update(Hive::Tui::Messages::OPEN_TOKEN_STATS)
      out = bubble.view

      assert_equal :token_stats, bubble.hive_model.mode
      assert_includes out, "scope: demo / task-one"
      assert_includes out, "2k/300/10"
      assert_includes out, "patrol"
      assert_includes out, "50/5/1"

      bubble.update(Hive::Tui::Messages::CLOSE_TOKEN_STATS)

      assert_equal :grid, bubble.hive_model.mode
      assert_nil bubble.hive_model.token_stats_state
    end
  end
end
