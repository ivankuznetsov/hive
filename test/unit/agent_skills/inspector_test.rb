require "test_helper"
require "hive/agent_skills"
require "hive/agent_skills/inspector"

class AgentSkillsInspectorTest < Minitest::Test
  include HiveTestHelper

  class FakeRunner
    attr_reader :calls

    def initialize(responses = {})
      @responses = responses
      @calls = []
    end

    def call(argv, env: {}, timeout: 10)
      @calls << { argv: argv, env: env, timeout: timeout }
      response = @responses.fetch(argv) do
        Hive::AgentSkills::CommandResult.new(stdout: "", stderr: "unexpected argv", exit_status: 127,
                                              error: nil, timed_out: false)
      end
      response.respond_to?(:call) ? response.call(argv, env, timeout) : response
    end
  end

  def result(stdout: "", stderr: "", status: 0, error: nil, timed_out: false)
    Hive::AgentSkills::CommandResult.new(
      stdout: stdout, stderr: stderr, exit_status: status, error: error, timed_out: timed_out
    )
  end

  def executable(path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#!/bin/sh\nexit 0\n")
    FileUtils.chmod(0o755, path)
  end

  def write(path, content = "")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def config(agent: "claude", reviewers: [], browser: false, bin: nil)
    cfg = Marshal.load(Marshal.dump(Hive::Config::DEFAULTS))
    cfg["project_root"] = nil
    cfg["brainstorm"]["agent"] = agent
    cfg["plan"]["agent"] = agent
    cfg["review"]["reviewers"] = reviewers
    cfg["review"]["browser_test"]["enabled"] = browser
    cfg["review"]["browser_test"]["agent"] = agent
    cfg["agents"][agent]["bin"] = bin if bin
    cfg
  end

  def claude_responses(bin:, plugins:, marketplaces:, version: "2.1.179")
    {
      [ bin, "--version" ] => result(stdout: "#{version} (Claude Code)\n"),
      [ bin, "plugin", "list", "--json" ] => result(stdout: JSON.generate(plugins)),
      [ bin, "plugin", "marketplace", "list", "--json" ] => result(stdout: JSON.generate(marketplaces))
    }
  end

  def inspect_rows(cfg:, project:, runner:, environment: {})
    Hive::AgentSkills::Inspector.new(
      config: cfg,
      project_root: project,
      runner: runner,
      environment: { "HOME" => project, "PATH" => "" }.merge(environment)
    ).inspect
  end

  def test_target_resolver_derives_stages_reviewers_and_optional_browser_skill
    reviewer = { "name" => "codex-ce", "kind" => "agent", "agent" => "codex", "skill" => "ce-code-review" }
    cfg = config(reviewers: [ reviewer ], browser: true)
    resolver = Hive::AgentSkills::TargetResolver.new(config: cfg, project_root: "/tmp/project")

    targets = resolver.resolve

    assert_equal %w[ce-brainstorm wiki-plan ce-code-review ce-test-browser].sort,
                 targets.select(&:managed).map(&:capability_id).sort
    assert_equal "/ce-code-review", targets.find { |t| t.capability_id == "ce-code-review" }.invocation
  end

  def test_target_resolver_preserves_custom_reviewer_as_unmanaged
    reviewer = { "name" => "private", "kind" => "agent", "agent" => "claude", "skill" => "private-review" }
    target = Hive::AgentSkills::TargetResolver.new(
      config: config(reviewers: [ reviewer ]), project_root: "/tmp/project"
    ).resolve.find { |row| row.configured_skill == "private-review" }

    refute target.managed
    assert_nil target.capability_id
  end

  def test_healthy_inventory_and_expected_resolver_path
    with_tmp_dir do |dir|
      bin = File.join(dir, "bin", "claude")
      executable(bin)
      install = File.join(dir, "claude", "plugins", "cache", "compound-engineering-plugin", "compound-engineering", "3.19.0")
      write(File.join(install, "skills", "ce-brainstorm", "SKILL.md"))
      responses = claude_responses(
        bin: bin,
        plugins: [ { "id" => "compound-engineering@compound-engineering-plugin", "version" => "3.19.0", "enabled" => true, "installPath" => install } ],
        marketplaces: [ { "name" => "compound-engineering-plugin", "repo" => "EveryInc/compound-engineering-plugin" } ]
      )
      cfg = config(bin: bin)
      cfg["plan"]["skill"] = "/ce-brainstorm"

      rows = inspect_rows(cfg: cfg, project: dir, runner: FakeRunner.new(responses),
                          environment: { "CLAUDE_CONFIG_DIR" => File.join(dir, "claude") })
      row = rows.find { |entry| entry.capability_id == "ce-brainstorm" }

      assert_equal "healthy", row.health
      assert_equal File.join(install, "skills", "ce-brainstorm", "SKILL.md"), row.resolution.fetch("path")
      assert_equal "3.19.0", row.native.fetch("package").fetch("version")
    end
  end

  def test_missing_inventory_and_resolution_is_missing
    with_tmp_dir do |dir|
      bin = File.join(dir, "claude")
      executable(bin)
      runner = FakeRunner.new(claude_responses(bin: bin, plugins: [], marketplaces: []))
      row = inspect_rows(cfg: config(bin: bin), project: dir, runner: runner).find { |r| r.capability_id == "ce-brainstorm" }

      assert_equal "missing", row.health
      assert_match(/not installed/, row.explanation)
    end
  end

  def test_older_package_is_stale_and_unsupported_major_is_incompatible
    with_tmp_dir do |dir|
      bin = File.join(dir, "claude")
      executable(bin)
      %w[2.9.0 4.0.0].each do |version|
        install = File.join(dir, "cache", version)
        write(File.join(install, "skills", "ce-brainstorm", "SKILL.md"))
        runner = FakeRunner.new(claude_responses(
          bin: bin,
          plugins: [ { "id" => "compound-engineering@compound-engineering-plugin", "version" => version, "enabled" => true, "installPath" => install } ],
          marketplaces: [ { "name" => "compound-engineering-plugin", "repo" => "EveryInc/compound-engineering-plugin" } ]
        ))
        row = inspect_rows(cfg: config(bin: bin), project: dir, runner: runner).find { |r| r.capability_id == "ce-brainstorm" }
        assert_equal(version.start_with?("2") ? "stale" : "incompatible", row.health)
      end
    end
  end

  def test_user_owned_plan_alias_and_project_shadow_are_conflicts
    with_tmp_dir do |dir|
      bin = File.join(dir, "claude")
      executable(bin)
      wiki_install = File.join(dir, "wiki-install")
      write(File.join(wiki_install, "skills", "wiki-plan", "SKILL.md"))
      write(File.join(dir, ".claude", "commands", "plan.md"), "my private plan command\n")
      ce_install = File.join(dir, "ce-install")
      write(File.join(ce_install, "skills", "ce-brainstorm", "SKILL.md"))
      write(File.join(dir, ".claude", "skills", "ce-brainstorm", "SKILL.md"), "shadow")
      runner = FakeRunner.new(claude_responses(
        bin: bin,
        plugins: [
          { "id" => "llm-wiki@aikuznetsov-marketplace", "version" => "0.1.9", "enabled" => true, "installPath" => wiki_install },
          { "id" => "compound-engineering@compound-engineering-plugin", "version" => "3.19.0", "enabled" => true, "installPath" => ce_install }
        ],
        marketplaces: [
          { "name" => "aikuznetsov-marketplace", "repo" => "ivankuznetsov/agent-plugins" },
          { "name" => "compound-engineering-plugin", "repo" => "EveryInc/compound-engineering-plugin" }
        ]
      ))

      rows = inspect_rows(cfg: config(bin: bin), project: dir, runner: runner)
      assert_equal "conflicting", rows.find { |r| r.capability_id == "wiki-plan" }.health
      assert_equal "conflicting", rows.find { |r| r.capability_id == "ce-brainstorm" }.health
      assert_match(/\.claude\/skills/, rows.find { |r| r.capability_id == "ce-brainstorm" }.explanation)
    end
  end

  def test_missing_binary_is_unavailable_without_native_runner_calls
    with_tmp_dir do |dir|
      runner = FakeRunner.new
      rows = inspect_rows(cfg: config(bin: File.join(dir, "missing-claude")), project: dir, runner: runner)

      assert rows.all? { |row| row.health == "unavailable" }
      assert_empty runner.calls
    end
  end

  def test_malformed_inventory_is_incompatible_and_binary_override_is_used
    with_tmp_dir do |dir|
      bin = File.join(dir, "custom-claude")
      executable(bin)
      responses = claude_responses(bin: bin, plugins: [], marketplaces: [])
      responses[[ bin, "plugin", "list", "--json" ]] = result(stdout: "{")
      runner = FakeRunner.new(responses)

      row = inspect_rows(cfg: config(bin: bin), project: dir, runner: runner).first

      assert_equal "incompatible", row.health
      assert runner.calls.all? { |call| call.fetch(:argv).first == bin }
    end
  end

  def test_native_claim_without_runtime_resolution_remains_missing
    with_tmp_dir do |dir|
      bin = File.join(dir, "claude")
      executable(bin)
      install = File.join(dir, "install")
      runner = FakeRunner.new(claude_responses(
        bin: bin,
        plugins: [ { "id" => "compound-engineering@compound-engineering-plugin", "version" => "3.19.0", "enabled" => true, "installPath" => install } ],
        marketplaces: [ { "name" => "compound-engineering-plugin", "repo" => "EveryInc/compound-engineering-plugin" } ]
      ))

      row = inspect_rows(cfg: config(bin: bin), project: dir, runner: runner).find { |r| r.capability_id == "ce-brainstorm" }

      assert_equal "missing", row.health
      assert_match(/cannot resolve/, row.explanation)
    end
  end

  def test_a_second_inspection_refreshes_native_inventory
    with_tmp_dir do |dir|
      bin = File.join(dir, "bin", "claude")
      executable(bin)
      install = File.join(
        dir, "claude", "plugins", "cache",
        "compound-engineering-plugin", "compound-engineering", "3.19.0"
      )
      plugins = []
      responses = claude_responses(
        bin: bin,
        plugins: [],
        marketplaces: [ { "name" => "compound-engineering-plugin", "repo" => "EveryInc/compound-engineering-plugin" } ]
      )
      responses[[ bin, "plugin", "list", "--json" ]] = lambda do |_argv, _env, _timeout|
        result(stdout: JSON.generate(plugins))
      end
      runner = FakeRunner.new(responses)
      inspector = Hive::AgentSkills::Inspector.new(
        config: config(bin: bin), project_root: dir, runner: runner,
        environment: { "HOME" => dir, "PATH" => "", "CLAUDE_CONFIG_DIR" => File.join(dir, "claude") }
      )

      first = inspector.inspect.find { |row| row.capability_id == "ce-brainstorm" }
      assert_equal "missing", first.health

      write(File.join(install, "skills", "ce-brainstorm", "SKILL.md"))
      plugins << {
        "id" => "compound-engineering@compound-engineering-plugin",
        "version" => "3.19.0",
        "enabled" => true,
        "installPath" => install
      }
      second = inspector.inspect.find { |row| row.capability_id == "ce-brainstorm" }

      assert_equal "healthy", second.health
      assert_equal 4, runner.calls.count { |call| call.fetch(:argv) == [ bin, "plugin", "list", "--json" ] }
    end
  end

  def test_multiple_capabilities_share_package_evidence_but_keep_rows
    with_tmp_dir do |dir|
      bin = File.join(dir, "claude")
      executable(bin)
      install = File.join(dir, "install")
      write(File.join(install, "skills", "ce-brainstorm", "SKILL.md"))
      write(File.join(install, "skills", "ce-code-review", "SKILL.md"))
      reviewer = { "name" => "ce", "kind" => "agent", "agent" => "claude", "skill" => "ce-code-review" }
      runner = FakeRunner.new(claude_responses(
        bin: bin,
        plugins: [ { "id" => "compound-engineering@compound-engineering-plugin", "version" => "3.19.0", "enabled" => true, "installPath" => install } ],
        marketplaces: [ { "name" => "compound-engineering-plugin", "repo" => "EveryInc/compound-engineering-plugin" } ]
      ))

      rows = inspect_rows(cfg: config(bin: bin, reviewers: [ reviewer ]), project: dir, runner: runner)
      package_rows = rows.select { |row| row.package_id == "compound-engineering" }

      assert_equal %w[ce-brainstorm ce-code-review], package_rows.map(&:capability_id).sort
      assert_equal 1, package_rows.map { |row| row.native.fetch("package") }.uniq.size
    end
  end

  def test_inspection_is_read_only_and_never_uses_install_argv
    with_tmp_dir do |dir|
      bin = File.join(dir, "claude")
      executable(bin)
      marker = File.join(dir, "operator-owned.txt")
      write(marker, "preserve me\n")
      runner = FakeRunner.new(claude_responses(bin: bin, plugins: [], marketplaces: []))
      before = File.read(marker)

      inspect_rows(cfg: config(bin: bin), project: dir, runner: runner)

      assert_equal before, File.read(marker)
      refute runner.calls.any? { |call| call.fetch(:argv).any? { |arg| %w[add install update upgrade].include?(arg) } }
    end
  end
end
