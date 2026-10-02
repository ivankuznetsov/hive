require "test_helper"
require "hive/workflow_selection"

class WorkflowSelectionTest < Minitest::Test
  include HiveTestHelper

  def setup
    super
    Hive::Workflows::Project.reset!
  end

  def teardown
    Hive::Workflows::Project.reset!
    super
  end

  def test_fetch_returns_registered_workflow
    with_registered_workflow(content_workflow) do
      assert_equal :content_fixture, Hive::WorkflowSelection.fetch!("content_fixture").id
    end
  end

  def test_fetch_defaults_blank_to_coding
    assert_equal :coding, Hive::WorkflowSelection.fetch!("").id
    assert_equal :coding, Hive::WorkflowSelection.fetch!(nil).id
  end

  def test_fetch_unknown_lists_valid_names
    with_registered_workflow(content_workflow) do
      error = assert_raises(Hive::Workflows::UnknownWorkflow) do
        Hive::WorkflowSelection.fetch!("bogus")
      end

      assert_includes error.message, "unknown workflow \"bogus\""
      assert_includes error.message, "coding"
      assert_includes error.message, "content_fixture"
      assert_equal "bogus", error.value, "the user-supplied name must travel as a structured field"
      assert_includes error.valid, "content_fixture", "the valid-names list must travel as a structured field"
    end
  end

  def test_valid_names_reflect_registry
    with_registered_workflow(content_workflow) do
      assert_includes Hive::WorkflowSelection.valid_names, "content_fixture"
    end
  end

  def test_unknown_fetch_uses_one_project_activation_for_resolution_and_suggestions
    with_tmp_dir do |project_root|
      write_project_workflow(project_root, "project-flow")
      fingerprint_calls = 0
      original = Hive::Workflows::Loader.method(:fingerprint)

      error = with_replaced_singleton_method(
        Hive::Workflows::Loader, :fingerprint, lambda { |workflow_dir|
          fingerprint_calls += 1
          original.call(workflow_dir)
        }
      ) do
        assert_raises(Hive::Workflows::UnknownWorkflow) do
          Hive::WorkflowSelection.fetch!("missing", project_root: project_root)
        end
      end

      assert_equal 1, fingerprint_calls,
                   "resolution and its suggestions must come from one active project view"
      assert_includes error.valid, "project-flow"
      assert_includes error.message, "project-flow"
    end
  end

  def test_project_valid_names_reads_registry_while_the_project_view_is_active
    with_tmp_dir do |project_root|
      write_project_workflow(project_root, "project-flow")
      lock_states = []
      original = Hive::Workflows::Registry.method(:ids)

      names = with_replaced_singleton_method(
        Hive::Workflows::Registry, :ids, lambda {
          lock_states << Hive::Workflows::Project::LOCK.mon_owned?
          original.call
        }
      ) do
        Hive::WorkflowSelection.valid_names(project_root: project_root)
      end

      assert_includes names, "project-flow"
      assert_equal [ true ], lock_states
    end
  end

  def test_nil_project_valid_names_synchronizes_the_legacy_current_view
    lock_states = []
    original = Hive::Workflows::Registry.method(:ids)

    names = with_registered_workflow(content_workflow) do
      with_replaced_singleton_method(
        Hive::Workflows::Registry, :ids, lambda {
          lock_states << Hive::Workflows::Project::LOCK.mon_owned?
          original.call
        }
      ) do
        Hive::WorkflowSelection.valid_names
      end
    end

    assert_includes names, "content_fixture"
    assert_equal [ true ], lock_states
  end

  private

  def write_project_workflow(project_root, id)
    workflows_dir = File.join(project_root, ".hive-state", "workflows")
    instruction_dir = File.join(workflows_dir, id)
    FileUtils.mkdir_p(instruction_dir)
    File.write(File.join(instruction_dir, "work.md"), "Do work.\n")
    File.write(File.join(workflows_dir, "#{id}.yml"), <<~YAML)
      id: #{id}
      stages:
        - name: inbox
          kind: terminal
          state_file: idea.md
        - name: work
          kind: agent
          state_file: work.md
          instruction: ./#{id}/work.md
        - name: done
          kind: terminal
          state_file: done.md
    YAML
  end
end
