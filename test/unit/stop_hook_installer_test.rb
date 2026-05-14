require "test_helper"
require "json"
require "open3"
require "shellwords"
require "hive/stop_hook_installer"

class StopHookInstallerTest < Minitest::Test
  include HiveTestHelper

  HOOK = Hive::StopHookInstaller::HOOK_PATH

  def test_install_writes_expected_settings_shape
    with_tmp_dir do |dir|
      path = Hive::StopHookInstaller.install(stage_dir: dir)
      data = JSON.parse(File.read(path))
      group = data.fetch("hooks").fetch("Stop").fetch(0)
      handler = group.fetch("hooks").fetch(0)

      assert_equal "command", handler.fetch("type")
      command = handler.fetch("command")
      assert_includes command, "HIVE_TASK_STAGE_DIR=#{Shellwords.escape(dir)}"
      assert_includes command, Shellwords.escape(HOOK)
    end
  end

  def test_install_is_idempotent
    with_tmp_dir do |dir|
      first = Hive::StopHookInstaller.install(stage_dir: dir)
      first_body = File.read(first)
      second = Hive::StopHookInstaller.install(stage_dir: dir)

      assert_equal first, second
      assert_equal first_body, File.read(second)
    end
  end

  def test_stop_hook_writes_result_json_and_done
    with_tmp_dir do |dir|
      payload = %({"session_id":"abc","transcript_path":"/tmp/transcript.jsonl"})
      out, err, status = Open3.capture3({ "HIVE_TASK_STAGE_DIR" => dir }, HOOK, stdin_data: payload)

      assert status.success?, "stdout=#{out.inspect} stderr=#{err.inspect}"
      assert_equal payload, File.read(File.join(dir, "result.json"))
      assert File.exist?(File.join(dir, ".done"))
    end
  end

  def test_stop_hook_requires_stage_dir_env
    _out, err, status = Open3.capture3(HOOK, stdin_data: "{}")

    refute status.success?
    assert_match(/HIVE_TASK_STAGE_DIR required/, err)
  end

  def test_stop_hook_syntax
    assert system("sh", "-n", HOOK)
  end
end
