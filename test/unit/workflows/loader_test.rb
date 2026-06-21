require "test_helper"
require "hive/workflows/loader"

class WorkflowsLoaderTest < Minitest::Test
  include HiveTestHelper

  def test_load_returns_empty_hash_when_project_has_no_workflow_directory
    with_tmp_dir do |project_root|
      assert_equal({}, Hive::Workflows::Loader.load(project_root))
    end
  end

  def test_load_uses_project_hive_state_path
    with_tmp_dir do |project_root|
      workflows_dir = File.join(project_root, ".custom-state", "workflows")
      FileUtils.mkdir_p(File.join(workflows_dir, "my-flow"))
      FileUtils.mkdir_p(File.join(project_root, ".hive-state"))
      File.write(File.join(project_root, ".hive-state", "config.yml"), "hive_state_path: .custom-state\n")
      File.write(File.join(workflows_dir, "my-flow", "work.md"), "Do it.\n")
      File.write(File.join(workflows_dir, "my-flow.yml"), <<~YAML)
        id: my-flow
        stages:
          - name: inbox
            kind: terminal
            state_file: idea.md
          - name: work
            kind: agent
            state_file: work.md
            instruction: ./my-flow/work.md
      YAML

      workflows = Hive::Workflows::Loader.load(project_root)

      assert_equal [ :"my-flow" ], workflows.keys
      assert_equal "2-work", workflows.fetch(:"my-flow").stage_named("work").dir
    end
  end

  def test_load_dir_reports_broken_descriptor_path
    with_tmp_dir do |workflows_dir|
      FileUtils.mkdir_p(File.join(workflows_dir, "good"))
      File.write(File.join(workflows_dir, "good", "work.md"), "Do it.\n")
      File.write(File.join(workflows_dir, "good.yml"), <<~YAML)
        id: good
        stages:
          - name: inbox
            kind: terminal
            state_file: idea.md
          - name: work
            kind: agent
            state_file: work.md
            instruction: ./good/work.md
      YAML
      broken = File.join(workflows_dir, "zz-broken.yml")
      File.write(broken, "id: [\n")

      error = assert_raises(Hive::ConfigError) { Hive::Workflows::Loader.load_dir(workflows_dir) }

      assert_includes error.message, broken
    end
  end
end
