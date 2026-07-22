require_relative "../../test_helper"
require "fileutils"
require "json"
require "tmpdir"
require_relative "artifact_capture"
require_relative "scenario"

class E2EArtifactCaptureTest < Minitest::Test
  def with_dirs
    Dir.mktmpdir("scenario") do |scenario_dir|
      Dir.mktmpdir("sandbox") do |sandbox|
        Dir.mktmpdir("home") do |run_home|
          yield(scenario_dir, sandbox, run_home)
        end
      end
    end
  end

  def make_step(kind, position: 1)
    Hive::E2E::Step.new(kind: kind, args: {}, description: "", position: position)
  end

  def collect(scenario_dir, sandbox, run_home, **overrides)
    error = overrides[:error] || RuntimeError.new("boom")
    failed_step = overrides[:failed_step] || make_step("cli")
    Hive::E2E::ArtifactCapture.new(scenario_dir: scenario_dir, sandbox_dir: sandbox, run_home: run_home,
                                   tui_log_dir: overrides[:tui_log_dir])
      .collect(error: error, failed_step: failed_step,
               step_results: overrides[:step_results] || [],
               tmux_driver: overrides[:tmux_driver],
               tmux_keystrokes: overrides[:tmux_keystrokes],
               pane_after: overrides[:pane_after],
               schema_diff: overrides[:schema_diff],
               pane_before: overrides[:pane_before])
  end

  def test_manifest_has_schema_version_and_empty_capture_errors_on_happy_path
    with_dirs do |scenario_dir, sandbox, run_home|
      collect(scenario_dir, sandbox, run_home)
      manifest = JSON.parse(File.read(File.join(scenario_dir, "manifest.json")))

      assert_equal "hive-e2e-manifest", manifest["schema"]
      assert_equal 1, manifest["schema_version"]
      assert_equal [], manifest["capture_errors"], "happy capture path should record no capture errors"
    end
  end

  def test_capture_failures_dont_mask_original_error
    with_dirs do |scenario_dir, sandbox, run_home|
      fake_tmux = Object.new
      fake_tmux.define_singleton_method(:keystrokes) do
        raise RuntimeError, "FORCED_CAPTURE_FAILURE"
      end
      fake_tmux.define_singleton_method(:capture_pane) { "PANE_TEXT\n" }
      original_error = RuntimeError.new("ORIGINAL_ERROR_TEXT")
      collect(scenario_dir, sandbox, run_home, error: original_error, tmux_driver: fake_tmux)

      exception_text = File.read(File.join(scenario_dir, "exception.txt"))
      assert_includes exception_text, "ORIGINAL_ERROR_TEXT",
        "original error must surface in exception.txt regardless of capture failures"

      manifest = JSON.parse(File.read(File.join(scenario_dir, "manifest.json")))
      capture_error = manifest.fetch("capture_errors").find do |entry|
        entry["label"] == "keystrokes.log"
      end
      assert capture_error, "manifest should record the guarded artifact writer failure"
      assert_includes capture_error.fetch("error"), "RuntimeError: FORCED_CAPTURE_FAILURE"
    end
  end

  def test_sandbox_tree_excludes_top_level_git_metadata
    with_dirs do |scenario_dir, sandbox, run_home|
      assert system("git", "-C", sandbox, "init", "-b", "master", "--quiet"),
        "expected git init fixture setup to succeed"
      File.write(File.join(sandbox, "visible.txt"), "visible\n")
      nested_git = File.join(sandbox, "vendor", "repo", ".git")
      FileUtils.mkdir_p(nested_git)
      File.write(File.join(nested_git, "config"), "secret metadata\n")

      collect(scenario_dir, sandbox, run_home)

      tree = File.read(File.join(scenario_dir, "sandbox-tree.txt"))
      assert_includes tree, "visible.txt\n"
      refute tree.lines.any? { |line| line == ".git\n" || line.start_with?(".git/") },
        "sandbox-tree.txt must not publish git metadata paths"
      refute tree.lines.any? { |line| line.chomp.split("/").include?(".git") },
        "sandbox-tree.txt must not publish nested git metadata paths"
    end
  end

  def test_log_tails_are_last_n_lines_per_log_file
    with_dirs do |scenario_dir, sandbox, run_home|
      logs_root = File.join(sandbox, ".hive-state", "logs", "myslug")
      FileUtils.mkdir_p(logs_root)
      log_path = File.join(logs_root, "stage.log")
      File.write(log_path, (1..500).map { |i| "line#{i}\n" }.join)

      collect(scenario_dir, sandbox, run_home)

      tail_path = File.join(scenario_dir, "logs", "myslug", "stage.log.tail")
      assert File.exist?(tail_path), "tail file should be written alongside the full log"
      tail_lines = File.readlines(tail_path)
      assert_equal Hive::E2E::ArtifactCapture::LOG_TAIL_LINES, tail_lines.size,
        "tail should be exactly the last #{Hive::E2E::ArtifactCapture::LOG_TAIL_LINES} lines"
      assert_equal "line500\n", tail_lines.last, "tail should end at the actual final log line"

      full_path = File.join(scenario_dir, "logs", "myslug", "stage.log")
      assert File.exist?(full_path), "full log should still be copied (forensic completeness)"
    end
  end

  def test_log_capture_skips_symlinked_logs
    with_dirs do |scenario_dir, sandbox, run_home|
      Dir.mktmpdir("outside-log") do |outside_dir|
        outside_log = File.join(outside_dir, "secret.log")
        File.write(outside_log, "SECRET\n")
        logs_root = File.join(sandbox, ".hive-state", "logs", "myslug")
        FileUtils.mkdir_p(logs_root)
        File.symlink(outside_log, File.join(logs_root, "stage.log"))

        collect(scenario_dir, sandbox, run_home)

        copied_log = File.join(scenario_dir, "logs", "myslug", "stage.log")
        refute File.exist?(copied_log), "symlinked logs must not be copied into the bundle"
        refute File.exist?("#{copied_log}.tail"), "symlinked logs must not be tailed"

        manifest = JSON.parse(File.read(File.join(scenario_dir, "manifest.json")))
        refute_includes manifest.fetch("files").map { |entry| entry.fetch("path") }, "logs/myslug/stage.log"
        assert manifest.fetch("capture_errors").any? { |entry| entry.fetch("label") == "logs:myslug/stage.log" },
               "skipped symlinked logs should leave a capture_errors breadcrumb"
      end
    end
  end

  def test_pane_before_and_after_both_written_on_tui_failure
    with_dirs do |scenario_dir, sandbox, run_home|
      fake_tmux = Object.new
      fake_tmux.define_singleton_method(:keystrokes) { [] }
      fake_tmux.define_singleton_method(:capture_pane) { "AFTER_PANE_TEXT\n" }

      collect(scenario_dir, sandbox, run_home,
              tmux_driver: fake_tmux,
              pane_before: "BEFORE_PANE_TEXT\n")

      pane_before = File.read(File.join(scenario_dir, "pane-before.txt"))
      pane_after = File.read(File.join(scenario_dir, "pane-after.txt"))

      assert_equal "BEFORE_PANE_TEXT\n", pane_before
      assert_equal "AFTER_PANE_TEXT\n", pane_after
    end
  end

  def test_pre_captured_tmux_evidence_survives_server_cleanup
    with_dirs do |scenario_dir, sandbox, run_home|
      collect(scenario_dir, sandbox, run_home,
              tmux_keystrokes: [ { "keys" => [ "enter" ] } ],
              pane_after: "FINAL_PANE_BEFORE_SHUTDOWN\n")

      assert_equal "FINAL_PANE_BEFORE_SHUTDOWN\n", File.read(File.join(scenario_dir, "pane-after.txt"))
      assert_equal [ { "keys" => [ "enter" ] } ],
                   JSON.parse(File.read(File.join(scenario_dir, "keystrokes.log")))
    end
  end

  def test_dead_tmux_pane_capture_records_placeholder
    with_dirs do |scenario_dir, sandbox, run_home|
      fake_tmux = Object.new
      fake_tmux.define_singleton_method(:keystrokes) { [] }
      fake_tmux.define_singleton_method(:capture_pane) { raise "pane is gone" }

      collect(scenario_dir, sandbox, run_home, tmux_driver: fake_tmux)

      pane_after = File.read(File.join(scenario_dir, "pane-after.txt"))
      assert_includes pane_after, "capture-pane failed",
        "artifact capture should preserve the original scenario failure when pane capture is already dead"
    end
  end

  def test_tui_subprocess_diagnostics_copied_into_bundle_when_present
    with_dirs do |scenario_dir, sandbox, run_home|
      log_dir = File.join(scenario_dir, "tui-live")
      FileUtils.mkdir_p(log_dir)
      spawn_log = File.join(log_dir, "hive-tui-spawn-FAKE.log")
      marker_log = File.join(log_dir, "hive-tui-subprocess.log")
      rotated_marker_log = File.join(log_dir, "hive-tui-subprocess.log.1")
      File.write(spawn_log, "FAKE-SPAWN-OUTPUT\n")
      File.write(marker_log, "----- BEGIN[FAKE]: hive plan -----\n")
      File.write(rotated_marker_log, "----- BEGIN[OLD]: hive run -----\n")

      collect(scenario_dir, sandbox, run_home, tui_log_dir: log_dir)

      copied_spawn = File.join(scenario_dir, "tui-subprocess", "hive-tui-spawn-FAKE.log")
      copied_marker = File.join(scenario_dir, "tui-subprocess", "hive-tui-subprocess.log")
      copied_rotated_marker = File.join(scenario_dir, "tui-subprocess", "hive-tui-subprocess.log.1")
      assert File.exist?(copied_spawn), "per-spawn capture file should be copied into the bundle"
      assert File.exist?(copied_marker), "shared TUI marker log should be copied into the bundle"
      assert File.exist?(copied_rotated_marker), "rotated shared TUI marker log should be copied into the bundle"
      assert_includes File.read(copied_spawn), "FAKE-SPAWN-OUTPUT",
                      "per-spawn capture body should round-trip into the bundle"
      assert File.exist?("#{copied_spawn}.tail"),
             "per-spawn capture should also get a .tail companion (matching log-tails pattern)"

      manifest = JSON.parse(File.read(File.join(scenario_dir, "manifest.json")))
      paths = manifest.fetch("files").map { |file| file.fetch("path") }
      assert_includes paths, "tui-subprocess/hive-tui-subprocess.log"
      assert_includes paths, "tui-subprocess/hive-tui-subprocess.log.1"
    end
  end

  def test_tui_subprocess_diagnostics_skip_symlinked_live_logs
    with_dirs do |scenario_dir, sandbox, run_home|
      Dir.mktmpdir("outside-tui-log") do |outside_dir|
        outside_log = File.join(outside_dir, "secret.log")
        File.write(outside_log, "SECRET\n")
        log_dir = File.join(scenario_dir, "tui-live")
        FileUtils.mkdir_p(log_dir)
        File.symlink(outside_log, File.join(log_dir, "hive-tui-spawn-FAKE.log"))
        File.symlink(outside_log, File.join(log_dir, "hive-tui-subprocess.log"))

        collect(scenario_dir, sandbox, run_home, tui_log_dir: log_dir)

        copied_spawn = File.join(scenario_dir, "tui-subprocess", "hive-tui-spawn-FAKE.log")
        copied_marker = File.join(scenario_dir, "tui-subprocess", "hive-tui-subprocess.log")
        refute File.exist?(copied_spawn), "symlinked TUI spawn logs must not be copied"
        refute File.exist?(copied_marker), "symlinked TUI marker logs must not be copied"

        manifest = JSON.parse(File.read(File.join(scenario_dir, "manifest.json")))
        paths = manifest.fetch("files").map { |entry| entry.fetch("path") }
        refute_includes paths, "tui-subprocess/hive-tui-spawn-FAKE.log"
        refute_includes paths, "tui-subprocess/hive-tui-subprocess.log"
        labels = manifest.fetch("capture_errors").map { |entry| entry.fetch("label") }
        assert_includes labels, "tui-subprocess:hive-tui-spawn-FAKE.log"
        assert_includes labels, "tui-subprocess:hive-tui-subprocess.log"
      end
    end
  end

  def test_tui_subprocess_diagnostics_ignore_global_tmp_logs
    with_dirs do |scenario_dir, sandbox, run_home|
      Dir.mktmpdir("hive-global-tui-log") do |global_dir|
        spawn_log = File.join(global_dir, "hive-tui-spawn-GLOBAL.log")
        File.write(spawn_log, "GLOBAL\n")
        collect(scenario_dir, sandbox, run_home)
        refute File.exist?(File.join(scenario_dir, "tui-subprocess", "hive-tui-spawn-GLOBAL.log")),
          "artifact capture must not copy stale global /tmp TUI logs into this scenario"
      end
    end
  end

  def test_tui_subprocess_spawn_capture_is_truncated_when_copied
    with_dirs do |scenario_dir, sandbox, run_home|
      log_dir = File.join(scenario_dir, "tui-live")
      FileUtils.mkdir_p(log_dir)
      spawn_log = File.join(log_dir, "hive-tui-spawn-BIG.log")
      File.write(spawn_log, "x" * (Hive::E2E::ArtifactCapture::TUI_SPAWN_CAPTURE_MAX_BYTES + 10))

      collect(scenario_dir, sandbox, run_home, tui_log_dir: log_dir)

      copied_spawn = File.join(scenario_dir, "tui-subprocess", "hive-tui-spawn-BIG.log")
      assert File.size(copied_spawn) < Hive::E2E::ArtifactCapture::TUI_SPAWN_CAPTURE_MAX_BYTES + 10,
             "artifact bundle should not copy oversized per-spawn captures wholesale"
      assert File.size("#{copied_spawn}.tail") <= File.size(copied_spawn),
             "tail companion should be derived from the truncated bundle copy"
      assert_includes File.read(copied_spawn, 128), "truncated to last"
      refute File.directory?(log_dir), "the supplied live diagnostics directory must be removed"
    end
  end

  def test_manifest_excludes_live_tui_subprocess_logs
    with_dirs do |scenario_dir, sandbox, run_home|
      log_dir = File.join(scenario_dir, "tui-subprocess-live")
      FileUtils.mkdir_p(log_dir)
      File.write(File.join(log_dir, "hive-tui-spawn-LIVE.log"), "LIVE\n")

      collect(scenario_dir, sandbox, run_home, tui_log_dir: log_dir)

      manifest = JSON.parse(File.read(File.join(scenario_dir, "manifest.json")))
      paths = manifest["files"].map { |file| file["path"] }
      refute paths.any? { |path| path.start_with?("tui-subprocess-live/") },
        "manifest should publish only curated tui-subprocess copies, not live logs"
      assert_includes paths, "tui-subprocess/hive-tui-spawn-LIVE.log"
    end
  end

  def test_manifest_includes_hidden_state_files
    with_dirs do |scenario_dir, sandbox, run_home|
      task_dir = File.join(sandbox, ".hive-state", "stages", "2-brainstorm", "task-1")
      FileUtils.mkdir_p(task_dir)
      lock_path = File.join(task_dir, ".lock")
      File.write(lock_path, "pid: 123\n")

      collect(scenario_dir, sandbox, run_home)

      copied_lock = File.join(scenario_dir, "state", "2-brainstorm", "task-1", ".lock")
      assert File.exist?(copied_lock), "hidden task lock should be copied into the artifact bundle"

      manifest = JSON.parse(File.read(File.join(scenario_dir, "manifest.json")))
      lock_entry = manifest.fetch("files").find { |file| file.fetch("path") == "state/2-brainstorm/task-1/.lock" }
      assert lock_entry, "manifest should include copied hidden state files"
      assert_equal File.size(copied_lock), lock_entry.fetch("size")
      assert_equal Digest::SHA256.file(copied_lock).hexdigest, lock_entry.fetch("sha256")
    end
  end

  def test_state_capture_skips_symlinked_state_files
    with_dirs do |scenario_dir, sandbox, run_home|
      Dir.mktmpdir("outside-state") do |outside_dir|
        outside_state = File.join(outside_dir, "task.md")
        File.write(outside_state, "SECRET\n")
        task_dir = File.join(sandbox, ".hive-state", "stages", "2-brainstorm", "task-1")
        FileUtils.mkdir_p(task_dir)
        File.symlink(outside_state, File.join(task_dir, "task.md"))

        collect(scenario_dir, sandbox, run_home)

        copied_state = File.join(scenario_dir, "state", "2-brainstorm", "task-1", "task.md")
        refute File.exist?(copied_state), "symlinked state files must not be copied into the bundle"

        manifest = JSON.parse(File.read(File.join(scenario_dir, "manifest.json")))
        refute_includes manifest.fetch("files").map { |entry| entry.fetch("path") },
                        "state/2-brainstorm/task-1/task.md"
        assert manifest.fetch("capture_errors").any? { |entry| entry.fetch("label") == "state:2-brainstorm/task-1/task.md" },
               "skipped symlinked state should leave a capture_errors breadcrumb"
      end
    end
  end

  def test_env_snapshot_is_json_with_schema_version
    with_dirs do |scenario_dir, sandbox, run_home|
      collect(scenario_dir, sandbox, run_home)

      json_path = File.join(scenario_dir, "env-snapshot.json")
      assert File.exist?(json_path), "env-snapshot must be JSON, not plaintext"

      payload = JSON.parse(File.read(json_path))
      assert_equal "hive-e2e-env-snapshot", payload["schema"]
      assert_equal 1, payload["schema_version"]
      assert_kind_of String, payload["ruby"]
      assert_kind_of String, payload["platform"]
    end
  end

  def test_manifest_skips_preexisting_symlinked_bundle_files
    with_dirs do |scenario_dir, sandbox, run_home|
      Dir.mktmpdir("outside-manifest") do |outside_dir|
        outside_file = File.join(outside_dir, "secret.txt")
        File.write(outside_file, "SECRET\n")
        FileUtils.mkdir_p(scenario_dir)
        File.symlink(outside_file, File.join(scenario_dir, "linked-secret.txt"))

        collect(scenario_dir, sandbox, run_home)

        manifest = JSON.parse(File.read(File.join(scenario_dir, "manifest.json")))
        refute_includes manifest.fetch("files").map { |entry| entry.fetch("path") }, "linked-secret.txt"
        assert manifest.fetch("capture_errors").any? { |entry| entry.fetch("label") == "manifest:linked-secret.txt" },
               "skipped symlinked manifest inputs should leave a capture_errors breadcrumb"
      end
    end
  end

  def test_tui_subprocess_live_logs_are_removed_before_manifest
    with_dirs do |scenario_dir, sandbox, run_home|
      live_dir = File.join(scenario_dir, "tui-subprocess-live")
      FileUtils.mkdir_p(live_dir)
      oversized_bytes = Hive::E2E::ArtifactCapture::TUI_SPAWN_CAPTURE_MAX_BYTES + 10
      spawn_log = File.join(live_dir, "hive-tui-spawn-BIG.log")
      File.write(spawn_log, "x" * oversized_bytes)

      collect(scenario_dir, sandbox, run_home, tui_log_dir: live_dir)

      copied_spawn = File.join(scenario_dir, "tui-subprocess", "hive-tui-spawn-BIG.log")
      assert File.exist?(copied_spawn), "bounded per-spawn copy should be retained"
      assert_operator File.size(copied_spawn), :<, oversized_bytes,
                      "oversized live output should only be retained through the truncated copy"
      refute File.directory?(live_dir), "unbounded live TUI log directory should not remain in the bundle"

      manifest = JSON.parse(File.read(File.join(scenario_dir, "manifest.json")))
      paths = manifest.fetch("files").map { |file| file.fetch("path") }
      refute paths.any? { |path| path.start_with?("tui-subprocess-live/") },
             "manifest should not include unbounded live TUI logs"
    end
  end

  def test_manifest_records_capture_error_when_file_disappears_during_digest
    with_dirs do |scenario_dir, sandbox, run_home|
      racy_path = File.join(scenario_dir, "racy.log")
      File.write(racy_path, "racy\n")
      original_digest_file = Digest::SHA256.method(:file)
      Digest::SHA256.define_singleton_method(:file) do |path|
        raise Errno::ENOENT, path if path == racy_path

        original_digest_file.call(path)
      end

      collect(scenario_dir, sandbox, run_home)

      manifest = JSON.parse(File.read(File.join(scenario_dir, "manifest.json")))
      refute_includes manifest["files"].map { |entry| entry["path"] }, "racy.log"
      error = manifest["capture_errors"].find { |entry| entry["label"] == "manifest:racy.log" }
      assert error, "manifest should record disappeared files instead of raising"
      assert_includes error["error"], "Errno::ENOENT"
    ensure
      Digest::SHA256.define_singleton_method(:file, original_digest_file) if original_digest_file
    end
  end

  def test_gh_script_state_and_audit_are_copied_into_failure_bundle
    with_dirs do |scenario_dir, sandbox, run_home|
      gh_root = File.join(run_home, "gh-stub")
      FileUtils.mkdir_p(gh_root)
      File.write(File.join(gh_root, "script.json"), "{}\n")
      File.write(File.join(gh_root, "state.json"), "{\"next_index\":0}\n")
      File.write(File.join(gh_root, "audit.jsonl"), "{\"matched\":false}\n")

      collect(scenario_dir, sandbox, run_home)

      assert_equal "{\"matched\":false}\n", File.read(File.join(scenario_dir, "gh", "audit.jsonl"))
      manifest = JSON.parse(File.read(File.join(scenario_dir, "manifest.json")))
      assert_includes manifest.fetch("files").map { |entry| entry.fetch("path") }, "gh/script.json"
    end
  end
end
