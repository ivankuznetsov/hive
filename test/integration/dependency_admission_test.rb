require "test_helper"
require "hive/commands/status"
require "hive/repository_identity"
require "hive/task_meta"

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

  private

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
