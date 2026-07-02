require "test_helper"
require "json"
require "open3"
require "shellwords"
require "tmpdir"
require "hive/claude_launcher"
require "hive/stop_hook_installer"

class StopHookInstallerTest < Minitest::Test
  include HiveTestHelper

  HOOK = Hive::StopHookInstaller::HOOK_PATH

  def test_install_writes_expected_settings_shape
    with_tmp_dir do |dir|
      paths = Hive::StopHookInstaller.install(stage_dir: dir)
      assert_kind_of Array, paths
      assert_equal 1, paths.size
      path = paths.first
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
      first_body = File.read(first.first)
      second = Hive::StopHookInstaller.install(stage_dir: dir)

      assert_equal first, second
      assert_equal first_body, File.read(second.first)
    end
  end

  def test_install_marks_settings_read_only
    with_tmp_dir do |dir|
      path = Hive::StopHookInstaller.install(stage_dir: dir).first

      assert_equal 0o444, File.stat(path).mode & 0o777,
                   "settings.json must be read-only so a prompt-injected " \
                   "brainstorm cannot overwrite the Stop hook command"
      assert_raises(Errno::EACCES) { File.write(path, "tampered") }
    end
  end

  def test_install_writes_to_extra_dirs
    with_tmp_dir do |dir|
      Dir.mktmpdir do |extra|
        paths = Hive::StopHookInstaller.install(stage_dir: dir, extra_dirs: [ extra ])

        assert_equal 2, paths.size,
                     "extra cwd should receive its own .claude/settings.json so Claude " \
                     "discovers the Stop hook regardless of launch cwd"
        assert paths.all? { |p| File.exist?(p) }
        # Both copies point at the orchestrator-owned stage_dir for
        # HIVE_TASK_STAGE_DIR — the second file is just a discovery
        # surface, not a separate state directory.
        paths.each do |path|
          data = JSON.parse(File.read(path))
          command = data.fetch("hooks").fetch("Stop").first.fetch("hooks").first.fetch("command")
          assert_includes command, "HIVE_TASK_STAGE_DIR=#{Shellwords.escape(dir)}"
        end
      end
    end
  end

  def test_installed_hook_paths_match_claude_launcher_signal_contract
    with_tmp_dir do |stage_dir|
      Dir.mktmpdir do |worktree_dir|
        task = Struct.new(:folder).new(stage_dir)
        paths = Hive::StopHookInstaller.install(stage_dir: stage_dir, extra_dirs: [ worktree_dir ])

        assert_equal File.join(stage_dir, ".done"), Hive::ClaudeLauncher.done_path(task)
        assert_equal File.join(stage_dir, "result.json"), Hive::ClaudeLauncher.result_path(task)
        assert_equal(
          [
            File.join(stage_dir, ".claude", "settings.json"),
            File.join(worktree_dir, ".claude", "settings.json")
          ].sort,
          paths.sort
        )

        paths.each do |settings_path|
          data = JSON.parse(File.read(settings_path))
          command = data.fetch("hooks").fetch("Stop").first.fetch("hooks").first.fetch("command")

          assert_includes command, "HIVE_TASK_STAGE_DIR=#{Shellwords.escape(stage_dir)}"
          assert_includes command, Shellwords.escape(HOOK)
          refute_includes command, "HIVE_TASK_STAGE_DIR=#{Shellwords.escape(worktree_dir)}"
        end

        script = File.read(HOOK)
        assert_includes script, 'result_path="${HIVE_TASK_STAGE_DIR}/result.json"'
        assert_includes script, 'touch "${HIVE_TASK_STAGE_DIR}/.done"'
      end
    end
  end

  def test_install_skips_extra_dir_equal_to_stage_dir
    with_tmp_dir do |dir|
      paths = Hive::StopHookInstaller.install(stage_dir: dir, extra_dirs: [ dir ])
      assert_equal 1, paths.size, "extra_dirs equal to stage_dir must not double-write"
    end
  end

  def test_install_backs_up_existing_project_owned_settings
    with_tmp_dir do |dir|
      claude_dir = File.join(dir, ".claude")
      FileUtils.mkdir_p(claude_dir)
      project_settings = File.join(claude_dir, "settings.json")
      project_body = %({"enabledPlugins":{"frontend-design@official":true}})
      File.write(project_settings, project_body)

      Hive::StopHookInstaller.install(stage_dir: dir)

      backup_path = "#{project_settings}#{Hive::StopHookInstaller::BACKUP_SUFFIX}"
      assert File.exist?(backup_path),
             "a pre-existing project-owned .claude/settings.json must be backed up before overwrite"
      assert_equal project_body, File.read(backup_path),
                   "the backup must hold the project's original content verbatim"
    end
  end

  def test_install_skips_backup_when_no_existing_settings_present
    with_tmp_dir do |dir|
      Hive::StopHookInstaller.install(stage_dir: dir)

      backup_path = File.join(dir, ".claude", "settings.json#{Hive::StopHookInstaller::BACKUP_SUFFIX}")
      refute File.exist?(backup_path),
             "no backup must be written when nothing existed to overwrite (the scratch case)"
    end
  end

  def test_install_does_not_overwrite_existing_backup
    with_tmp_dir do |dir|
      claude_dir = File.join(dir, ".claude")
      FileUtils.mkdir_p(claude_dir)
      project_settings = File.join(claude_dir, "settings.json")
      project_body = %({"original":"project-owned"})
      File.write(project_settings, project_body)

      # First install backs up the project file. Second install runs
      # against the hive-installed stub; if it re-backed up, the stub
      # would clobber the original. The invariant: backup is captured
      # once per install/cleanup pair and never re-captured mid-pair.
      Hive::StopHookInstaller.install(stage_dir: dir)
      Hive::StopHookInstaller.install(stage_dir: dir)

      backup_path = "#{project_settings}#{Hive::StopHookInstaller::BACKUP_SUFFIX}"
      assert_equal project_body, File.read(backup_path),
                   "second install must NOT overwrite the existing backup with the hive stub"
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
    # Scrub HIVE_TASK_STAGE_DIR from the child env so the test is hermetic even
    # when the surrounding shell exports it (e.g. under the review harness);
    # otherwise the hook inherits the value and never reaches its required-env
    # error path. A nil env value unsets the var for the child process.
    _out, err, status = Open3.capture3({ "HIVE_TASK_STAGE_DIR" => nil }, HOOK, stdin_data: "{}")

    refute status.success?
    assert_match(/HIVE_TASK_STAGE_DIR required/, err)
  end

  def test_stop_hook_syntax
    assert system("sh", "-n", HOOK)
  end
end
