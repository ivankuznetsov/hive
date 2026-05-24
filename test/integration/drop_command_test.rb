require "test_helper"
require "json"
require "open3"
require "hive/config"
require "hive/git_ops"
require "hive/task"

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

  def create_task(dir, stage, slug)
    folder = File.join(dir, ".hive-state", "stages", stage, slug)
    FileUtils.mkdir_p(folder)
    state_name = Hive::Task::STATE_FILES.fetch(stage.split("-", 2).last)
    File.write(File.join(folder, state_name), "# #{slug}\n<!-- WAITING -->\n")
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
end
