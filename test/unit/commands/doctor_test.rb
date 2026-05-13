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

  def test_pi_stage_uses_profile_skill_format_and_resolves
    with_fake_home do |home|
      write_file("#{home}/.pi/agent/skills/ce-brainstorm/SKILL.md")
      write_file("#{home}/.pi/agent/skills/plan/SKILL.md")
      out = StringIO.new
      cfg = {
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
      assert_match(%r{plan.*pi.*/skill:plan.*✓ present}, out.string)
    end
  end

  def test_pi_stage_missing_when_formatted_skill_absent
    with_fake_home do |home|
      write_file("#{home}/.pi/agent/skills/ce-brainstorm/SKILL.md")
      out = StringIO.new
      cfg = {
        "brainstorm" => { "agent" => "pi" },
        "plan" => { "agent" => "pi" }
      }
      exit_code = Hive::Commands::Doctor.new(
        config: cfg,
        project_root: nil,
        output: out
      ).call
      assert_equal Hive::Commands::Doctor::EXIT_MISSING_SKILL, exit_code
      assert_match(%r{plan.*pi.*/skill:plan.*✗ missing}, out.string)
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
    with_fake_home do |home|
      # No user-level claude /plan, but project-level present.
      with_tmp_dir do |project|
        write_file("#{home}/.claude/commands/x.md")
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

  # ---- Review.reviewers extension (U1/U2/U3) ----

  def cfg_with_reviewers(reviewers)
    {
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
        { "brainstorm" => { "agent" => "claude", "skill" => "/x" },
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
      assert_match(%r{6-review/weird-linter.*— not_applicable}, out.string)
      assert_match(/kind 'linter' is not 'agent'/, out.string)
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
      stage_rows = doctor.rows.select { |r| r[:kind] == "stage" }
      reviewer_rows = doctor.rows.select { |r| r[:kind] == "reviewer" }

      assert_equal 2, stage_rows.length
      assert_equal 1, reviewer_rows.length

      stage_rows.each do |r|
        assert_equal r[:stage], r[:label], "stage rows: :label equals :stage"
        refute r.key?(:name), "stage rows must NOT have :name"
        assert r[:skill].start_with?("/"), "stage rows store full invocation in :skill"
      end

      reviewer = reviewer_rows.first
      assert_equal "6-review", reviewer[:stage]
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
      assert_equal "hive-doctor.v1", env["schema"]
      assert_equal 3, env["checks"].length

      stage_entries = env["checks"].select { |c| c["kind"] == "stage" }
      reviewer_entries = env["checks"].select { |c| c["kind"] == "reviewer" }
      assert_equal 2, stage_entries.length
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
end
