require "test_helper"
require "hive/commands/status"
require "hive/task"
require "hive/workflow_selection"
require "hive/workflows/project"

class WorkflowsProjectTest < Minitest::Test
  include HiveTestHelper

  def setup
    super
    Hive::Workflows::Project.reset!
  end

  def teardown
    Hive::Workflows::Project.reset!
    super
  end

  def test_load_registers_project_descriptor_and_resets_union
    with_tmp_dir do |project_root|
      write_project_workflow(project_root, "my-flow")

      Hive::Workflows::Project.load!(project_root)

      assert_equal :"my-flow", Hive::Workflows::Registry.fetch(:"my-flow").id
      assert_includes Hive::Workflows::Registry.ids, :"my-flow"
      assert_includes Hive::Workflows.all_stage_dirs, "2-work"
    end
  end

  def test_project_load_is_memoized_per_root
    with_tmp_dir do |project_root|
      workflows_dir = File.join(project_root, ".hive-state", "workflows")
      calls = 0
      descriptor = project_descriptor("memo-flow")

      with_replaced_singleton_method(Hive::Workflows::Loader, :workflow_dir, ->(_root) { workflows_dir }) do
        with_replaced_singleton_method(Hive::Workflows::Loader, :load_dir, lambda { |_dir|
          calls += 1
          { descriptor.id => descriptor }
        }) do
          Hive::Workflows::Project.load!(project_root)
          Hive::Workflows::Project.load!(project_root)
        end
      end

      assert_equal 1, calls
      assert_equal descriptor, Hive::Workflows::Registry.fetch(:"memo-flow")
    end
  end

  def test_loading_another_project_replaces_project_overlay_without_reparsing
    with_tmp_dir do |root_a|
      with_tmp_dir do |root_b|
        write_project_workflow(root_a, "flow-a", stage_name: "alpha")
        write_project_workflow(root_b, "flow-b", stage_name: "beta")

        Hive::Workflows::Project.load!(root_a)
        assert_includes Hive::Workflows::Registry.ids, :"flow-a"
        refute_includes Hive::Workflows::Registry.ids, :"flow-b"
        assert_includes Hive::Workflows.all_stage_names, "alpha"

        Hive::Workflows::Project.load!(root_b)
        assert_includes Hive::Workflows::Registry.ids, :"flow-b"
        refute_includes Hive::Workflows::Registry.ids, :"flow-a"
        assert_includes Hive::Workflows.all_stage_names, "beta"
        refute_includes Hive::Workflows.all_stage_names, "alpha"

        Hive::Workflows::Project.load!(root_a)
        assert_includes Hive::Workflows::Registry.ids, :"flow-a"
        refute_includes Hive::Workflows::Registry.ids, :"flow-b"
      end
    end
  end

  def test_builtin_id_collision_is_reported_with_descriptor_path
    with_tmp_dir do |project_root|
      path = write_project_workflow(project_root, "coding")

      error = assert_raises(Hive::ConfigError) { Hive::Workflows::Project.load!(project_root) }

      assert_includes error.message, path
      assert_includes error.message, "collides with registered workflow :coding"
    end
  end

  def test_load_tolerates_broken_project_config_for_task_fallback_paths
    with_tmp_dir do |project_root|
      FileUtils.mkdir_p(File.join(project_root, ".hive-state"))
      File.write(File.join(project_root, ".hive-state", "config.yml"), "default_workflow: [\n")

      Hive::Workflows::Project.load!(project_root)

      assert_equal [ :coding, :content ], Hive::Workflows::Registry.ids
    end
  end

  def test_task_resolves_project_workflow_from_meta
    with_tmp_dir do |project_root|
      write_project_workflow(project_root, "my-flow")
      task_dir = File.join(project_root, ".hive-state", "stages", "2-work", "write-report-260621-abcd")
      FileUtils.mkdir_p(task_dir)
      Hive::TaskMeta.write(task_dir, id: 1, slug: File.basename(task_dir), display_name: nil, workflow: "my-flow")

      task = Hive::Task.new(task_dir)

      assert_equal :"my-flow", task.workflow.id
      assert_equal "work", task.stage_name
    end
  end

  def test_workflow_selection_loads_project_descriptors_and_reports_valid_names
    with_tmp_dir do |project_root|
      write_project_workflow(project_root, "my-flow")

      assert_equal :"my-flow", Hive::WorkflowSelection.fetch!("my-flow", project_root: project_root).id

      error = assert_raises(Hive::Workflows::UnknownWorkflow) do
        Hive::WorkflowSelection.fetch!("missing", project_root: project_root)
      end

      assert_includes error.valid, "my-flow"
      assert_includes error.message, "my-flow"
    end
  end

  def test_status_loads_project_descriptors_before_scanning_stage_union
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      write_project_workflow(project_root, "my-flow")
      task_dir = File.join(hive_state, "stages", "2-work", "status-task-260621-abcd")
      FileUtils.mkdir_p(task_dir)
      File.write(File.join(task_dir, "work.md"), "<!-- COMPLETE -->\n")
      Hive::TaskMeta.write(task_dir, id: 2, slug: File.basename(task_dir), display_name: nil, workflow: "my-flow")

      payload = Hive::Commands::Status.new.json_payload([
        { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
      ])

      tasks = payload.fetch("projects").first.fetch("tasks")
      task = tasks.find { |candidate| candidate.fetch("slug") == "status-task-260621-abcd" }
      refute_nil task
      assert_equal "my-flow", task.fetch("workflow")
      assert_equal "2-work", task.fetch("stage")
    end
  end

  private

    def write_project_workflow(project_root, id, stage_name: "work")
      workflows_dir = File.join(project_root, ".hive-state", "workflows")
      instruction_dir = File.join(workflows_dir, id)
      FileUtils.mkdir_p(instruction_dir)
      File.write(File.join(instruction_dir, "#{stage_name}.md"), "Do #{stage_name}.\n")
      path = File.join(workflows_dir, "#{id}.yml")
      File.write(path, <<~YAML)
        id: #{id}
        stages:
          - name: inbox
            kind: terminal
            state_file: idea.md
          - name: #{stage_name}
            kind: agent
            state_file: #{stage_name}.md
            instruction: ./#{id}/#{stage_name}.md
      YAML
      path
    end

    def project_descriptor(id)
      Hive::Workflow.new(
        id: id.to_sym,
        stages: [
          Hive::Workflow::Stage.new(name: "inbox", index: 1, state_file: "idea.md", kind: :inert),
          Hive::Workflow::Stage.new(
            name: "work",
            index: 2,
            state_file: "work.md",
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: "work"),
            kind: :agent,
            instruction: "/tmp/work.md"
          )
        ]
      )
    end
end
