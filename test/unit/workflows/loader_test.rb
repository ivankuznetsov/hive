require "test_helper"
require "hive/workflows/loader"

class WorkflowsLoaderTest < Minitest::Test
  include HiveTestHelper

  # Production resolves through `Project.load! → load_dir(workflow_dir(...))`;
  # the dead `Loader.load` one-shot was removed, so these exercise the same
  # two-step resolution the production path uses.
  def test_load_dir_returns_empty_hash_when_project_has_no_workflow_directory
    with_tmp_dir do |project_root|
      dir = Hive::Workflows::Loader.workflow_dir(project_root)
      assert_equal({}, Hive::Workflows::Loader.load_dir(dir))
    end
  end

  def test_workflow_dir_uses_project_hive_state_path
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

      dir = Hive::Workflows::Loader.workflow_dir(project_root)
      assert_equal workflows_dir, dir
      workflows = Hive::Workflows::Loader.load_dir(dir)

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
      assert_includes err, "hive: skipping",
                      "the skip breadcrumb must name the 'hive: skipping …' contract, not just the path"
      assert_includes err, "not valid YAML",
                      "the skip breadcrumb must carry the underlying parse reason"
    end
  end

  # A parseable-but-semantically-invalid sibling (here: an id/filename mismatch)
  # routes through DescriptorParser → ConfigError, not the Psych rescue — the
  # more realistic authoring mistake than a raw YAML syntax error. It must still
  # be isolated: the good descriptor loads, the invalid one is skipped with its
  # ConfigError reason on stderr.
  def test_load_dir_skips_parseable_but_invalid_descriptor_and_reports_reason
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
      # id "mismatch" does not equal filename "zz-mismatch" → ConfigError.
      mismatch = File.join(workflows_dir, "zz-mismatch.yml")
      File.write(mismatch, <<~YAML)
        id: mismatch
        stages:
          - name: inbox
            kind: terminal
            state_file: idea.md
      YAML

      workflows = nil
      _out, err = capture_io { workflows = Hive::Workflows::Loader.load_dir(workflows_dir) }

      assert_equal [ :good ], workflows.keys,
                   "the good descriptor must still load when a parseable sibling is semantically invalid"
      assert_includes err, mismatch,
                      "the semantically-invalid descriptor must be reported with its path"
      assert_includes err, "must match filename",
                      "the skip breadcrumb must carry the ConfigError reason (id/filename mismatch)"
    end
  end
end
