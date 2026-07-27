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
    assert_equal "Open PR", coding.columns.find { |column| column.stage == "5-open-pr" }.label
    assert_equal Hive::Workflows::Registry.fetch(:content).stage_dirs, content.columns.map(&:stage)
    assert_equal [ "coding-task" ], coding.columns.find { |column| column.stage == "3-plan" }.tasks.map(&:slug)
    assert_equal [ "content-task" ], content.columns.find { |column| column.stage == "2-research" }.tasks.map(&:slug)
  end

  test "attaches a project hidden count to exactly one workflow band" do
    project_name = create_hive_project!("kanban-hidden-archive-app")
    project_path = File.join(ENV.fetch("HIVE_TEST_HOME_ROOT"), "repos", project_name)
    project = Project.new(
      "name" => project_name,
      "path" => project_path,
      "hive_state_path" => File.join(project_path, ".hive-state"),
      "hidden_archived_task_count" => 3,
      "tasks" => [
        { "slug" => "coding-task", "stage" => "3-plan", "workflow" => "coding" },
        { "slug" => "content-task", "stage" => "2-research", "workflow" => "content" }
      ]
    )

    bands = Board.new([ project ]).bands

    assert_equal [ 3, 0 ], bands.map(&:hidden_archived_task_count)
    assert_equal 3, bands.sum(&:hidden_archived_task_count)
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

  test "keeps tasks visible and marks an unknown workflow unavailable" do
    project_name = create_hive_project!("kanban-missing-workflow-app")
    project_path = File.join(ENV.fetch("HIVE_TEST_HOME_ROOT"), "repos", project_name)
    project = Project.new(
      "name" => project_name,
      "path" => project_path,
      "hive_state_path" => File.join(project_path, ".hive-state"),
      "tasks" => [ { "slug" => "stranded-task", "stage" => "2-draft-copy", "workflow" => "missing" } ]
    )

    band = Board.new([ project ]).bands.sole

    assert_equal "workflow_unavailable", band.error
    assert_equal "Workflow unavailable. Observed task stages remain visible.", band.availability_message
    assert_equal [ "stranded-task" ], band.columns.sole.tasks.map(&:slug)
    assert_equal "Draft Copy", band.columns.sole.label
  end

  test "marks a degraded empty project instead of presenting a healthy pipeline" do
    project_name = create_hive_project!("kanban-degraded-app")
    project_path = File.join(ENV.fetch("HIVE_TEST_HOME_ROOT"), "repos", project_name)
    project = Project.new(
      "name" => project_name,
      "path" => project_path,
      "hive_state_path" => File.join(project_path, ".hive-state"),
      "error" => "project_load_failed",
      "tasks" => []
    )

    band = Board.new([ project ]).bands.sole

    assert_equal "project_load_failed", band.error
    assert_equal "Project status unavailable: project load failed.", band.availability_message
  end

  test "loads each healthy project config once while building the board" do
    project_name = create_hive_project!("kanban-config-load-app")
    project_path = File.join(ENV.fetch("HIVE_TEST_HOME_ROOT"), "repos", project_name)
    project = Project.new(
      "name" => project_name,
      "path" => project_path,
      "hive_state_path" => File.join(project_path, ".hive-state"),
      "tasks" => []
    )
    original_load = Hive::Config.method(:load)
    calls = 0
    Hive::Config.define_singleton_method(:load) do |path|
      calls += 1 if File.expand_path(path) == project_path
      original_load.call(path)
    end

    Board.new([ project ])

    assert_equal 1, calls
  ensure
    Hive::Config.define_singleton_method(:load, original_load) if original_load
  end

  test "uses a project-authored default workflow for empty and active bands" do
    project_name = create_hive_project!("kanban-custom-workflow-app")
    project_path = File.join(ENV.fetch("HIVE_TEST_HOME_ROOT"), "repos", project_name)
    write_project_workflow(project_path, "custom-board", stage_name: "quality-gate")
    config_path = File.join(project_path, ".hive-state", "config.yml")
    config = YAML.safe_load_file(config_path) || {}
    config["default_workflow"] = "custom-board"
    File.write(config_path, config.to_yaml)
    Hive::Workflows::Project.reset!

    attributes = {
      "name" => project_name,
      "path" => project_path,
      "hive_state_path" => File.join(project_path, ".hive-state")
    }
    empty_band = Board.new([ Project.new(attributes.merge("tasks" => [])) ]).bands.sole
    task_band = Board.new([
      Project.new(attributes.merge(
        "tasks" => [ { "slug" => "custom-task", "stage" => "2-quality-gate", "workflow" => "custom-board" } ]
      ))
    ]).bands.sole

    assert_equal "custom-board", empty_band.workflow_id
    assert_equal %w[1-inbox 2-quality-gate 3-done], empty_band.columns.map(&:stage)
    assert_nil empty_band.error
    assert_equal [ "custom-task" ], task_band.columns.fetch(1).tasks.map(&:slug)
    assert_nil task_band.error
  ensure
    Hive::Workflows::Project.reset!
  end

  private

  def write_project_workflow(project_root, id, stage_name:)
    workflows_dir = File.join(project_root, ".hive-state", "workflows")
    instruction_dir = File.join(workflows_dir, id)
    FileUtils.mkdir_p(instruction_dir)
    File.write(File.join(instruction_dir, "#{stage_name}.md"), "Do #{stage_name}.\n")
    File.write(File.join(workflows_dir, "#{id}.yml"), <<~YAML)
      id: #{id}
      stages:
        - name: inbox
          kind: terminal
          state_file: idea.md
        - name: #{stage_name}
          kind: agent
          state_file: #{stage_name}.md
          instruction: ./#{id}/#{stage_name}.md
        - name: done
          kind: terminal
          state_file: done.md
    YAML
  end
end
