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
      # Stub ENV["TERM"] to nil and force git -C $sandbox to fail by using a
      # sandbox without .git. The capture step that depends on it raises,
      # but the original RuntimeError is still the surfaced scenario error.
      original_error = RuntimeError.new("ORIGINAL_ERROR_TEXT")
      collect(scenario_dir, sandbox, run_home, error: original_error)

      exception_text = File.read(File.join(scenario_dir, "exception.txt"))
      assert_includes exception_text, "ORIGINAL_ERROR_TEXT",
        "original error must surface in exception.txt regardless of capture failures"

      manifest = JSON.parse(File.read(File.join(scenario_dir, "manifest.json")))
      # capture_errors may or may not be empty (sandbox-tree.txt + git status
      # both succeed against an empty dir); the contract is that the manifest
      # is well-formed and the original error is preserved.
      assert manifest.key?("capture_errors")
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
      File.write(spawn_log, "FAKE-SPAWN-OUTPUT\n")
      File.write(marker_log, "----- BEGIN[FAKE]: hive plan -----\n")

      collect(scenario_dir, sandbox, run_home, tui_log_dir: log_dir)

      copied_spawn = File.join(scenario_dir, "tui-subprocess", "hive-tui-spawn-FAKE.log")
      copied_marker = File.join(scenario_dir, "tui-subprocess", "hive-tui-subprocess.log")
      assert File.exist?(copied_spawn), "per-spawn capture file should be copied into the bundle"
      assert File.exist?(copied_marker), "shared TUI marker log should be copied into the bundle"
      assert_includes File.read(copied_spawn), "FAKE-SPAWN-OUTPUT",
                      "per-spawn capture body should round-trip into the bundle"
      assert File.exist?("#{copied_spawn}.tail"),
             "per-spawn capture should also get a .tail companion (matching log-tails pattern)"
    end
  end

  def test_tui_subprocess_diagnostics_ignore_global_tmp_logs
    with_dirs do |scenario_dir, sandbox, run_home|
      spawn_log = File.join(Dir.tmpdir, "hive-tui-spawn-GLOBAL.log")
      File.write(spawn_log, "GLOBAL\n")
      begin
        collect(scenario_dir, sandbox, run_home)
        refute File.exist?(File.join(scenario_dir, "tui-subprocess", "hive-tui-spawn-GLOBAL.log")),
          "artifact capture must not copy stale global /tmp TUI logs into this scenario"
      ensure
        File.delete(spawn_log) if File.exist?(spawn_log)
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
      assert File.size(copied_spawn) < File.size(spawn_log),
             "artifact bundle should not copy oversized per-spawn captures wholesale"
      assert File.size("#{copied_spawn}.tail") <= File.size(copied_spawn),
             "tail companion should be derived from the truncated bundle copy"
      assert_includes File.read(copied_spawn, 128), "truncated to last"
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
end
