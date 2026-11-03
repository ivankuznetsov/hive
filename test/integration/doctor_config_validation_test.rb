require "test_helper"
require "open3"
require "rbconfig"

class DoctorConfigValidationIntegrationTest < Minitest::Test
  include HiveTestHelper

  HIVE_BIN = File.expand_path("../../bin/hive", __dir__)
  HIVE_LIB = File.expand_path("../../lib", __dir__)

  def test_doctor_rejects_obsolete_root_reviewers_without_running_probes
    with_doctor_project({ "reviewers" => nil }) do |out, err, status, probe_marker, config_path|
      assert_equal Hive::ExitCodes::CONFIG, status.exitstatus
      assert_empty out
      assert_includes err, "Unknown top-level key `reviewers`."
      assert_includes err, config_path
      refute File.exist?(probe_marker), "doctor probes must not run after shared config validation fails"
      refute_includes out, "hive doctor"
    end
  end

  def test_doctor_reports_generic_unknown_top_level_key
    with_doctor_project({ "defualt_branch" => "main" }) do |out, err, status, probe_marker, config_path|
      assert_equal Hive::ExitCodes::CONFIG, status.exitstatus
      assert_empty out
      assert_includes err, "Unknown top-level key `defualt_branch`."
      assert_includes err, config_path
      refute File.exist?(probe_marker), "doctor probes must not run after shared config validation fails"
    end
  end

  def test_whole_default_command_never_launches_registered_agents_outside_minitest
    with_doctor_project({}) do |out, err, status, probe_marker, _config_path|
      assert_includes [ 0, 65 ], status.exitstatus, err
      refute File.exist?(probe_marker), "default production doctor must not launch agents for skills, MCP, versions, or helper aliases"
      assert_includes out, "registered agent executable; version probe skipped"
      assert_includes out, "personal MCP drift is uninspected"
      assert_includes out, "agent_cli/claude"
      assert_includes out, "agent_cli/opencode"
    end
  end

  def test_distinct_qmd_helper_is_allowed_without_launching_agents
    with_doctor_project({}, separate_qmd: true) do |out, err, status, probe_marker, _config_path|
      assert_includes [ 0, 65 ], status.exitstatus, err
      refute File.exist?(probe_marker)
      assert_match(/wiki\/qmd.*✓ present/, out)
    end
  end

  private

  def with_doctor_project(config, separate_qmd: false)
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
        qmd = probe_bin
        if separate_qmd
          qmd = File.join(home, "qmd-helper")
          File.write(qmd, "#!/bin/sh\necho 'qmd 2.1.0'\n")
          FileUtils.chmod(0o755, qmd)
        end
        env = {
          "HOME" => home,
          "HIVE_HOME" => home,
          "HIVE_QMD_BIN" => qmd,
          "HIVE_CLAUDE_BIN" => probe_bin,
          "HIVE_CODEX_BIN" => probe_bin,
          "HIVE_PI_BIN" => probe_bin,
          "HIVE_GROK_BIN" => probe_bin,
          "HIVE_OPENCODE_BIN" => probe_bin,
          "OPENCLAW_BIN" => probe_bin,
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
