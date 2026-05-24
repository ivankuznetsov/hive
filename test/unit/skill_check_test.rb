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

  def test_malformed_invocation_returns_missing_with_argument_error
    status, msg = Hive::SkillCheck::Codex.verify("garbage")

    assert_equal :missing, status
    assert_match(/expected/, msg)
  end
end

class HiveSkillCheckPiTest < Minitest::Test
  include HiveTestHelper

  def with_fake_home
    with_tmp_dir do |dir|
      old = ENV["HOME"]
      original_global_npm_root = Hive::SkillCheck::Pi.method(:global_npm_root)
      ENV["HOME"] = dir
      Hive::SkillCheck::Pi.define_singleton_method(:global_npm_root) { nil }
      yield dir
    ensure
      old.nil? ? ENV.delete("HOME") : ENV["HOME"] = old
      Hive::SkillCheck::Pi.define_singleton_method(:global_npm_root) do
        original_global_npm_root.call
      end
    end
  end

  def with_pi_global_npm_root(root)
    original = Hive::SkillCheck::Pi.method(:global_npm_root)
    Hive::SkillCheck::Pi.define_singleton_method(:global_npm_root) { root }
    yield
  ensure
    Hive::SkillCheck::Pi.define_singleton_method(:global_npm_root) do
      original.call
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

  def test_present_via_pi_package_npm_root_g
    with_fake_home do |_home|
      with_tmp_dir do |npm_root|
        with_pi_global_npm_root(npm_root) do
          write_file("#{npm_root}/some-package/skills/foo/SKILL.md")
          status, msg = Hive::SkillCheck::Pi.verify("/skill:foo")
          assert_equal :present, status
          assert_equal "#{npm_root}/some-package/skills/foo/SKILL.md", msg
        end
      end
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

  def test_present_via_project_pi_settings_package_path
    with_fake_home do |_home|
      with_tmp_dir do |project|
        write_file("#{project}/.pi/settings.json", '{"packages":["../local-package"]}')
        write_file("#{project}/local-package/skills/foo/SKILL.md")
        status, msg = Hive::SkillCheck::Pi.verify("/skill:foo", project_root: project)
        assert_equal :present, status
        assert_equal "#{project}/local-package/skills/foo/SKILL.md", msg
      end
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

  def test_missing_hint_summarizes_parse_errors
    inv = Hive::SkillCheck::Invocation.new(plugin: "skill", name: "foo")

    msg = Hive::SkillCheck::Pi.install_hint(inv, parse_errors: [ "one", "two", "three", "four" ])

    assert_match(/failed to parse 4 settings\/manifest file/, msg)
    assert_match(/one; two; three/, msg)
    assert_match(/\(and 1 more\)/, msg)
  end

  def test_global_npm_root_returns_nil_on_timeout
    with_replaced_singleton_method(Timeout, :timeout, ->(_seconds) { raise Timeout::Error }) do
      assert_nil Hive::SkillCheck::Pi.global_npm_root
    end
  end

  def test_manifest_skill_candidates_expands_jailed_globs
    with_tmp_dir do |package_root|
      write_file("#{package_root}/package.json", '{"pi":{"skills":["custom-*"]}}')
      write_file("#{package_root}/custom-one/foo/SKILL.md")

      paths = Hive::SkillCheck::Pi.manifest_skill_candidates(package_root, "foo")

      assert_includes paths, "#{package_root}/custom-one/foo/SKILL.md"
    end
  end

  def test_jail_path_rejects_paths_outside_all_roots
    assert_nil Hive::SkillCheck::Pi.jail_path("/tmp/outside", [ "/var/hive" ])
  end

  def test_path_candidates_for_markdown_uses_frontmatter_name
    with_tmp_dir do |dir|
      named = File.join(dir, "custom.md")
      plain = File.join(dir, "plain.md")
      write_file(named, "---\nname: foo\n---\nbody\n")
      write_file(plain, "body\n")

      assert_equal [ named ], Hive::SkillCheck::Pi.path_candidates(named, "foo", include_root_md: true)
      assert_equal [], Hive::SkillCheck::Pi.path_candidates(named, "bar", include_root_md: true)
      assert_equal [], Hive::SkillCheck::Pi.path_candidates(plain, "foo", include_root_md: true)
      assert_equal [], Hive::SkillCheck::Pi.path_candidates(File.join(dir, "missing.md"), "foo", include_root_md: true)
    end
  end

  def test_absolute_or_relative_path_expands_home_absolute_and_relative_forms
    with_tmp_dir do |base|
      home = File.join(base, "home")

      assert_equal home, Hive::SkillCheck::Pi.absolute_or_relative_path("~", base, home: home)
      assert_equal File.join(home, "skills"), Hive::SkillCheck::Pi.absolute_or_relative_path("~/skills", base, home: home)
      assert_equal "/var/tmp", Hive::SkillCheck::Pi.absolute_or_relative_path("/var/tmp", base, home: home)
      assert_equal File.join(base, "local"), Hive::SkillCheck::Pi.absolute_or_relative_path("local", base, home: home)
    end
  end

  def test_skill_file_matches_handles_read_errors
    with_tmp_dir do |dir|
      path = File.join(dir, "custom.md")

      with_replaced_singleton_method(File, :file?, ->(_path) { true }) do
        with_replaced_singleton_method(File, :read, ->(_path, _bytes) { raise Errno::EACCES }) do
          refute Hive::SkillCheck::Pi.skill_file_matches?(path, "foo")
        end
      end
    end
  end

  def test_read_json_records_parse_errors_and_swallows_read_failures
    with_tmp_dir do |dir|
      path = File.join(dir, "settings.json")
      write_file(path, "{")
      errors = []

      assert_nil Hive::SkillCheck::Pi.read_json(path, errors: errors)
      assert_equal 1, errors.size
      assert_match(/settings\.json:/, errors.first)

      with_replaced_singleton_method(File, :file?, ->(_path) { true }) do
        with_replaced_singleton_method(File, :read, ->(_path) { raise Errno::EACCES }) do
          assert_nil Hive::SkillCheck::Pi.read_json(File.join(dir, "blocked.json"), errors: errors)
        end
      end
    end
  end

  def test_returns_missing_for_garbage_invocation
    status, msg = Hive::SkillCheck::Pi.verify("garbage")
    assert_equal :missing, status
    assert_match(/expected/, msg, "malformed invocation surfaces parse error")
  end
end
