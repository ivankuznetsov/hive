require "test_helper"
require "hive/commands/approve"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/run"
require "hive/commands/workflow"
require "hive/task_meta"
require "hive/workflow_selection"
require "hive/workflows/project"

class UserWorkflowE2ETest < Minitest::Test
  include HiveTestHelper

  def setup
    super
    Hive::Workflows::Project.reset!
  end

  def teardown
    Hive::Workflows::Project.reset!
    super
  end

  def test_scaffolded_workflow_runs_from_new_task_to_done
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        project = File.basename(project_root)
        capture_io { Hive::Commands::Init.new(project_root).call }

        refute_includes Hive::WorkflowSelection.valid_names(project_root: project_root), "my-flow"
        capture_io { Hive::Commands::Workflow.new!("my-flow", project_root: project_root) }

        capture_io { Hive::Commands::New.new(project, "custom workflow task", workflow: "my-flow").call }
        inbox = task_folder(project_root, "1-inbox")
        assert File.directory?(inbox)
        assert_equal "my-flow", Hive::TaskMeta.read(inbox)[:workflow]
        assert_includes File.read(File.join(inbox, "idea.md")), "<!-- COMPLETE -->"

        capture_io { Hive::Commands::Approve.new(File.basename(inbox), project: project, from: "1-inbox").call }
        work = task_folder(project_root, "2-work")
        assert File.directory?(work)
        refute File.directory?(inbox)

        ran = []
        with_deterministic_content_agent(record: ran) do
          capture_io { Hive::Commands::Run.new(File.basename(work), project: project).call }
        end

        assert_equal [ "work" ], ran
        assert File.file?(File.join(work, "work.md"))
        assert_includes File.read(File.join(work, "work.md")), "<!-- COMPLETE -->"

        capture_io { Hive::Commands::Approve.new(File.basename(work), project: project, from: "2-work").call }
        done = task_folder(project_root, "3-done")
        assert File.directory?(done)
        assert File.file?(File.join(done, "idea.md"))
        assert File.file?(File.join(done, "work.md"))
        assert_equal "my-flow", Hive::TaskMeta.read(done)[:workflow]

        capture_io { Hive::Commands::New.new(project, "coding path still works").call }
        coding_inbox = task_folder(project_root, "1-inbox")
        assert File.directory?(coding_inbox)
        assert_nil Hive::TaskMeta.read(coding_inbox)[:workflow]
        assert_includes File.read(File.join(coding_inbox, "idea.md")), "<!-- WAITING -->"
      end
    end
  end

  private

    def task_folder(project_root, stage)
      matches = Dir[File.join(project_root, ".hive-state", "stages", stage, "*")]
      assert_equal 1, matches.size, "expected one task in #{stage}, got #{matches.inspect}"
      matches.first
    end
end
