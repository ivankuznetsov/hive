require "test_helper"
require "hive/commands/approve"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/run"
require "hive/commands/workflow"
require "hive/stages/base"
require "hive/task_meta"
require "hive/workflows/project"

class ArchitectureWorkflowE2ETest < Minitest::Test
  include HiveTestHelper

  IDEA = "Design a native custom workflow system for architecture planning"

  def setup
    super
    Hive::Workflows::Project.reset!
  end

  def teardown
    Hive::Workflows::Project.reset!
    super
  end

  def test_architecture_template_runs_to_agent_terminal_deliverable
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        project = File.basename(project_root)
        capture_io { Hive::Commands::Init.new(project_root).call }
        capture_io { Hive::Commands::Workflow.new!("architecture", project_root: project_root, template: "architecture") }

        descriptor_path = File.join(project_root, ".hive-state", "workflows", "architecture.yml")
        descriptor = File.read(descriptor_path)
        assert_match(/kind:\s+council/, descriptor)
        refute_match(/name:\s+done/, descriptor)

        Hive::Workflows::Project.reset!
        capture_io { Hive::Commands::New.new(project, IDEA, workflow: "architecture").call }
        inbox = task_folder(project_root, "1-inbox")
        assert_equal "architecture", Hive::TaskMeta.read(inbox)[:workflow]
        assert_includes File.read(File.join(inbox, "idea.md")), IDEA
        assert_includes File.read(File.join(inbox, "idea.md")), "<!-- COMPLETE -->"

        slug = File.basename(inbox)
        Hive::Workflows::Project.reset!
        capture_io { Hive::Commands::Approve.new(slug, project: project, from: "1-inbox").call }

        ran = []
        Hive::Workflows::Project.reset!
        with_architecture_agents(ran) do
          draft = task_folder(project_root, "2-draft")
          capture_io { Hive::Commands::Run.new(slug, project: project).call }
          assert File.file?(File.join(draft, "draft.md"))

          Hive::Workflows::Project.reset!
          capture_io { Hive::Commands::Approve.new(slug, project: project, from: "2-draft").call }
          review = task_folder(project_root, "3-review")
          capture_io { Hive::Commands::Run.new(slug, project: project).call }
          assert File.file?(File.join(review, "reviews", "triage-01.md"))

          Hive::Workflows::Project.reset!
          capture_io { Hive::Commands::Approve.new(slug, project: project, from: "3-review").call }
          architecture = task_folder(project_root, "4-architecture")
          capture_io { Hive::Commands::Run.new(slug, project: project).call }
          assert File.file?(File.join(architecture, "architecture.md"))
          assert_includes File.read(File.join(architecture, "architecture.md")), "Final architecture"
        end

        assert_equal %w[draft review-claude-doc review-codex-doc architecture], ran
      end
    end
  end

  private

    def with_architecture_agents(ran)
      original = Hive::Stages::Base.method(:spawn_agent)
      Hive::Stages::Base.define_singleton_method(:spawn_agent) do |task, **kwargs|
        if kwargs[:expected_output]
          ran << kwargs.fetch(:log_label)
          FileUtils.mkdir_p(File.dirname(kwargs[:expected_output]))
          File.write(kwargs[:expected_output], "Verdict: ready\n\n## Findings\n- Looks good.\n")
          { status: :ok }
        else
          ran << task.stage_name
          body = if task.stage_name == "architecture"
            "# Final architecture\n\nReady for implementation.\n<!-- COMPLETE -->\n"
          else
            "# Architecture draft\n\nScoped enough for review.\n<!-- COMPLETE -->\n"
          end
          File.write(task.state_file, body)
          { status: :complete }
        end
      end
      yield
    ensure
      Hive::Stages::Base.define_singleton_method(:spawn_agent, original) if original
    end

    def task_folder(project_root, stage)
      matches = Dir[File.join(project_root, ".hive-state", "stages", stage, "*")]
      assert_equal 1, matches.size, "expected one task in #{stage}, got #{matches.inspect}"
      matches.first
    end
end
