require "test_helper"
require "hive/skill_check"
require "fileutils"

class HiveSkillCheckParseTest < Minitest::Test
  def test_parses_plain_invocation
    inv = Hive::SkillCheck.parse("/plan")
    assert_nil inv.plugin
    assert_equal "plan", inv.name
  end

  def test_parses_plugin_namespaced_invocation
    inv = Hive::SkillCheck.parse("/compound-engineering:ce-plan")
    assert_equal "compound-engineering", inv.plugin
    assert_equal "ce-plan", inv.name
  end

  def test_rejects_nil
    assert_raises(ArgumentError) { Hive::SkillCheck.parse(nil) }
  end

  def test_rejects_missing_leading_slash
    assert_raises(ArgumentError) { Hive::SkillCheck.parse("plan") }
  end

  def test_rejects_empty_name
    assert_raises(ArgumentError) { Hive::SkillCheck.parse("/") }
    assert_raises(ArgumentError) { Hive::SkillCheck.parse("/plug:") }
  end

  def test_rejects_whitespace
    assert_raises(ArgumentError) { Hive::SkillCheck.parse("/foo bar") }
  end
end

class HiveSkillCheckClaudeTest < Minitest::Test
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

  def test_present_via_user_command_directory
    with_fake_home do |home|
      write_file("#{home}/.claude/commands/plan.md")
      status, msg = Hive::SkillCheck::Claude.verify("/plan")
      assert_equal :present, status
      assert_equal "#{home}/.claude/commands/plan.md", msg
    end
  end

  def test_present_via_user_skill_directory
    with_fake_home do |home|
      write_file("#{home}/.claude/skills/wiki-researcher/SKILL.md")
      status, msg = Hive::SkillCheck::Claude.verify("/wiki-researcher")
      assert_equal :present, status
      assert_equal "#{home}/.claude/skills/wiki-researcher/SKILL.md", msg
    end
  end

  def test_present_via_project_command_directory_takes_precedence
    with_fake_home do |home|
      write_file("#{home}/.claude/commands/plan.md", "user")
      with_tmp_dir do |project|
        write_file("#{project}/.claude/commands/plan.md", "project")
        status, msg = Hive::SkillCheck::Claude.verify("/plan", project_root: project)
        assert_equal :present, status
        assert_equal "#{project}/.claude/commands/plan.md", msg,
          "project-level path must beat the user-level one"
      end
    end
  end

  def test_present_via_plugin_cache_layout
    with_fake_home do |home|
      write_file("#{home}/.claude/plugins/cache/every-marketplace/compound-engineering/3.0.1/skills/ce-plan/SKILL.md")
      status, msg = Hive::SkillCheck::Claude.verify("/compound-engineering:ce-plan")
      assert_equal :present, status
      assert_match(%r{cache/every-marketplace/compound-engineering/3.0.1/skills/ce-plan/SKILL.md\z}, msg)
    end
  end

  def test_present_via_plugin_marketplace_source_layout
    with_fake_home do |home|
      write_file("#{home}/.claude/plugins/marketplaces/some-mp/plugins/compound-engineering/skills/ce-brainstorm/SKILL.md")
      status, msg = Hive::SkillCheck::Claude.verify("/compound-engineering:ce-brainstorm")
      assert_equal :present, status
      assert_match(%r{plugins/compound-engineering/skills/ce-brainstorm/SKILL.md\z}, msg)
    end
  end

  def test_missing_returns_install_hint_for_plain_invocation
    with_fake_home do |_home|
      status, msg = Hive::SkillCheck::Claude.verify("/nonexistent-skill")
      assert_equal :missing, status
      assert_match(/not found under ~\/\.claude\/\{commands,skills\}/, msg)
    end
  end

  def test_missing_returns_install_hint_for_plugin_invocation
    with_fake_home do |_home|
      status, msg = Hive::SkillCheck::Claude.verify("/no-such-plug:no-such-skill")
      assert_equal :missing, status
      assert_match(/claude plugin install/, msg)
    end
  end

  def test_malformed_invocation_returns_missing_with_argument_error
    with_fake_home do |_home|
      status, msg = Hive::SkillCheck::Claude.verify("garbage")
      assert_equal :missing, status
      assert_match(/expected/, msg)
    end
  end
end

class HiveSkillCheckCodexTest < Minitest::Test
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

  def test_present_via_user_skill
    with_fake_home do |home|
      write_file("#{home}/.codex/skills/plan/SKILL.md")
      status, msg = Hive::SkillCheck::Codex.verify("/plan")
      assert_equal :present, status
      assert_equal "#{home}/.codex/skills/plan/SKILL.md", msg
    end
  end

  def test_present_via_system_skill
    with_fake_home do |home|
      write_file("#{home}/.codex/skills/.system/imagegen/SKILL.md")
      status, msg = Hive::SkillCheck::Codex.verify("/imagegen")
      assert_equal :present, status
      assert_match(%r{\.system/imagegen/SKILL.md\z}, msg)
    end
  end

  def test_present_via_plugin_cache
    with_fake_home do |home|
      write_file("#{home}/.codex/plugins/cache/compound-engineering-plugin/compound-engineering/3.6.1/skills/ce-plan/SKILL.md")
      status, msg = Hive::SkillCheck::Codex.verify("/compound-engineering:ce-plan")
      assert_equal :present, status
      assert_match(%r{compound-engineering/3.6.1/skills/ce-plan/SKILL.md\z}, msg)
    end
  end

  def test_missing_plain_invocation_with_codex_specific_hint
    with_fake_home do |_home|
      status, msg = Hive::SkillCheck::Codex.verify("/no-such-skill")
      assert_equal :missing, status
      assert_match(/no user-level slash-command directory/, msg)
    end
  end

  def test_missing_plugin_invocation_with_install_hint
    with_fake_home do |_home|
      status, msg = Hive::SkillCheck::Codex.verify("/missing-plug:missing-name")
      assert_equal :missing, status
      assert_match(/codex plugin install/, msg)
    end
  end
end

class HiveSkillCheckPiTest < Minitest::Test
  def test_returns_not_applicable_for_any_invocation
    [ "/plan", "/compound-engineering:ce-plan", "/foo" ].each do |inv|
      status, msg = Hive::SkillCheck::Pi.verify(inv)
      assert_equal :not_applicable, status, "pi must report N/A for #{inv}"
      assert_match(/no slash-command resolver/, msg)
    end
  end

  def test_returns_not_applicable_even_for_garbage_invocation
    # Pi's check is honest: it doesn't even parse the invocation
    # because no parsing can change the answer (pi sends prompt
    # text verbatim regardless).
    status, _msg = Hive::SkillCheck::Pi.verify("not-an-invocation")
    assert_equal :not_applicable, status
  end
end
