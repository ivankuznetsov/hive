require "test_helper"
require "json"
require "open3"
require "hive/config"
require "hive/git_ops"
require "hive/task"
require "hive/task_meta"

class DropCommandIntegrationTest < Minitest::Test
  include HiveTestHelper

  HIVE_BIN = File.expand_path("../../bin/hive", __dir__)

  def with_cli_project
    with_tmp_global_config do |home|
      with_tmp_git_repo do |dir|
        ops = Hive::GitOps.new(dir)
        ops.hive_state_init
        Hive::Config.register_project(name: File.basename(dir), path: dir)
        yield(home, dir, File.basename(dir))
      end
    end
  end

  def with_two_cli_projects
    with_tmp_global_config do |home|
      with_tmp_git_repo do |dir1|
        with_tmp_git_repo do |dir2|
          Hive::GitOps.new(dir1).hive_state_init
          Hive::GitOps.new(dir2).hive_state_init
          project1 = "project-one"
          project2 = "project-two"
          Hive::Config.register_project(name: project1, path: dir1)
          Hive::Config.register_project(name: project2, path: dir2)
          yield(home, dir1, project1, dir2, project2)
        end
      end
    end
  end

  def create_task(dir, stage, slug)
    folder = File.join(dir, ".hive-state", "stages", stage, slug)
    FileUtils.mkdir_p(folder)
    state_name = Hive::Task::STATE_FILES.fetch(stage.split("-", 2).last)
    File.write(File.join(folder, state_name), "# #{slug}\n<!-- WAITING -->\n")
    folder
  end

  def create_task_with_id(dir, stage, slug, id)
    folder = create_task(dir, stage, slug)
    Hive::TaskMeta.write(folder, id: id, slug: slug, display_name: nil)
    folder
  end

  def run_hive(home, *args)
    Open3.capture3({ "HIVE_HOME" => home }, HIVE_BIN, *args)
  end

  def test_bin_hive_drop_removes_multi_stage_slug_and_emits_json
    with_cli_project do |home, dir, project|
      slug = "cli-drop-260522-aaaa"
      folder2 = create_task(dir, "2-brainstorm", slug)
      folder3 = create_task(dir, "3-plan", slug)

      out, err, status = run_hive(home, "drop", slug, "--project", project, "--json")

      assert status.success?, err
      payload = JSON.parse(out)
      assert_equal "hive-drop", payload["schema"]
      assert_equal [ "2-brainstorm", "3-plan" ], payload["from_stages"]
      refute File.directory?(folder2)
      refute File.directory?(folder3)
    end
  end

  def test_bin_hive_drop_unknown_slug_exits_usage_with_error_envelope
    with_cli_project do |home, _dir, project|
      out, _err, status = run_hive(home, "drop", "missing-260522-aaaa", "--project", project, "--json")

      refute status.success?
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      payload = JSON.parse(out)
      assert_equal "invalid_task_path", payload["error_kind"]
    end
  end

  def test_bin_hive_drop_archived_slug_exits_usage
    with_cli_project do |home, dir, project|
      slug = "done-260522-aaaa"
      folder = create_task(dir, "9-done", slug)

      out, _err, status = run_hive(home, "drop", slug, "--project", project, "--json")

      refute status.success?
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      assert_equal "already_archived", JSON.parse(out)["error_kind"]
      assert File.directory?(folder)
    end
  end

  def test_bin_hive_drop_numeric_id_removes_task_and_emits_json
    with_cli_project do |home, dir, project|
      slug = "id-drop-260622-aaaa"
      folder = create_task_with_id(dir, "2-brainstorm", slug, 7448)

      out, err, status = run_hive(home, "drop", "7448", "--project", project, "--json")

      assert status.success?, err
      payload = JSON.parse(out)
      assert_equal "hive-drop", payload["schema"]
      assert_equal slug, payload["slug"]
      assert_equal [ "2-brainstorm" ], payload["from_stages"]
      refute File.directory?(folder)
    end
  end

  def test_bin_hive_drop_unknown_numeric_id_exits_usage_with_error_envelope
    with_cli_project do |home, _dir, project|
      out, _err, status = run_hive(home, "drop", "9999", "--project", project, "--json")

      refute status.success?
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      payload = JSON.parse(out)
      assert_equal "invalid_task_path", payload["error_kind"]
      assert_includes payload["message"], "no task folder for id 9999"
    end
  end

  def test_bin_hive_drop_duplicate_numeric_id_requires_project_and_then_drops_selected_project
    with_two_cli_projects do |home, dir1, project1, dir2, _project2|
      slug1 = "duplicate-id-one-260622-aaaa"
      slug2 = "duplicate-id-two-260622-aaaa"
      folder1 = create_task_with_id(dir1, "2-brainstorm", slug1, 7448)
      folder2 = create_task_with_id(dir2, "2-brainstorm", slug2, 7448)

      out, _err, status = run_hive(home, "drop", "7448", "--json")

      refute status.success?
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      payload = JSON.parse(out)
      assert_equal "ambiguous_slug", payload["error_kind"]
      assert_includes payload["message"], "task id 7448 is duplicated"
      assert File.directory?(folder1)
      assert File.directory?(folder2)

      out, err, status = run_hive(home, "drop", "7448", "--project", project1, "--json")

      assert status.success?, err
      payload = JSON.parse(out)
      assert_equal slug1, payload["slug"]
      assert_equal project1, payload["project"]
      refute File.directory?(folder1)
      assert File.directory?(folder2)
    end
  end
end
