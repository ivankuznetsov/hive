require "test_helper"
require "hive/commands/status"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/run"
require "hive/commands/approve"
require "hive/commands/stage_action"
require "hive/repository_identity"
require "hive/task_meta"
require "json_schemer"

class DependencyAdmissionIntegrationTest < Minitest::Test
  include HiveTestHelper

  def test_cross_project_live_repository_mismatch_holds_status_row
    with_tmp_dir do |root|
      app = File.join(root, "app")
      data = File.join(root, "data")
      expected_remote = File.join(root, "expected-data.git")
      wrong_remote = File.join(root, "wrong-data.git")
      [ app, data, expected_remote, wrong_remote ].each { |path| FileUtils.mkdir_p(path) }
      run!("git", "-C", app, "init", "--quiet")
      run!("git", "-C", data, "init", "--quiet")
      run!("git", "-C", data, "remote", "add", "origin", wrong_remote)

      dependent = write_task(app, "4-execute", "dependent-task", "task.md", "EXECUTE_COMPLETE")
      base = write_task(data, "8-finalize", "base-task", "pr.md", "COMPLETE")
      Hive::TaskMeta.write(dependent, id: 2, slug: "dependent-task", display_name: nil,
                                      depends_on: "data:base-task")
      Hive::TaskMeta.write(base, id: 1, slug: "base-task", display_name: nil)

      payload = Hive::Commands::Status.new.json_payload([
        project("app", app, repository_identity: nil),
        project("data", data, repository_identity: Hive::RepositoryIdentity.normalize(expected_remote))
      ])
      row = payload.fetch("projects").first.fetch("tasks").find { |task| task["slug"] == "dependent-task" }

      assert_equal true, row.fetch("blocked")
      assert_equal "admission_error", row.fetch("action")
      assert_nil row.fetch("suggested_command")
      assert_equal "dependency_repository_mismatch", row.fetch("admission_error").fetch("reason_code")
      assert_equal "data:base-task", row.fetch("admission_error").fetch("offending_ref")
    end
  end

  def test_plan_only_ordering_declaration_holds_status_row
    with_tmp_dir do |root|
      folder = write_task(root, "4-execute", "ordering-task", "task.md", "EXECUTE_COMPLETE")
      Hive::TaskMeta.write(folder, id: 2, slug: "ordering-task", display_name: nil)
      File.write(File.join(folder, "plan.md"), "---\ndepends_on: prerequisite-task\n---\n# Plan\n")

      payload = Hive::Commands::Status.new.json_payload([ project(File.basename(root), root) ])
      row = payload.fetch("projects").first.fetch("tasks").first

      assert_equal true, row.fetch("blocked")
      assert_equal "plan_dependency_missing", row.fetch("admission_error").fetch("reason_code")
    end
  end

  def test_manual_run_and_stage_action_revalidate_plan_only_dependency_before_runner
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        project_name = File.basename(dir)
        capture_io do
          Hive::Commands::New.new(project_name, "ordering task", slug_override: "ordering-task").call
        end
        inbox = File.join(dir, ".hive-state", "stages", "1-inbox", "ordering-task")
        execute = File.join(dir, ".hive-state", "stages", "4-execute", "ordering-task")
        FileUtils.mkdir_p(File.dirname(execute))
        FileUtils.mv(inbox, execute)
        File.write(File.join(execute, "task.md"), "# Task\n<!-- EXECUTE_COMPLETE -->\n")
        File.write(File.join(execute, "plan.md"), "---\ndepends_on: prerequisite-task\n---\n# Plan\n")

        rebase_called = false
        run = Hive::Commands::Run.new(execute, json: true)
        run.define_singleton_method(:perform_rebase) do |*|
          rebase_called = true
          raise "rebase must not run"
        end
        run_out, = capture_io do
          assert_raises(Hive::DependencyAdmissionError) { run.call }
        end
        run_payload = JSON.parse(run_out)

        assert_equal false, rebase_called
        assert_equal "admission_error", run_payload.fetch("error_kind")
        assert_equal "plan_dependency_missing", run_payload.fetch("reason_code")
        assert_equal Hive::ExitCodes::CONFIG, run_payload.fetch("exit_code")
        assert_schema_valid("hive-run", run_payload)

        action_out, = capture_io do
          assert_raises(Hive::DependencyAdmissionError) do
            Hive::Commands::StageAction.new("develop", execute, json: true).call
          end
        end
        action_payload = JSON.parse(action_out)
        assert_equal "admission_error", action_payload.fetch("error_kind")
        assert_equal "plan_dependency_missing", action_payload.fetch("reason_code")
        assert_schema_valid("hive-stage-action", action_payload)
        assert File.directory?(execute), "held task must not be moved"
      end
    end
  end

  def test_forward_approve_returns_retryable_wait_and_force_cannot_bypass_it
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        project_name = File.basename(dir)
        capture_io do
          Hive::Commands::New.new(project_name, "base task", slug_override: "base-task").call
          Hive::Commands::New.new(
            project_name,
            "dependent task",
            slug_override: "dependent-task",
            depends_on: "base-task"
          ).call
        end
        inbox = File.join(dir, ".hive-state", "stages", "1-inbox", "dependent-task")
        brainstorm = File.join(dir, ".hive-state", "stages", "2-brainstorm", "dependent-task")
        FileUtils.mkdir_p(File.dirname(brainstorm))
        FileUtils.mv(inbox, brainstorm)
        File.write(File.join(brainstorm, "brainstorm.md"), "# Done\n<!-- COMPLETE -->\n")
        head_before = run!("git", "-C", File.join(dir, ".hive-state"), "rev-parse", "HEAD").strip

        out, = capture_io do
          assert_raises(Hive::DependencyWaitError) do
            Hive::Commands::Approve.new(brainstorm, force: true, json: true).call
          end
        end
        payload = JSON.parse(out)

        assert_equal "dependency_wait", payload.fetch("error_kind")
        assert_equal "dependency_wait", payload.fetch("reason_code")
        assert_equal "base-task", payload.fetch("offending_ref")
        assert_equal Hive::ExitCodes::TEMPFAIL, payload.fetch("exit_code")
        assert_schema_valid("hive-approve", payload)
        assert File.directory?(brainstorm)
        refute File.exist?(File.join(dir, ".hive-state", "stages", "3-plan", "dependent-task"))
        assert_equal head_before,
                     run!("git", "-C", File.join(dir, ".hive-state"), "rev-parse", "HEAD").strip
      end
    end
  end

  def test_forward_approve_rejects_missing_dependency_but_backward_recovery_skips_admission
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        project_name = File.basename(dir)
        capture_io do
          Hive::Commands::New.new(
            project_name,
            "held task",
            slug_override: "held-task",
            depends_on: "missing-task"
          ).call
        end
        inbox = File.join(dir, ".hive-state", "stages", "1-inbox", "held-task")
        brainstorm = File.join(dir, ".hive-state", "stages", "2-brainstorm", "held-task")
        FileUtils.mkdir_p(File.dirname(brainstorm))
        FileUtils.mv(inbox, brainstorm)
        File.write(File.join(brainstorm, "brainstorm.md"), "# Done\n<!-- COMPLETE -->\n")

        out, = capture_io do
          assert_raises(Hive::DependencyAdmissionError) do
            Hive::Commands::Approve.new(brainstorm, force: true, json: true).call
          end
        end
        payload = JSON.parse(out)
        assert_equal "dependency_task_missing", payload.fetch("reason_code")
        assert File.directory?(brainstorm)

        execute = File.join(dir, ".hive-state", "stages", "4-execute", "held-task")
        FileUtils.mkdir_p(File.dirname(execute))
        FileUtils.mv(brainstorm, execute)
        File.write(File.join(execute, "meta.yml"), "depends_on: [broken\n")
        capture_io { Hive::Commands::Approve.new(execute, to: "3-plan").call }
        assert File.directory?(File.join(dir, ".hive-state", "stages", "3-plan", "held-task")),
               "backward recovery must remain possible with corrupt admission metadata"
      end
    end
  end

  def test_manual_run_rejects_cross_project_repository_mismatch
    with_tmp_global_config do
      with_tmp_dir do |root|
        app = File.join(root, "app")
        data = File.join(root, "data")
        expected = File.join(root, "expected-data.git")
        wrong = File.join(root, "wrong-data.git")
        [ app, data, expected, wrong ].each { |path| FileUtils.mkdir_p(path) }
        [ app, data ].each { |path| initialize_git_repo(path) }
        run!("git", "-C", data, "remote", "add", "origin", expected)
        capture_io do
          Hive::Commands::Init.new(app).call
          Hive::Commands::Init.new(data).call
          Hive::Commands::New.new("data", "base", slug_override: "base-task").call
          Hive::Commands::New.new(
            "app", "dependent", slug_override: "dependent-task", depends_on: "data:base-task"
          ).call
        end
        run!("git", "-C", data, "remote", "set-url", "origin", wrong)
        inbox = File.join(app, ".hive-state", "stages", "1-inbox", "dependent-task")
        execute = File.join(app, ".hive-state", "stages", "4-execute", "dependent-task")
        FileUtils.mkdir_p(File.dirname(execute))
        FileUtils.mv(inbox, execute)
        File.write(File.join(execute, "task.md"), "# Task\n")

        out, = capture_io do
          assert_raises(Hive::DependencyAdmissionError) do
            Hive::Commands::Run.new(execute, json: true).call
          end
        end
        payload = JSON.parse(out)
        assert_equal "dependency_repository_mismatch", payload.fetch("reason_code")
        assert_equal "data:base-task", payload.fetch("offending_ref")
        assert File.directory?(execute)
      end
    end
  end

  private

  def assert_schema_valid(name, payload)
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path(name))))
    errors = schemer.validate(payload).to_a
    assert_empty errors, "#{name} payload did not validate: #{errors.inspect}"
  end

  def initialize_git_repo(path)
    run!("git", "-C", path, "init", "-b", "master", "--quiet")
    run!("git", "-C", path, "config", "user.email", "test@example.com")
    run!("git", "-C", path, "config", "user.name", "Test")
    run!("git", "-C", path, "config", "commit.gpgsign", "false")
    File.write(File.join(path, "README.md"), "test\n")
    run!("git", "-C", path, "add", ".")
    run!("git", "-C", path, "commit", "-m", "initial", "--quiet")
  end

  def project(name, root, repository_identity: nil)
    {
      "name" => name,
      "path" => root,
      "hive_state_path" => File.join(root, ".hive-state"),
      "repository_identity" => repository_identity
    }
  end

  def write_task(root, stage, slug, state_file, marker)
    folder = File.join(root, ".hive-state", "stages", stage, slug)
    FileUtils.mkdir_p(folder)
    File.write(File.join(folder, state_file), "<!-- #{marker} -->\n")
    folder
  end
end
