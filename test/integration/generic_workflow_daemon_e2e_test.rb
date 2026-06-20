require "test_helper"
require "json"
require "hive/cli"
require "hive/commands/init"
require "hive/commands/new"
require "hive/daemon/policy"
require "hive/stages/base"
require "hive/task_meta"

class GenericWorkflowDaemonE2ETest < Minitest::Test
  include HiveTestHelper

  SLUG = "generic-daemon-260620-abcd"

  def test_generic_task_advances_two_stages_through_status_policy_and_cli
    descriptor = dispatch_workflow

    with_registered_workflow(descriptor) do
      with_tmp_global_config do
        with_tmp_git_repo do |project_root|
          project = File.basename(project_root)
          capture_io { Hive::Commands::Init.new(project_root).call }
          seed_generic_task(project_root, descriptor)
          coding_slug = seed_coding_task(project)

          first = status_row(SLUG)
          assert_equal "1-intake", first.fetch("stage")
          assert_equal "dispatch", first.fetch("workflow")
          assert_equal "ready_to_run", first.fetch("action")
          assert_equal "hive run #{SLUG}", first.fetch("suggested_command")
          assert_equal :dispatch, policy_decision(first)

          coding = status_row(coding_slug)
          assert_equal "coding", coding.fetch("workflow")
          assert_equal "ready_to_brainstorm", coding.fetch("action")
          assert_equal :dispatch, policy_decision(coding)

          ran = []
          with_stubbed_generic_agent(ran) do
            capture_io { Hive::CLI.start([ "run", SLUG, "--project", project ]) }

            after_intake_run = status_row(SLUG)
            assert_equal "ready_to_advance", after_intake_run.fetch("action")
            assert_equal "hive approve #{SLUG} --from 1-intake", after_intake_run.fetch("suggested_command")
            assert_equal :dispatch, policy_decision(after_intake_run)

            capture_io { Hive::CLI.start([ "approve", SLUG, "--project", project, "--from", "1-intake" ]) }
            assert File.directory?(stage_folder(project_root, "2-gather"))
            refute File.exist?(stage_folder(project_root, "1-intake"))

            gather = status_row(SLUG)
            assert_equal "2-gather", gather.fetch("stage")
            assert_equal "ready_to_run", gather.fetch("action")
            assert_equal :dispatch, policy_decision(gather)

            capture_io { Hive::CLI.start([ "run", SLUG, "--project", project ]) }
            after_gather_run = status_row(SLUG)
            assert_equal "ready_to_advance", after_gather_run.fetch("action")
            assert_equal "hive approve #{SLUG} --from 2-gather", after_gather_run.fetch("suggested_command")

            capture_io { Hive::CLI.start([ "approve", SLUG, "--project", project, "--from", "2-gather" ]) }
          end

          assert_equal %w[intake gather], ran
          assert File.directory?(stage_folder(project_root, "3-report"))
          refute File.exist?(stage_folder(project_root, "2-gather"))
        end
      end
    end
  end

  private

  def seed_generic_task(project_root, descriptor)
    stage = descriptor.stage_named("intake")
    folder = stage_folder(project_root, stage.dir)
    FileUtils.mkdir_p(folder)
    Hive::TaskMeta.write(folder, id: 101, slug: SLUG, display_name: "Generic Daemon", workflow: descriptor.id.to_s)
  end

  def seed_coding_task(project)
    capture_io { Hive::Commands::New.new(project, "coding parity row").call }
    folder = Dir[File.join(Hive::Config.find_project(project).fetch("hive_state_path"), "stages", "1-inbox", "coding-parity-row-*")].first
    File.basename(folder)
  end

  def stage_folder(project_root, stage_dir)
    File.join(project_root, ".hive-state", "stages", stage_dir, SLUG)
  end

  def status_row(slug)
    out, = capture_io { Hive::CLI.start([ "status", "--json" ]) }
    payload = JSON.parse(out)
    payload.fetch("projects").flat_map { |project| project.fetch("tasks") }.find { |task| task.fetch("slug") == slug } ||
      flunk("missing status row for #{slug}")
  end

  def policy_decision(row)
    Hive::Daemon::Policy.decide(
      action: row.fetch("action"),
      stage: row.fetch("stage"),
      workflow: row.fetch("workflow"),
      command: row.fetch("suggested_command"),
      state_file_mtime: Time.parse(row.fetch("mtime")),
      last_dispatched_state_file_mtime: nil,
      now: Time.now
    )
  end

  def with_stubbed_generic_agent(ran)
    original = Hive::Stages::Base.method(:spawn_agent)
    Hive::Stages::Base.define_singleton_method(:spawn_agent) do |task, **_kwargs|
      ran << task.stage_name
      File.write(task.state_file, "# #{task.stage_name}\n<!-- COMPLETE -->\n")
      { status: :complete }
    end
    yield
  ensure
    Hive::Stages::Base.define_singleton_method(:spawn_agent, original) if original
  end
end
