require "test_helper"
require "open3"
require "rbconfig"

class DoctorConfigValidationIntegrationTest < Minitest::Test
  include HiveTestHelper

  HIVE_BIN = File.expand_path("../../bin/hive", __dir__)
  HIVE_LIB = File.expand_path("../../lib", __dir__)

  def test_doctor_rejects_invalid_promoted_reviewers_without_running_probes
    with_doctor_project("reviewers" => nil) do |out, err, status, probe_marker, config_path|
      assert_equal Hive::ExitCodes::CONFIG, status.exitstatus
      assert_empty out
      assert_includes err, "review.reviewers"
      assert_includes err, "is nil"
      assert_includes err, config_path
      refute File.exist?(probe_marker), "doctor probes must not run after shared config validation fails"
      refute_includes out, "hive doctor"
    end
  end

  def test_doctor_reports_generic_unknown_top_level_key
    with_doctor_project("defualt_branch" => "main") do |out, err, status, probe_marker, config_path|
      assert_equal Hive::ExitCodes::CONFIG, status.exitstatus
      assert_empty out
      assert_includes err, "Unknown top-level key `defualt_branch`."
      assert_includes err, config_path
      refute File.exist?(probe_marker), "doctor probes must not run after shared config validation fails"
    end
  end

  private

  def with_doctor_project(config)
    with_tmp_global_config do |home|
      with_tmp_dir do |project_root|
        state_dir = File.join(project_root, ".hive-state")
        FileUtils.mkdir_p(state_dir)
        FileUtils.mkdir_p(File.join(project_root, ".llm-wiki"))
        config_path = File.join(state_dir, "config.yml")
        File.write(config_path, config.to_yaml)

        probe_marker = File.join(home, "doctor-probe-ran")
        probe_bin = File.join(home, "doctor-probe")
        File.write(probe_bin, <<~SH)
          #!/bin/sh
          : > "$HIVE_DOCTOR_PROBE_MARKER"
          echo "probe should not run"
        SH
        FileUtils.chmod(0o755, probe_bin)
        env = {
          "HOME" => home,
          "HIVE_HOME" => home,
          "HIVE_QMD_BIN" => probe_bin,
          "HIVE_CLAUDE_BIN" => probe_bin,
          "HIVE_DOCTOR_PROBE_MARKER" => probe_marker
        }

        out, err, status = Open3.capture3(
          env,
          RbConfig.ruby, "-I", HIVE_LIB, HIVE_BIN, "doctor",
          chdir: project_root
        )
        yield out, err, status, probe_marker, config_path
      end
    end
  end
end
