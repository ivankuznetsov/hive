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
          - name: done
            kind: terminal
            state_file: done.md
      YAML

      workflows = Hive::Workflows::Loader.load(project_root)

      assert_equal [ :"my-flow" ], workflows.keys
      assert_equal "2-work", workflows.fetch(:"my-flow").stage_named("work").dir
    end
  end

  # Per-file isolation (plan U9-2): a single malformed descriptor must NOT abort
  # loading its siblings — the good one still loads, and the broken one is
  # reported (with its path) on stderr instead of raising and bricking every
  # task in the project.
  def test_load_dir_skips_broken_descriptor_and_reports_its_path
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
          - name: done
            kind: terminal
            state_file: done.md
      YAML
      broken = File.join(workflows_dir, "zz-broken.yml")
      File.write(broken, "id: [\n")

      workflows = nil
      _out, err = capture_io { workflows = Hive::Workflows::Loader.load_dir(workflows_dir) }

      assert_equal [ :good ], workflows.keys,
                   "the good descriptor must still load even when a sibling is malformed"
      assert_equal "2-work", workflows.fetch(:good).stage_named("work").dir
      assert_includes err, broken,
                      "the malformed descriptor must be reported with its path on stderr"
    end
  end
end
