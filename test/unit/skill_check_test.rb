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
      assert_match(/installed plugin/, msg, "hint mentions plugin fallback path")
    end
  end

  def test_present_via_plugin_cache_for_bare_invocation
    # Claude resolves `/foo` against any installed plugin's skill
    # named `foo` (in addition to user-level commands/skills). A user
    # who ran `claude plugin install some-marketplace` to bring in
    # `compound-engineering` and writes `skill: ce-code-review` in
    # config expects `/ce-code-review` to resolve against the plugin
    # — even though there's no explicit `<plugin>:` prefix.
    with_fake_home do |home|
      write_file("#{home}/.claude/plugins/cache/every-marketplace/compound-engineering/3.0.1/skills/ce-code-review/SKILL.md")
      status, msg = Hive::SkillCheck::Claude.verify("/ce-code-review")
      assert_equal :present, status
      assert_match(%r{cache/every-marketplace/compound-engineering/3\.0\.1/skills/ce-code-review/SKILL.md\z}, msg)
    end
  end

  def test_present_via_plugin_marketplace_source_for_bare_invocation
    with_fake_home do |home|
      write_file("#{home}/.claude/plugins/marketplaces/some-mp/plugins/compound-engineering/skills/ce-code-review/SKILL.md")
      status, msg = Hive::SkillCheck::Claude.verify("/ce-code-review")
      assert_equal :present, status
      assert_match(%r{plugins/compound-engineering/skills/ce-code-review/SKILL.md\z}, msg)
    end
  end

  def test_user_level_command_takes_precedence_over_plugin_fallback
    with_fake_home do |home|
      write_file("#{home}/.claude/commands/ce-code-review.md", "user")
      write_file("#{home}/.claude/plugins/cache/mp/foo/1.0/skills/ce-code-review/SKILL.md", "plugin")
      status, msg = Hive::SkillCheck::Claude.verify("/ce-code-review")
      assert_equal :present, status
      assert_match(%r{commands/ce-code-review\.md\z}, msg,
        "user-level command must beat the plugin-fallback path")
    end
  end

  def test_glob_metacharacters_do_not_match_claude_plugin_fallback
    with_fake_home do |home|
      write_file("#{home}/.claude/plugins/cache/mp/foo/1.0/skills/foobar/SKILL.md")
      status, msg = Hive::SkillCheck::Claude.verify("/foo*")
      assert_equal :missing, status
      assert_match(/foo\*/, msg)
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
      assert_match(/install a plugin that ships it/, msg, "hint mentions plugin fallback path")
    end
  end

  def test_codex_present_via_plugin_cache_for_bare_invocation
    with_fake_home do |home|
      write_file("#{home}/.codex/plugins/cache/some-mp/compound-engineering/3.7.0/skills/ce-code-review/SKILL.md")
      status, msg = Hive::SkillCheck::Codex.verify("/ce-code-review")
      assert_equal :present, status
      assert_match(%r{compound-engineering/3\.7\.0/skills/ce-code-review/SKILL.md\z}, msg)
    end
  end

  def test_glob_metacharacters_do_not_match_codex_plugin_fallback
    with_fake_home do |home|
      write_file("#{home}/.codex/plugins/cache/some-mp/pkg/1.0/skills/foobar/SKILL.md")
      status, msg = Hive::SkillCheck::Codex.verify("/foo*")
      assert_equal :missing, status
      assert_match(/foo\*/, msg)
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

  def test_present_via_user_pi_skills_directory
    with_fake_home do |home|
      write_file("#{home}/.pi/agent/skills/foo/SKILL.md")
      status, msg = Hive::SkillCheck::Pi.verify("/skill:foo")
      assert_equal :present, status
      assert_equal "#{home}/.pi/agent/skills/foo/SKILL.md", msg
    end
  end

  def test_present_via_user_pi_recursive_skills_directory
    with_fake_home do |home|
      write_file("#{home}/.pi/agent/skills/pi-skills/foo/SKILL.md")
      status, msg = Hive::SkillCheck::Pi.verify("/skill:foo")
      assert_equal :present, status
      assert_equal "#{home}/.pi/agent/skills/pi-skills/foo/SKILL.md", msg
    end
  end

  def test_present_via_user_pi_root_markdown_skill
    with_fake_home do |home|
      write_file("#{home}/.pi/agent/skills/foo.md")
      status, msg = Hive::SkillCheck::Pi.verify("/skill:foo")
      assert_equal :present, status
      assert_equal "#{home}/.pi/agent/skills/foo.md", msg
    end
  end

  def test_present_via_cross_agent_skills_directory
    with_fake_home do |home|
      write_file("#{home}/.agents/skills/foo/SKILL.md")
      status, msg = Hive::SkillCheck::Pi.verify("/skill:foo")
      assert_equal :present, status
      assert_equal "#{home}/.agents/skills/foo/SKILL.md", msg
    end
  end

  def test_present_via_project_pi_skills_directory
    with_fake_home do |_home|
      with_tmp_dir do |project|
        write_file("#{project}/.pi/skills/foo/SKILL.md")
        status, msg = Hive::SkillCheck::Pi.verify("/skill:foo", project_root: project)
        assert_equal :present, status
        assert_equal "#{project}/.pi/skills/foo/SKILL.md", msg
      end
    end
  end

  def test_present_via_project_pi_root_markdown_skill
    with_fake_home do |_home|
      with_tmp_dir do |project|
        write_file("#{project}/.pi/skills/foo.md")
        status, msg = Hive::SkillCheck::Pi.verify("/skill:foo", project_root: project)
        assert_equal :present, status
        assert_equal "#{project}/.pi/skills/foo.md", msg
      end
    end
  end

  def test_present_via_project_cross_agent_skills_directory
    with_fake_home do |_home|
      with_tmp_dir do |project|
        write_file("#{project}/.agents/skills/foo/SKILL.md")
        status, msg = Hive::SkillCheck::Pi.verify("/skill:foo", project_root: project)
        assert_equal :present, status
        assert_match(%r{\.agents/skills/foo/SKILL.md\z}, msg)
      end
    end
  end

  def test_present_via_ancestor_project_cross_agent_skills_directory
    with_fake_home do |_home|
      with_tmp_dir do |project|
        FileUtils.mkdir_p("#{project}/.git")
        nested = File.join(project, "nested")
        FileUtils.mkdir_p(nested)
        write_file("#{project}/.agents/skills/foo/SKILL.md")
        status, msg = Hive::SkillCheck::Pi.verify("/skill:foo", project_root: nested)
        assert_equal :present, status
        assert_equal "#{project}/.agents/skills/foo/SKILL.md", msg
      end
    end
  end

  def test_present_via_pi_package_global_npm_root
    with_fake_home do |home|
      write_file("#{home}/.pi/npm/node_modules/some-package/skills/foo/SKILL.md")
      status, msg = Hive::SkillCheck::Pi.verify("/skill:foo")
      assert_equal :present, status
      assert_match(%r{\.pi/npm/node_modules/some-package/skills/foo/SKILL.md\z}, msg)
    end
  end

  def test_present_via_pi_package_git_root
    with_fake_home do |home|
      write_file("#{home}/.pi/agent/git/github.com/user/repo/skills/foo/SKILL.md")
      status, msg = Hive::SkillCheck::Pi.verify("/skill:foo")
      assert_equal :present, status
      assert_match(%r{\.pi/agent/git/github\.com/user/repo/skills/foo/SKILL.md\z}, msg)
    end
  end

  def test_present_via_pi_package_manifest_skill_path
    with_fake_home do |home|
      package_root = "#{home}/.pi/agent/git/github.com/user/repo"
      write_file("#{package_root}/package.json", '{"pi":{"skills":["custom-skills"]}}')
      write_file("#{package_root}/custom-skills/foo/SKILL.md")
      status, msg = Hive::SkillCheck::Pi.verify("/skill:foo")
      assert_equal :present, status
      assert_match(%r{custom-skills/foo/SKILL.md\z}, msg)
    end
  end

  def test_present_via_pi_settings_skill_path
    with_fake_home do |home|
      write_file("#{home}/.pi/agent/settings.json", '{"skills":["./extra-skills"]}')
      write_file("#{home}/.pi/agent/extra-skills/foo/SKILL.md")
      status, msg = Hive::SkillCheck::Pi.verify("/skill:foo")
      assert_equal :present, status
      assert_match(%r{\.pi/agent/extra-skills/foo/SKILL.md\z}, msg)
    end
  end

  def test_glob_metacharacters_do_not_match_pi_skill_fallback
    with_fake_home do |home|
      write_file("#{home}/.pi/agent/skills/foobar/SKILL.md")
      status, msg = Hive::SkillCheck::Pi.verify("/skill:foo*")
      assert_equal :missing, status
      assert_match(/foo\*/, msg)
    end
  end

  def test_missing_returns_install_hint
    with_fake_home do |_home|
      status, msg = Hive::SkillCheck::Pi.verify("/skill:nonexistent")
      assert_equal :missing, status
      assert_match(/pi install/, msg, "hint mentions `pi install`")
      assert_match(/skills\//, msg, "hint references discovery paths")
    end
  end

  def test_returns_not_applicable_for_non_skill_invocation_form
    # Pi distinguishes: skills are `/skill:<name>`, extension commands
    # are `/<name>`, prompt templates are `/<templatename>`. Hive's
    # reviewer/stage prompts are skill invocations, so `/foo` (without
    # `skill:` prefix) cannot resolve as a skill on pi. Surface that
    # via `:not_applicable` rather than fabricating a present/missing
    # answer.
    [ "/foo", "/compound-engineering:ce-plan" ].each do |inv|
      status, msg = Hive::SkillCheck::Pi.verify(inv)
      assert_equal :not_applicable, status, "pi must report N/A for #{inv} (wrong form)"
      assert_match(/`\/skill:<name>`/, msg)
    end
  end

  def test_returns_missing_for_garbage_invocation
    status, msg = Hive::SkillCheck::Pi.verify("garbage")
    assert_equal :missing, status
    assert_match(/expected/, msg, "malformed invocation surfaces parse error")
  end
end
