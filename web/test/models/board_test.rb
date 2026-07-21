require "test_helper"

class BoardTest < ActiveSupport::TestCase
  test "groups tasks into project workflow bands and descriptor ordered columns" do
    project_name = create_hive_project!("kanban-model-app")
    project_path = File.join(ENV.fetch("HIVE_TEST_HOME_ROOT"), "repos", project_name)
    project = Project.new(
      "name" => project_name,
      "path" => project_path,
      "hive_state_path" => File.join(project_path, ".hive-state"),
      "tasks" => [
        { "slug" => "coding-task", "stage" => "3-plan", "workflow" => "coding" },
        { "slug" => "content-task", "stage" => "2-research", "workflow" => "content" }
      ]
    )

    board = Board.new([ project ])

    assert_equal [ [ project_name, "coding" ], [ project_name, "content" ] ],
                 board.bands.map { |band| [ band.project.name, band.workflow_id ] }
    coding = board.bands.first
    content = board.bands.last
    assert_equal Hive::Workflows::Registry.fetch(:coding).stage_dirs, coding.columns.map(&:stage)
    assert_equal Hive::Workflows::Registry.fetch(:content).stage_dirs, content.columns.map(&:stage)
    assert_equal [ "coding-task" ], coding.columns.find { |column| column.stage == "3-plan" }.tasks.map(&:slug)
    assert_equal [ "content-task" ], content.columns.find { |column| column.stage == "2-research" }.tasks.map(&:slug)
  end

  test "keeps unknown stages visible after the configured workflow columns" do
    project_name = create_hive_project!("kanban-unknown-stage-app")
    project_path = File.join(ENV.fetch("HIVE_TEST_HOME_ROOT"), "repos", project_name)
    project = Project.new(
      "name" => project_name,
      "path" => project_path,
      "hive_state_path" => File.join(project_path, ".hive-state"),
      "tasks" => [
        { "slug" => "future-task", "stage" => "99-future", "workflow" => "coding" }
      ]
    )

    band = Board.new([ project ]).bands.sole

    assert_equal "99-future", band.columns.last.stage
    assert_equal [ "future-task" ], band.columns.last.tasks.map(&:slug)
  end

  test "renders an empty project through its configured default workflow" do
    project_name = create_hive_project!("kanban-empty-app")
    project_path = File.join(ENV.fetch("HIVE_TEST_HOME_ROOT"), "repos", project_name)
    project = Project.new(
      "name" => project_name,
      "path" => project_path,
      "hive_state_path" => File.join(project_path, ".hive-state"),
      "tasks" => []
    )

    band = Board.new([ project ]).bands.sole

    assert_equal "coding", band.workflow_id
    assert_equal Hive::Workflows::Registry.fetch(:coding).stage_dirs, band.columns.map(&:stage)
    assert_equal 0, band.task_count
  end
end
