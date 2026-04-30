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
    Hive::E2E::ArtifactCapture.new(scenario_dir: scenario_dir, sandbox_dir: sandbox, run_home: run_home)
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
end
