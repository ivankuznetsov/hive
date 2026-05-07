require "test_helper"
require "stringio"
require "fileutils"
require "json"
require "hive/commands/doctor"

class HiveCommandsDoctorTest < Minitest::Test
  include HiveTestHelper

  def with_fake_home
    with_tmp_dir do |dir|
      old = ENV["HOME"]
      ENV["HOME"] = dir
      yield dir
    ensure
      old.nil? ? ENV.delete("HOME") : ENV["HOME"] = old
    end
  end

  def write_file(path, content = "")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def base_config(overrides = {})
    {
      "brainstorm" => { "agent" => "claude" },
      "plan" => { "agent" => "claude" }
    }.merge(overrides) { |_k, a, b| a.merge(b) }
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

  def test_pi_stage_is_not_applicable_and_does_not_fail
    with_fake_home do |_home|
      out = StringIO.new
      cfg = {
        "brainstorm" => { "agent" => "pi", "skill" => "/anything" },
        "plan" => { "agent" => "pi", "skill" => "/anything" }
      }
      exit_code = Hive::Commands::Doctor.new(
        config: cfg,
        project_root: nil,
        output: out
      ).call
      assert_equal 0, exit_code, "pi-only configs must not fail doctor"
      assert_match(/— not_applicable/, out.string)
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
      assert_equal "hive-doctor.v1", env["schema"]
      assert_equal 2, env["checks"].length
      assert_equal 1, env["summary"]["missing"]
      assert_equal 1, env["summary"]["present"]
      assert(env["checks"].any? { |c| c["stage"] == "plan" && c["status"] == "present" })
      assert(env["checks"].any? { |c| c["stage"] == "brainstorm" && c["status"] == "missing" })
    end
  end

  def test_uses_config_defaults_when_skill_key_unset
    with_fake_home do |home|
      # No `skill:` key in config; doctor falls back to DEFAULTS
      # ("/compound-engineering:ce-brainstorm" and "/plan").
      write_file("#{home}/.claude/plugins/cache/mp/compound-engineering/3.0.1/skills/ce-brainstorm/SKILL.md")
      write_file("#{home}/.claude/commands/plan.md")
      out = StringIO.new
      cfg = {
        "brainstorm" => { "agent" => "claude" },
        "plan" => { "agent" => "claude" }
      }
      exit_code = Hive::Commands::Doctor.new(
        config: cfg,
        project_root: nil,
        output: out
      ).call
      assert_equal 0, exit_code
      assert_match(%r{/compound-engineering:ce-brainstorm}, out.string)
      assert_match(%r{/plan}, out.string)
    end
  end

  def test_project_root_affects_claude_plain_invocation_resolution
    with_fake_home do |_home|
      # No user-level claude /plan, but project-level present.
      with_tmp_dir do |project|
        write_file("#{project}/.claude/commands/plan.md")
        out = StringIO.new
        cfg = base_config(
          "brainstorm" => { "agent" => "pi", "skill" => "/x" }, # parked: pi → N/A
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
end
