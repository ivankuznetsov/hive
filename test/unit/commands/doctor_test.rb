require "test_helper"
require "stringio"
require "fileutils"
require "json"
require "digest"
require "hive/commands/doctor"

class HiveCommandsDoctorTest < Minitest::Test
  include HiveTestHelper

  class ResolutionOnlyInspector
    def initialize(config:, project_root:)
      @config = config
      @project_root = project_root
    end

    def inspect
      Hive::AgentSkills::TargetResolver.new(config: @config, project_root: @project_root).resolve
        .reject { |target| target.capability_id == "hive" }.map do |target|
        if target.kind == "linter" || target.kind == "codex_review"
          health = "healthy"
          message = "kind '#{target.kind}' is not 'agent'; doctor only checks agent-kind reviewers"
          resolution = { "status" => "not_applicable", "path" => nil }
        else
          resolver = case target.agent
          when "claude" then Hive::SkillCheck::Claude
          when "codex" then Hive::SkillCheck::Codex
          when "pi" then Hive::SkillCheck::Pi
          end
          found = resolver.resolve(target.invocation, project_root: @project_root)
          health = found.status == :present ? "healthy" : "missing"
          message = found.message
          resolution = { "status" => found.status.to_s, "path" => found.path }
        end
        Hive::AgentSkills::Inspection.new(
          target: target, expected: {}, native: { "available" => true },
          resolution: resolution, health: health,
          severity: health == "healthy" ? "info" : "error",
          explanation: message, remediation: target.managed ? "hive setup-agents --agent #{target.agent} --skill #{target.capability_id}" : "manual"
        )
      end
    end
  end

  def with_fake_home
    with_tmp_dir do |dir|
      old = ENV["HOME"]
      original_inspector_new = Hive::AgentSkills::Inspector.method(:new)
      ENV["HOME"] = dir
      Hive::AgentSkills::Inspector.define_singleton_method(:new) do |config:, project_root:, **|
        ResolutionOnlyInspector.new(config: config, project_root: project_root)
      end
      yield dir
    ensure
      Hive::AgentSkills::Inspector.define_singleton_method(:new, original_inspector_new) if original_inspector_new
      old.nil? ? ENV.delete("HOME") : ENV["HOME"] = old
    end
  end

  def write_file(path, content = "")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def base_config(overrides = {})
    {
      "claude" => { "mode" => "headless" },
      "brainstorm" => { "agent" => "claude" },
      "plan" => { "agent" => "claude" }
    }.merge(overrides) { |_k, a, b| a.merge(b) }
  end

  def with_fake_tmux(output)
    with_tmp_dir do |dir|
      path = File.join(dir, "tmux")
      File.write(path, <<~SH)
        #!/usr/bin/env bash
        echo "#{output}"
      SH
      File.chmod(0o755, path)
      old = ENV["HIVE_TMUX_BIN"]
      ENV["HIVE_TMUX_BIN"] = path
      yield
    ensure
      old.nil? ? ENV.delete("HIVE_TMUX_BIN") : ENV["HIVE_TMUX_BIN"] = old
    end
  end

  def test_exit_success_when_all_present
    with_fake_home do |home|
      write_file("#{home}/.claude/plugins/cache/mp/compound-engineering/3.0.1/skills/ce-brainstorm/SKILL.md")
      write_file("#{home}/.claude/commands/plan.md")
      out = StringIO.new
      cfg = base_config(
        "brainstorm" => { "agent" => "claude", "skill" => "/compound-engineering:ce-brainstorm" },
        "plan" => { "agent" => "claude", "skill" => "/plan" }
      )
      exit_code = Hive::Commands::Doctor.new(
        config: cfg,
        project_root: nil,
        output: out
      ).call
      assert_equal 0, exit_code
      assert_match(/✓ present/, out.string)
      refute_match(/✗ missing/, out.string)
    end
  end

  def test_exit_missing_skill_when_one_missing
    with_fake_home do |home|
      write_file("#{home}/.claude/commands/plan.md")
      # ce-brainstorm intentionally absent
      out = StringIO.new
      cfg = base_config(
        "brainstorm" => { "agent" => "claude", "skill" => "/compound-engineering:ce-brainstorm" },
        "plan" => { "agent" => "claude", "skill" => "/plan" }
      )
      exit_code = Hive::Commands::Doctor.new(
        config: cfg,
        project_root: nil,
        output: out
      ).call
      assert_equal Hive::Commands::Doctor::EXIT_MISSING_SKILL, exit_code
      assert_match(/✗ missing/, out.string)
      assert_match(/claude plugin install/, out.string,
        "human-readable output must include the install hint for the missing one")
    end
  end

  def test_pi_stage_uses_profile_skill_format_and_resolves
    with_fake_home do |home|
      write_file("#{home}/.pi/agent/skills/ce-brainstorm/SKILL.md")
      write_file("#{home}/.pi/agent/skills/wiki-plan/SKILL.md")
      out = StringIO.new
      cfg = {
        "claude" => { "mode" => "headless" },
        "brainstorm" => { "agent" => "pi" },
        "plan" => { "agent" => "pi" }
      }
      exit_code = Hive::Commands::Doctor.new(
        config: cfg,
        project_root: nil,
        output: out
      ).call
      assert_equal 0, exit_code
      assert_match(%r{brainstorm.*pi.*/skill:ce-brainstorm.*✓ present}, out.string)
      assert_match(%r{plan.*pi.*/skill:wiki-plan.*✓ present}, out.string)
    end
  end

  def test_pi_stage_missing_when_formatted_skill_absent
    with_fake_home do |home|
      write_file("#{home}/.pi/agent/skills/ce-brainstorm/SKILL.md")
      out = StringIO.new
      cfg = {
        "claude" => { "mode" => "headless" },
        "brainstorm" => { "agent" => "pi" },
        "plan" => { "agent" => "pi" }
      }
      exit_code = Hive::Commands::Doctor.new(
        config: cfg,
        project_root: nil,
        output: out
      ).call
      assert_equal Hive::Commands::Doctor::EXIT_MISSING_SKILL, exit_code
      assert_match(%r{plan.*pi.*/skill:wiki-plan.*✗ missing}, out.string)
    end
  end

  def test_codex_plan_stage_uses_llm_wiki_plugin_skill_by_default
    with_fake_home do |home|
      write_file("#{home}/.codex/plugins/cache/mp/llm-wiki/0.1.7/skills/wiki-plan/SKILL.md")
      write_file("#{home}/.codex/plugins/cache/mp/compound-engineering/3.8.1/skills/ce-brainstorm/SKILL.md")
      out = StringIO.new
      cfg = {
        "claude" => { "mode" => "headless" },
        "brainstorm" => { "agent" => "codex" },
        "plan" => { "agent" => "codex" }
      }
      exit_code = Hive::Commands::Doctor.new(
        config: cfg,
        project_root: nil,
        output: out
      ).call

      assert_equal 0, exit_code
      assert_match(%r{plan.*codex.*/llm-wiki:wiki-plan.*✓ present}, out.string)
    end
  end

  def test_codex_plan_stage_maps_legacy_plan_alias_to_llm_wiki
    with_fake_home do |home|
      write_file("#{home}/.codex/plugins/cache/mp/llm-wiki/0.1.7/skills/wiki-plan/SKILL.md")
      write_file("#{home}/.codex/plugins/cache/mp/compound-engineering/3.8.1/skills/ce-brainstorm/SKILL.md")
      out = StringIO.new
      cfg = {
        "claude" => { "mode" => "headless" },
        "brainstorm" => { "agent" => "codex" },
        "plan" => { "agent" => "codex", "skill" => "/plan" }
      }
      exit_code = Hive::Commands::Doctor.new(
        config: cfg,
        project_root: nil,
        output: out
      ).call

      assert_equal 0, exit_code
      assert_match(%r{plan.*codex.*/llm-wiki:wiki-plan.*✓ present}, out.string)
    end
  end

  def test_json_envelope_shape
    with_fake_home do |home|
      write_file("#{home}/.claude/commands/plan.md")
      out = StringIO.new
      cfg = base_config(
        "brainstorm" => { "agent" => "claude", "skill" => "/missing-plug:missing-skill" },
        "plan" => { "agent" => "claude", "skill" => "/plan" }
      )
      exit_code = Hive::Commands::Doctor.new(
        config: cfg,
        project_root: nil,
        json: true,
        output: out
      ).call
      assert_equal Hive::Commands::Doctor::EXIT_MISSING_SKILL, exit_code

      env = JSON.parse(out.string)
      assert_equal "hive-doctor.v2", env["schema"]
      assert_equal 3, env["managed_skills"].length
      assert_equal 2, env.dig("summary", "managed", "missing")
      assert_equal 1, env.dig("summary", "managed", "healthy")
      assert(env["managed_skills"].any? { |c| c["stage"] == "plan" && c["health"] == "healthy" })
      assert(env["managed_skills"].any? { |c| c["stage"] == "brainstorm" && c["health"] == "missing" })
      assert(env["managed_skills"].any? do |row|
        row["stage"] == "prerequisite:llm-wiki" && row["health"] == "missing"
      end)
    end
  end

  def test_uses_config_defaults_when_skill_key_unset
    with_fake_home do |home|
      # No `skill:` key in config; doctor falls back to DEFAULTS
      # ("/ce-brainstorm" and Claude's "/plan").
      write_file("#{home}/.claude/plugins/cache/mp/compound-engineering/3.0.1/skills/ce-brainstorm/SKILL.md")
      write_file("#{home}/.claude/commands/plan.md")
      out = StringIO.new
      cfg = {
        "claude" => { "mode" => "headless" },
        "brainstorm" => { "agent" => "claude" },
        "plan" => { "agent" => "claude" }
      }
      exit_code = Hive::Commands::Doctor.new(
        config: cfg,
        project_root: nil,
        output: out
      ).call
      assert_equal 0, exit_code
      assert_match(%r{/ce-brainstorm}, out.string)
      assert_match(%r{/plan}, out.string)
    end
  end

  def test_project_root_affects_claude_plain_invocation_resolution
    with_fake_home do |home|
      # No user-level claude /plan, but project-level present.
      with_tmp_dir do |project|
        write_file("#{home}/.claude/commands/x.md")
        write_file("#{home}/.claude/plugins/cache/mp/compound-engineering/3.0.1/skills/ce-brainstorm/SKILL.md")
        write_file("#{project}/.claude/commands/plan.md")
        out = StringIO.new
        cfg = base_config(
          "brainstorm" => { "agent" => "claude", "skill" => "/x" }, # parked
          "plan" => { "agent" => "claude", "skill" => "/plan" }
        )
        exit_code = Hive::Commands::Doctor.new(
          config: cfg,
          project_root: project,
          output: out
        ).call
        assert_equal 0, exit_code, "project-level /plan should be detected"
        assert_match(/✓ present/, out.string)
      end
    end
  end

  def test_tmux_dependency_row_is_reported_for_global_claude_tmux_mode
    with_fake_home do |home|
      write_file("#{home}/.claude/plugins/cache/mp/compound-engineering/3.0.1/skills/ce-brainstorm/SKILL.md")
      write_file("#{home}/.claude/commands/plan.md")
      with_fake_tmux("tmux 3.6a") do
        out = StringIO.new
        cfg = base_config(
          "claude" => { "mode" => "tmux" },
          "brainstorm" => {
            "agent" => "claude",
            "skill" => "/compound-engineering:ce-brainstorm"
          },
          "plan" => { "agent" => "claude", "skill" => "/plan" }
        )

        exit_code = Hive::Commands::Doctor.new(config: cfg, project_root: nil, output: out).call

        assert_equal 0, exit_code
        assert_match(%r{claude/tmux.*tmux.*✓ present}, out.string)
      end
    end
  end

  def test_tmux_dependency_row_fails_when_global_tmux_mode_cannot_run_tmux
    with_fake_home do |home|
      write_file("#{home}/.claude/plugins/cache/mp/compound-engineering/3.0.1/skills/ce-brainstorm/SKILL.md")
      write_file("#{home}/.claude/commands/plan.md")
      old = ENV["HIVE_TMUX_BIN"]
      ENV["HIVE_TMUX_BIN"] = "missing-tmux-for-hive"
      out = StringIO.new
      cfg = base_config(
        "claude" => { "mode" => "tmux" },
        "brainstorm" => {
          "agent" => "claude",
          "skill" => "/compound-engineering:ce-brainstorm"
        },
        "plan" => { "agent" => "claude", "skill" => "/plan" }
      )

      exit_code = Hive::Commands::Doctor.new(config: cfg, project_root: nil, output: out).call

      assert_equal Hive::Commands::Doctor::EXIT_MISSING_SKILL, exit_code
      assert_match(%r{claude/tmux.*✗ missing}, out.string)
      assert_match(/tmux binary not runnable/, out.string)
    ensure
      old.nil? ? ENV.delete("HIVE_TMUX_BIN") : ENV["HIVE_TMUX_BIN"] = old
    end
  end

  def test_tmux_mode_does_not_warn_for_non_claude_stage_agents
    with_fake_home do |home|
      write_file("#{home}/.pi/agent/skills/ce-brainstorm/SKILL.md")
      write_file("#{home}/.pi/agent/skills/wiki-plan/SKILL.md")
      with_fake_tmux("tmux 3.6a") do
        out = StringIO.new
        cfg = base_config(
          "claude" => { "mode" => "tmux" },
          "brainstorm" => { "agent" => "pi" },
          "plan" => { "agent" => "pi" }
        )

        exit_code = Hive::Commands::Doctor.new(config: cfg, project_root: nil, output: out).call

        assert_equal 0, exit_code
        assert_match(%r{claude/tmux.*✓ present}, out.string)
        refute_match(/! warning/, out.string)
      end
    end
  end

  def test_tmux_runtime_warns_when_api_key_env_is_exported
    old_anthropic = ENV["ANTHROPIC_API_KEY"]
    old_claude = ENV["CLAUDE_API_KEY"]
    ENV["ANTHROPIC_API_KEY"] = "test-key"
    ENV.delete("CLAUDE_API_KEY")

    with_fake_home do |home|
      write_file("#{home}/.claude/plugins/cache/mp/compound-engineering/3.0.1/skills/ce-brainstorm/SKILL.md")
      write_file("#{home}/.claude/commands/plan.md")
      with_fake_tmux("tmux 3.6a") do
        out = StringIO.new
        cfg = base_config(
          "claude" => { "mode" => "tmux" },
          "brainstorm" => {
            "agent" => "claude",
            "skill" => "/compound-engineering:ce-brainstorm"
          },
          "plan" => { "agent" => "claude", "skill" => "/plan" }
        )

        Hive::Commands::Doctor.new(config: cfg, project_root: nil, json: true, output: out).call

        env = JSON.parse(out.string)
        warning = env.fetch("checks").find { |check| check["status"] == "warning" }
        assert_equal 1, env.fetch("summary").fetch("warnings")
        assert_equal "billing-auth", warning.fetch("configured_skill")
        assert_equal "ANTHROPIC_API_KEY", warning.fetch("skill")
      end
    end
  ensure
    old_anthropic.nil? ? ENV.delete("ANTHROPIC_API_KEY") : ENV["ANTHROPIC_API_KEY"] = old_anthropic
    old_claude.nil? ? ENV.delete("CLAUDE_API_KEY") : ENV["CLAUDE_API_KEY"] = old_claude
  end

  def test_llm_wiki_qmd_uses_hive_managed_binary_when_not_on_path
    with_fake_home do |home|
      install_brainstorm_and_plan_skills(home)
      with_tmp_dir do |project|
        FileUtils.mkdir_p(File.join(project, ".llm-wiki"))
        with_tmp_dir do |data_home|
          qmd = File.join(data_home, "hive", "qmd", "bin", "qmd")
          write_file(qmd, <<~SH)
            #!/bin/sh
            echo "qmd 2.1.0"
          SH
          File.chmod(0o755, qmd)

          out = StringIO.new
          cfg = base_config(
            "brainstorm" => { "agent" => "claude", "skill" => "/x" },
            "plan" => { "agent" => "claude", "skill" => "/x" }
          )

          with_env("XDG_DATA_HOME" => data_home, "PATH" => "", "HIVE_QMD_BIN" => nil) do
            doctor = Hive::Commands::Doctor.new(config: cfg, project_root: project, output: out)
            exit_code = doctor.call

            assert_equal 0, exit_code
            assert_match(%r{wiki/qmd.*✓ present}, out.string)
            qmd_row = doctor.rows.find { |row| row[:label] == "wiki/qmd" }
            assert_match(/qmd 2\.1\.0/, qmd_row.fetch(:message))
          end
        end
      end
    end
  end

  def test_llm_wiki_qmd_warning_when_binary_fails_to_start
    with_fake_home do |home|
      install_brainstorm_and_plan_skills(home)
      with_tmp_dir do |project|
        FileUtils.mkdir_p(File.join(project, ".llm-wiki"))
        with_tmp_dir do |bin_dir|
          qmd = File.join(bin_dir, "qmd")
          write_file(qmd, <<~SH)
            #!/usr/bin/env bash
            echo "NODE_MODULE_VERSION mismatch" >&2
            exit 1
          SH
          File.chmod(0o755, qmd)

          out = StringIO.new
          cfg = base_config(
            "brainstorm" => { "agent" => "claude", "skill" => "/x" },
            "plan" => { "agent" => "claude", "skill" => "/x" }
          )

          with_env("HIVE_QMD_BIN" => qmd) do
            exit_code = Hive::Commands::Doctor.new(config: cfg, project_root: project, output: out).call

            assert_equal 0, exit_code
            assert_match(%r{wiki/qmd.*! warning}, out.string)
            assert_match(/NODE_MODULE_VERSION mismatch/, out.string)
            assert_match(/npm rebuild better-sqlite3/, out.string)
          end
        end
      end
    end
  end

  def test_llm_wiki_qmd_uses_install_prefix_sidecar_binary
    with_fake_home do |home|
      install_brainstorm_and_plan_skills(home)
      with_tmp_dir do |project|
        FileUtils.mkdir_p(File.join(project, ".llm-wiki"))
        with_tmp_dir do |data_home|
          with_tmp_dir do |prefix|
            # No qmd at the default <data_home>/hive/qmd/bin/qmd candidate;
            # the install-prefix sidecar points at a separate prefix dir.
            write_file(File.join(data_home, "hive", "install-prefix"), "#{prefix}\n")
            qmd = File.join(prefix, "hive", "qmd", "bin", "qmd")
            write_file(qmd, <<~SH)
              #!/bin/sh
              echo "qmd 2.2.0"
            SH
            File.chmod(0o755, qmd)

            out = StringIO.new
            cfg = base_config(
              "brainstorm" => { "agent" => "claude", "skill" => "/x" },
              "plan" => { "agent" => "claude", "skill" => "/x" }
            )

            with_env("XDG_DATA_HOME" => data_home, "PATH" => "", "HIVE_QMD_BIN" => nil) do
              doctor = Hive::Commands::Doctor.new(config: cfg, project_root: project, output: out)
              exit_code = doctor.call

              assert_equal 0, exit_code
              assert_match(%r{wiki/qmd.*✓ present}, out.string)
              qmd_row = doctor.rows.find { |row| row[:label] == "wiki/qmd" }
              assert_match(/qmd 2\.2\.0/, qmd_row.fetch(:message),
                "doctor must resolve qmd via the install-prefix sidecar")
            end
          end
        end
      end
    end
  end

  def test_llm_wiki_qmd_warning_when_not_found
    with_fake_home do |home|
      install_brainstorm_and_plan_skills(home)
      with_tmp_dir do |project|
        FileUtils.mkdir_p(File.join(project, ".llm-wiki"))
        with_tmp_dir do |data_home|
          # Empty data_home: no qmd at the default candidate and no
          # install-prefix sidecar file.
          out = StringIO.new
          cfg = base_config(
            "brainstorm" => { "agent" => "claude", "skill" => "/x" },
            "plan" => { "agent" => "claude", "skill" => "/x" }
          )

          with_env("XDG_DATA_HOME" => data_home, "PATH" => "", "HIVE_QMD_BIN" => nil) do
            exit_code = Hive::Commands::Doctor.new(config: cfg, project_root: project, output: out).call

            assert_equal 0, exit_code
            assert_match(%r{wiki/qmd.*! warning}, out.string)
            assert_match(/qmd is not installed or not discoverable/, out.string)
          end
        end
      end
    end
  end

  def test_llm_wiki_qmd_warning_when_binary_cannot_be_executed
    with_fake_home do |home|
      install_brainstorm_and_plan_skills(home)
      with_tmp_dir do |project|
        FileUtils.mkdir_p(File.join(project, ".llm-wiki"))
        with_tmp_dir do |bin_dir|
          # Executable file whose shebang names a missing interpreter, so
          # Open3.capture3 raises Errno::ENOENT — FIX 1 must rescue it.
          qmd = File.join(bin_dir, "qmd")
          write_file(qmd, <<~SH)
            #!/nonexistent/xyz
            echo unreachable
          SH
          File.chmod(0o755, qmd)

          out = StringIO.new
          cfg = base_config(
            "brainstorm" => { "agent" => "claude", "skill" => "/x" },
            "plan" => { "agent" => "claude", "skill" => "/x" }
          )

          with_env("HIVE_QMD_BIN" => qmd) do
            # No assert_nothing_raised: if FIX 1's rescue is absent the
            # call raises Errno::ENOENT and this test errors out.
            exit_code = Hive::Commands::Doctor.new(config: cfg, project_root: project, output: out).call

            assert_equal 0, exit_code
            assert_match(%r{wiki/qmd.*! warning}, out.string)
            assert_match(/timed out or could not be executed/, out.string)
          end
        end
      end
    end
  end

  def test_legacy_brainstorm_runtime_row_warns_to_migrate
    with_fake_home do |home|
      write_file("#{home}/.claude/plugins/cache/mp/compound-engineering/3.0.1/skills/ce-brainstorm/SKILL.md")
      write_file("#{home}/.claude/commands/plan.md")
      out = StringIO.new
      cfg = base_config(
        "brainstorm" => {
          "agent" => "claude",
          "skill" => "/compound-engineering:ce-brainstorm",
          "runtime" => "tmux_interactive"
        },
        "plan" => { "agent" => "claude", "skill" => "/plan" }
      )

      exit_code = Hive::Commands::Doctor.new(config: cfg, project_root: nil, output: out).call

      assert_equal 0, exit_code
      assert_match(%r{2-brainstorm/brainstorm\.runtime.*! warning}, out.string)
      assert_match(/superseded by claude\.mode/, out.string)
    end
  end

  # ---- Review.reviewers extension (U1/U2/U3) ----

  def cfg_with_reviewers(reviewers)
    {
      "claude" => { "mode" => "headless" },
      "brainstorm" => { "agent" => "claude", "skill" => "/x" }, # parked
      "plan" => { "agent" => "claude", "skill" => "/x" },       # parked
      "review" => { "reviewers" => reviewers }
    }
  end

  def install_brainstorm_and_plan_skills(home)
    # Install the parked stage skills so the test focuses on reviewer behaviour.
    write_file("#{home}/.claude/commands/x.md")
  end

  def test_review_reviewers_happy_path_all_present
    with_fake_home do |home|
      install_brainstorm_and_plan_skills(home)
      # Reviewers' ce-code-review installed at user level (matches the
      # bare-name → /ce-code-review invocation path).
      write_file("#{home}/.claude/skills/ce-code-review/SKILL.md")
      write_file("#{home}/.claude/plugins/cache/mp/pr-review-toolkit/1.0/skills/review-pr/SKILL.md")

      out = StringIO.new
      cfg = cfg_with_reviewers([
        { "name" => "claude-ce-code-review", "kind" => "agent",
          "agent" => "claude", "skill" => "ce-code-review" },
        { "name" => "pr-review-toolkit", "kind" => "agent",
          "agent" => "claude", "skill" => "pr-review-toolkit:review-pr" }
      ])
      exit_code = Hive::Commands::Doctor.new(config: cfg, project_root: nil, output: out).call

      assert_equal 0, exit_code
      assert_match(%r{6-review/claude-ce-code-review.*✓ present}, out.string)
      assert_match(%r{6-review/pr-review-toolkit.*✓ present}, out.string)
    end
  end

  def test_review_reviewers_one_missing_exits_65
    with_fake_home do |home|
      install_brainstorm_and_plan_skills(home)
      # ce-code-review present, pr-review-toolkit:review-pr absent.
      write_file("#{home}/.claude/skills/ce-code-review/SKILL.md")

      out = StringIO.new
      cfg = cfg_with_reviewers([
        { "name" => "claude-ce-code-review", "kind" => "agent",
          "agent" => "claude", "skill" => "ce-code-review" },
        { "name" => "pr-review-toolkit", "kind" => "agent",
          "agent" => "claude", "skill" => "pr-review-toolkit:review-pr" }
      ])
      exit_code = Hive::Commands::Doctor.new(config: cfg, project_root: nil, output: out).call

      assert_equal Hive::Commands::Doctor::EXIT_MISSING_SKILL, exit_code
      assert_match(%r{6-review/pr-review-toolkit.*✗ missing}, out.string)
      assert_match(%r{\[6-review/pr-review-toolkit/claude\]}, out.string,
        "install-hint footer must include the row label")
    end
  end

  def test_review_reviewers_mixed_agents
    with_fake_home do |home|
      install_brainstorm_and_plan_skills(home)
      write_file("#{home}/.claude/skills/ce-code-review/SKILL.md")
      write_file("#{home}/.codex/skills/ce-code-review/SKILL.md")

      out = StringIO.new
      cfg = cfg_with_reviewers([
        { "name" => "claude-ce-code-review", "kind" => "agent",
          "agent" => "claude", "skill" => "ce-code-review" },
        { "name" => "codex-ce-code-review", "kind" => "agent",
          "agent" => "codex", "skill" => "ce-code-review" }
      ])
      exit_code = Hive::Commands::Doctor.new(config: cfg, project_root: nil, output: out).call

      assert_equal 0, exit_code
      assert_match(%r{6-review/claude-ce-code-review.*claude.*✓ present}, out.string)
      assert_match(%r{6-review/codex-ce-code-review.*codex.*✓ present}, out.string)
    end
  end

  def test_review_reviewers_empty_or_nil_or_absent
    with_fake_home do |home|
      install_brainstorm_and_plan_skills(home)
      [
        cfg_with_reviewers([]),
        cfg_with_reviewers(nil),
        { "claude" => { "mode" => "headless" },
          "brainstorm" => { "agent" => "claude", "skill" => "/x" },
          "plan" => { "agent" => "claude", "skill" => "/x" } } # `review:` absent
      ].each do |cfg|
        out = StringIO.new
        exit_code = Hive::Commands::Doctor.new(config: cfg, project_root: nil, output: out).call
        assert_equal 0, exit_code,
          "empty/nil/absent reviewers must not fail (cfg shape: #{cfg.dig('review', 'reviewers').inspect})"
        refute_match(%r{6-review/}, out.string,
          "no reviewer rows should appear when reviewers list is empty/nil/absent")
      end
    end
  end

  def test_review_reviewers_non_agent_kind_is_not_applicable
    with_fake_home do |home|
      install_brainstorm_and_plan_skills(home)
      out = StringIO.new
      cfg = cfg_with_reviewers([
        { "name" => "weird-linter", "kind" => "linter",
          "agent" => "claude", "skill" => "doesnt-matter" }
      ])
      exit_code = Hive::Commands::Doctor.new(config: cfg, project_root: nil, output: out).call

      assert_equal 0, exit_code, "non-agent kind must not fail doctor"
      assert_match(%r{6-review/weird-linter.*✓ present}, out.string)
    end
  end

  def test_review_reviewers_pi_agent_resolves_via_real_skill_paths
    # Pi has a real skill model (~/.pi/agent/skills/, ~/.agents/skills/,
    # plus pi packages). With pi's `skill_syntax_format` =
    # `/skill:%{skill}`, the reviewer's bare `skill: ce-code-review`
    # formats to `/skill:ce-code-review` and the verifier probes pi's
    # discovery paths.
    with_fake_home do |home|
      install_brainstorm_and_plan_skills(home)
      write_file("#{home}/.pi/agent/skills/ce-code-review/SKILL.md")
      out = StringIO.new
      cfg = cfg_with_reviewers([
        { "name" => "pi-reviewer", "kind" => "agent",
          "agent" => "pi", "skill" => "ce-code-review" }
      ])
      exit_code = Hive::Commands::Doctor.new(config: cfg, project_root: nil, output: out).call

      assert_equal 0, exit_code
      assert_match(%r{6-review/pi-reviewer.*pi.*✓ present}, out.string)
    end
  end

  def test_review_reviewers_pi_agent_missing_when_skill_absent
    with_fake_home do |home|
      install_brainstorm_and_plan_skills(home)
      out = StringIO.new
      cfg = cfg_with_reviewers([
        { "name" => "pi-reviewer", "kind" => "agent",
          "agent" => "pi", "skill" => "ce-code-review" }
      ])
      exit_code = Hive::Commands::Doctor.new(config: cfg, project_root: nil, output: out).call

      assert_equal Hive::Commands::Doctor::EXIT_MISSING_SKILL, exit_code
      assert_match(%r{6-review/pi-reviewer.*pi.*✗ missing}, out.string)
      assert_match(/pi install/, out.string)
    end
  end

  def test_row_shape_includes_kind_label_name_for_reviewers
    with_fake_home do |home|
      install_brainstorm_and_plan_skills(home)
      write_file("#{home}/.claude/skills/ce-code-review/SKILL.md")
      out = StringIO.new
      cfg = cfg_with_reviewers([
        { "name" => "claude-ce-code-review", "kind" => "agent",
          "agent" => "claude", "skill" => "ce-code-review" }
      ])
      doctor = Hive::Commands::Doctor.new(config: cfg, project_root: nil, output: out)
      doctor.call

      assert_kind_of Array, doctor.rows
      stage_rows = doctor.rows.select { |r| r[:kind] == "managed_skill" && %w[brainstorm plan].include?(r[:stage]) }
      reviewer_rows = doctor.rows.select { |r| r[:kind] == "managed_skill" && r[:stage].start_with?("6-review/") }

      assert_equal 1, stage_rows.length
      assert_equal 1, reviewer_rows.length

      stage_rows.each do |r|
        assert_equal "brainstorm,plan", r[:label], "duplicate agent/capability uses retain both surfaces"
        refute r.key?(:name), "stage rows must NOT have :name"
        assert r[:skill].start_with?("/"), "stage rows store full invocation in :skill"
      end

      reviewer = reviewer_rows.first
      assert_equal "6-review/claude-ce-code-review", reviewer[:stage]
      assert_equal "6-review/claude-ce-code-review", reviewer[:label]
      assert_equal "claude-ce-code-review", reviewer[:name]
      assert_equal "/ce-code-review", reviewer[:skill],
        "reviewer :skill must be the full invocation, not the bare config name"
    end
  end

  def test_json_envelope_includes_kind_and_label_on_all_rows_and_name_on_reviewers
    with_fake_home do |home|
      install_brainstorm_and_plan_skills(home)
      write_file("#{home}/.claude/skills/ce-code-review/SKILL.md")
      out = StringIO.new
      cfg = cfg_with_reviewers([
        { "name" => "claude-ce-code-review", "kind" => "agent",
          "agent" => "claude", "skill" => "ce-code-review" }
      ])
      Hive::Commands::Doctor.new(config: cfg, project_root: nil, json: true, output: out).call

      env = JSON.parse(out.string)
      assert_equal "hive-doctor.v2", env["schema"]
      assert_equal 2, env["managed_skills"].length

      stage_entries = env["managed_skills"].select { |c| %w[brainstorm plan].include?(c["stage"]) }
      reviewer_entries = env["managed_skills"].select { |c| c["stage"].start_with?("6-review/") }
      assert_equal 1, stage_entries.length
      assert_equal 1, reviewer_entries.length

      stage_entries.each do |c|
        assert c.key?("label"), "every stage entry has :label"
        refute c.key?("name"), "stage entries must NOT have :name"
      end

      reviewer = reviewer_entries.first
      assert_equal "6-review/claude-ce-code-review", reviewer["label"]
      assert_equal "claude-ce-code-review", reviewer["name"]
      assert_equal "/ce-code-review", reviewer["skill"]
    end
  end

  def test_table_column_widths_handle_long_reviewer_labels
    with_fake_home do |home|
      install_brainstorm_and_plan_skills(home)
      long_name = "very-long-custom-reviewer-name-that-stretches-the-column"
      write_file("#{home}/.claude/skills/ce-code-review/SKILL.md")
      out = StringIO.new
      cfg = cfg_with_reviewers([
        { "name" => long_name, "kind" => "agent",
          "agent" => "claude", "skill" => "ce-code-review" }
      ])
      Hive::Commands::Doctor.new(config: cfg, project_root: nil, output: out).call

      assert_match(%r{6-review/#{Regexp.escape(long_name)}}, out.string)
      # Header still aligns: separator dashes match the longest label width.
      header_line = out.string.lines[0]
      separator_line = out.string.lines[1]
      assert_equal header_line.length, separator_line.length,
        "header and separator must be the same width even with long reviewer labels"
    end
  end

  def test_json_config_error_returns_config_exit_and_error_payload
    out = StringIO.new
    cfg = base_config("brainstorm" => { "agent" => "bogus", "skill" => "/x" })

    exit_code = Hive::Commands::Doctor.new(
      config: cfg,
      project_root: nil,
      json: true,
      output: out
    ).call

    assert_equal Hive::Commands::Doctor::EXIT_CONFIG_ERROR, exit_code
    payload = JSON.parse(out.string)
    assert_match(/unknown agent profile/, payload.fetch("error"))
  end

  def test_text_config_error_returns_config_exit_and_prefixed_message
    out = StringIO.new
    cfg = base_config("brainstorm" => { "agent" => "bogus", "skill" => "/x" })

    exit_code = Hive::Commands::Doctor.new(
      config: cfg,
      project_root: nil,
      output: out
    ).call

    assert_equal Hive::Commands::Doctor::EXIT_CONFIG_ERROR, exit_code
    assert_match(/hive doctor: unknown agent profile/, out.string)
  end

  def test_row_line_marks_version_too_old_and_unknown_statuses
    doctor = Hive::Commands::Doctor.new(config: base_config, project_root: nil)
    widths = { label: 5, agent: 6, skill: 2, status: 15 }

    old_line = doctor.send(:row_line, {
      label: "plan",
      agent: "claude",
      skill: "/x",
      status: "version_too_old"
    }, widths)
    unknown_line = doctor.send(:row_line, {
      label: "plan",
      agent: "claude",
      skill: "/x",
      status: "mystery"
    }, widths)

    assert_match(/✗ version_too_old/, old_line)
    assert_match(/\? mystery/, unknown_line)
  end
  def test_legacy_runtime_warning_reports_unreadable_config_yml
    with_fake_home do |home|
      install_brainstorm_and_plan_skills(home)
      with_tmp_dir do |project|
        FileUtils.mkdir_p(File.join(project, ".hive-state"))
        File.write(File.join(project, ".hive-state", "config.yml"), "brainstorm: [broken\n")
        out = StringIO.new
        cfg = base_config(
          "brainstorm" => { "agent" => "claude", "skill" => "/x" },
          "plan" => { "agent" => "claude", "skill" => "/x" }
        )

        exit_code = Hive::Commands::Doctor.new(config: cfg, project_root: project, output: out).call

        assert_equal 0, exit_code
        assert_match(/could not parse \.hive-state\/config\.yml/, out.string)
      end
    end
  end

  def test_legacy_runtime_probe_ignores_invalid_yaml_when_called_directly
    with_tmp_dir do |project|
      FileUtils.mkdir_p(File.join(project, ".hive-state"))
      File.write(File.join(project, ".hive-state", "config.yml"), "brainstorm: [broken\n")
      doctor = Hive::Commands::Doctor.new(config: base_config, project_root: project)

      refute doctor.send(:legacy_brainstorm_runtime_present?)
    end
  end

  def test_v2_managed_health_reports_unavailable_as_non_blocking_and_exact_remediation
    unavailable_target = Hive::AgentSkills::Target.new(
      surfaces: [ "brainstorm" ], kind: "stage", agent: "claude",
      configured_skill: "/ce-brainstorm", invocation: "/ce-brainstorm",
      capability_id: "ce-brainstorm", package_id: "compound-engineering", managed: true
    )
    unavailable = Hive::AgentSkills::Inspection.new(
      target: unavailable_target,
      expected: { "package" => "compound-engineering@compound-engineering-plugin" },
      native: { "available" => false }, resolution: { "path" => nil },
      health: "unavailable", severity: "warning", explanation: "claude is absent",
      remediation: "hive setup-agents --agent claude --skill ce-brainstorm"
    )
    inspector = Struct.new(:rows) { def inspect = rows }.new([ unavailable ])
    out = StringIO.new

    exit_code = Hive::Commands::Doctor.new(
      config: base_config,
      project_root: nil,
      json: true,
      output: out,
      inspector: inspector
    ).call

    assert_equal 0, exit_code
    payload = JSON.parse(out.string)
    assert_equal "hive-doctor.v2", payload.fetch("schema")
    assert_equal 1, payload.dig("summary", "managed", "unavailable")
    assert_equal "hive setup-agents --agent claude --skill ce-brainstorm",
                 payload.dig("managed_skills", 0, "remediation")
  end

  def test_v2_conflict_is_actionable_and_preserves_winning_path_evidence
    target = Hive::AgentSkills::Target.new(
      surfaces: [ "plan" ], kind: "stage", agent: "claude",
      configured_skill: "/plan", invocation: "/plan",
      capability_id: "wiki-plan", package_id: "llm-wiki", managed: true
    )
    conflict = Hive::AgentSkills::Inspection.new(
      target: target, expected: { "package" => "llm-wiki@aikuznetsov-marketplace" },
      native: { "available" => true },
      resolution: { "path" => "/repo/.claude/commands/plan.md" },
      health: "conflicting", severity: "error",
      explanation: "user-owned alias /repo/.claude/commands/plan.md wins; Hive will not replace it",
      remediation: "hive setup-agents --agent claude --skill wiki-plan"
    )
    inspector = Struct.new(:rows) { def inspect = rows }.new([ conflict ])
    out = StringIO.new

    exit_code = Hive::Commands::Doctor.new(
      config: base_config, project_root: nil, output: out, inspector: inspector
    ).call

    assert_equal Hive::Commands::Doctor::EXIT_MISSING_SKILL, exit_code
    assert_includes out.string, "/repo/.claude/commands/plan.md"
    assert_includes out.string, "Hive will not replace it"
  end

  def test_doctor_requests_read_only_openclaw_evidence_from_default_inspector
    captured = nil
    fake = Struct.new(:rows) { def inspect = rows }.new([])
    replacement = lambda do |**kwargs|
      captured = kwargs
      fake
    end

    with_replaced_singleton_method(Hive::AgentSkills::Inspector, :new, replacement) do
      Hive::Commands::Doctor.new(
        config: base_config, project_root: nil, output: StringIO.new
      ).call
    end

    assert_equal true, captured.fetch(:include_openclaw)
    assert_equal false, captured.fetch(:native_commands)
  end

  def test_default_doctor_does_not_invoke_mutating_agent_inventory_commands
    with_tmp_dir do |home|
      bin_dir = File.join(home, "bin")
      FileUtils.mkdir_p(bin_dir)
      bins = %w[claude codex pi openclaw].to_h do |name|
        path = File.join(bin_dir, name)
        File.write(path, <<~SH)
          #!/bin/sh
          printf '%s\n' #{name} > #{File.join(home, "native-command-ran")}
          exit 0
        SH
        FileUtils.chmod(0o700, path)
        [ name, path ]
      end
      marker = File.join(home, "native-command-ran")
      cfg = Marshal.load(Marshal.dump(Hive::Config::DEFAULTS))
      %w[claude codex pi].each { |agent| cfg.fetch("agents").fetch(agent)["bin"] = bins.fetch(agent) }
      snapshot = lambda do
        Dir.glob(File.join(home, "**", "*"), File::FNM_DOTMATCH).sort.to_h do |path|
          next [ path, [ "directory", File.stat(path).mode & 0o777 ] ] if File.directory?(path)

          [ path, [ "file", File.stat(path).mode & 0o777, Digest::SHA256.file(path).hexdigest ] ]
        end
      end
      before = snapshot.call

      exit_code = Hive::Commands::Doctor.new(
        config: cfg,
        project_root: nil,
        json: true,
        output: StringIO.new,
        environment: {
          "HOME" => home,
          "PATH" => bin_dir,
          "CLAUDE_CONFIG_DIR" => File.join(home, "claude"),
          "CODEX_HOME" => File.join(home, "codex"),
          "PI_CODING_AGENT_DIR" => File.join(home, "pi"),
          "OPENCLAW_BIN" => bins.fetch("openclaw"),
          "OPENCLAW_STATE_DIR" => File.join(home, "openclaw")
        }
      ).call

      assert_equal Hive::Commands::Doctor::EXIT_MISSING_SKILL, exit_code
      refute File.exist?(marker)
      assert_equal before, snapshot.call
    end
  end

  def test_openclaw_drift_is_actionable_but_never_setup_managed
    target = Hive::AgentSkills::Target.new(
      surfaces: [ "hive.operations" ], kind: "openclaw", agent: "openclaw",
      configured_skill: "hive", invocation: "/hive", capability_id: "hive",
      package_id: "hive-operations", managed: false
    )
    row = Hive::AgentSkills::Inspection.new(
      target: target,
      expected: { "distribution" => "clawhub", "version" => "0.1.2" },
      native: { "available" => true, "clawhub" => { "installedVersion" => "0.1.1" } },
      resolution: { "path" => "/home/me/.openclaw/workspace/skills/hive-cli/SKILL.md" },
      health: "stale", severity: "warning", explanation: "ClawHub Hive skill is stale",
      remediation: "openclaw skills update @ivankuznetsov/hive-cli"
    )
    inspector = Struct.new(:rows) { def inspect = rows }.new([ row ])
    output = StringIO.new

    exit_code = Hive::Commands::Doctor.new(
      config: base_config, project_root: nil, output: output, inspector: inspector
    ).call

    assert_equal Hive::Commands::Doctor::EXIT_MISSING_SKILL, exit_code
    assert_includes output.string, "openclaw skills update @ivankuznetsov/hive-cli"
    refute row.managed
  end

  def test_private_dependency_and_rendering_boundaries
    with_tmp_dir do |dir|
      executable = File.join(dir, "qmd")
      File.write(executable, "#!/bin/sh\n")
      FileUtils.chmod(0o755, executable)
      doctor = Hive::Commands::Doctor.new(config: base_config, project_root: dir, output: StringIO.new)
      with_env("PATH" => dir) do
        assert_equal executable, doctor.send(:which, "qmd")
      end

      state = File.join(dir, ".hive-state")
      FileUtils.mkdir_p(state)
      File.write(File.join(state, "config.yml"), "brainstorm:\n  runtime: tmux\n")
      assert doctor.send(:legacy_brainstorm_runtime_present?)

      clean = Hive::Commands::Doctor.new(config: base_config, project_root: dir, output: StringIO.new)
      refute clean.send(:config_yml_unreadable?)

      widths = { label: 12, agent: 8, skill: 16, status: 16 }
      %w[stale incompatible unavailable not_applicable].each do |status|
        rendered = doctor.send(
          :row_line,
          { kind: status == "not_applicable" ? "dependency" : "managed_skill",
            label: "row", agent: "agent", skill: "/skill", status: status },
          widths
        )
        assert_includes rendered, status
      end
    end
  end
end
