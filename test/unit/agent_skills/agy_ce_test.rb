require "test_helper"
require "json"

require "hive/agent_skills/inspector"
require "hive/agent_skills/provisioner"
require "hive/agent_support/agy"

# Compound Engineering for Antigravity CLI (`agy`). `agy plugin install`
# natively accepts GitHub URLs, `.claude-plugin/plugin.json` bundles, and
# symlinks, installing them under `~/.gemini/config/plugins/<name>` and
# recording enablement in `~/.gemini/config/config.json`.
class AgentSkillsAgyCeTest < Minitest::Test
  include HiveTestHelper

  FAKE_BIN = File.expand_path("../../fixtures/fake-agy", __dir__)
  REPOSITORY = "https://github.com/EveryInc/compound-engineering-plugin.git"

  class FakeRunner
    attr_reader :calls

    def initialize(responses = {})
      @responses = responses
      @calls = []
    end

    def call(argv, **)
      @calls << argv
      @responses.fetch(argv) do
        Hive::AgentSkills::CommandResult.new(
          stdout: "[]", stderr: "", exit_status: 0, error: nil, timed_out: false
        )
      end
    end
  end

  def environment(home, fixture: nil)
    env = {
      "HOME" => home,
      "PATH" => ENV.fetch("PATH", "")
    }
    env["HIVE_FAKE_AGY_PLUGIN_SOURCE"] = fixture if fixture
    env
  end

  def config
    cfg = Marshal.load(Marshal.dump(Hive::Config::DEFAULTS))
    cfg["project_root"] = nil
    cfg["agents"]["agy"]["bin"] = FAKE_BIN
    cfg["brainstorm"]["agent"] = "agy"
    cfg
  end

  def write_ce_fixture(root, version: "3.35.3", repository: REPOSITORY)
    FileUtils.mkdir_p(File.join(root, ".claude-plugin"))
    File.write(
      File.join(root, ".claude-plugin", "plugin.json"),
      JSON.generate(
        "name" => "compound-engineering",
        "version" => version,
        "repository" => repository
      )
    )
    %w[ce-brainstorm ce-plan ce-code-review ce-doc-review ce-test-browser].each do |skill|
      dir = File.join(root, "skills", skill)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "SKILL.md"), "---\nname: #{skill}\ndescription: #{skill}\n---\n")
    end
    root
  end

  def target(capability)
    Hive::AgentSkills::Target.new(
      surfaces: [ "test" ].freeze, kind: "stage", agent: "agy",
      configured_skill: capability,
      invocation: "/#{capability}",
      capability_id: capability, package_id: "compound-engineering",
      managed: true
    )
  end

  def inspection(capability:, health:, native_package: nil, resolution: {})
    Hive::AgentSkills::Inspection.new(
      target: target(capability), expected: {},
      native: {
        "available" => true, "bin" => FAKE_BIN,
        "package" => native_package, "marketplace" => nil
      },
      resolution: { "path" => nil, "alias_owned" => nil }.merge(resolution),
      health: health, severity: "error", explanation: health,
      remediation: "repair"
    )
  end

  def adapter(home, runner: FakeRunner.new)
    Hive::AgentSupport::Agy::SetupAdapter.new(
      config: config, project_root: home, runner: runner,
      environment: environment(home)
    )
  end

  def test_missing_package_plans_native_plugin_install
    with_tmp_dir do |home|
      row = inspection(capability: "ce-brainstorm", health: "missing")

      plan = adapter(home).plan([ row ])

      assert_equal %w[plugin_install], plan.operations.map(&:kind)
      assert_equal [ FAKE_BIN, "plugin", "install", REPOSITORY ],
                   plan.operations.fetch(0).argv
    end
  end

  def test_stale_package_plans_reinstall_update
    with_tmp_dir do |home|
      row = inspection(
        capability: "ce-brainstorm", health: "stale",
        native_package: { "id" => "compound-engineering", "version" => "2.9.0", "enabled" => true }
      )

      plan = adapter(home).plan([ row ])

      assert_equal %w[plugin_update], plan.operations.map(&:kind)
      assert_equal [ FAKE_BIN, "plugin", "install", REPOSITORY ],
                   plan.operations.fetch(0).argv
    end
  end

  def test_disabled_package_plans_enable_only
    with_tmp_dir do |home|
      row = inspection(
        capability: "ce-brainstorm", health: "missing",
        native_package: {
          "id" => "compound-engineering", "version" => "3.35.3", "enabled" => false
        }
      )

      plan = adapter(home).plan([ row ])

      assert_equal %w[plugin_enable], plan.operations.map(&:kind)
      assert_equal [ FAKE_BIN, "plugin", "enable", "compound-engineering" ],
                   plan.operations.fetch(0).argv
    end
  end

  def test_foreign_installed_plugin_is_an_ownership_conflict
    with_tmp_dir do |home|
      plugin_dir = File.join(home, ".gemini", "config", "plugins", "compound-engineering")
      FileUtils.mkdir_p(plugin_dir)
      File.write(
        File.join(plugin_dir, "plugin.json"),
        JSON.generate(
          "name" => "compound-engineering",
          "version" => "3.0.0",
          "repository" => "https://github.com/someone-else/private-plugin.git"
        )
      )
      row = inspection(capability: "ce-brainstorm", health: "missing")

      plan = adapter(home).plan([ row ])

      assert_empty plan.operations
      assert_match(/will not replace/, plan.conflicts.join("\n"))
    end
  end

  def test_filesystem_inventory_reads_installed_plugin_and_config_enablement
    with_tmp_dir do |home|
      root = File.join(home, ".gemini", "config")
      plugin_dir = File.join(root, "plugins", "compound-engineering")
      write_ce_fixture(plugin_dir, version: "3.35.3")
      File.write(
        File.join(plugin_dir, "plugin.json"),
        JSON.generate("name" => "compound-engineering", "version" => "3.35.3")
      )
      File.write(
        File.join(root, "config.json"),
        JSON.generate("plugins" => { "compound-engineering" => { "enabled" => false } })
      )
      native = Hive::AgentSkills::Manifest.load
        .package("compound-engineering").native_for("agy")

      inventory = Hive::AgentSupport::Agy::Skills.filesystem_inventory(
        native_spec: native, root: root,
        read_json: ->(path, default) { File.file?(path) ? JSON.parse(File.read(path)) : default }
      )

      assert_equal "3.35.3", inventory.dig("package", "version")
      assert_equal false, inventory.dig("package", "enabled")
      assert_equal plugin_dir, inventory.dig("package", "install_path")
      assert_equal REPOSITORY, inventory.dig("package", "source")
    end
  end

  def test_provisioner_installs_and_reaches_healthy_through_fake_agy
    with_tmp_dir do |home|
      fixture = write_ce_fixture(File.join(home, "ce-fixture"))
      project = File.join(home, "project")
      Dir.mkdir(project, 0o700)
      with_env("HIVE_FAKE_AGY_PLUGIN_SOURCE" => fixture) do
        provisioner = Hive::AgentSkills::Provisioner.new(
          config: config, project_root: project,
          runner: Hive::AgentSkills::CommandRunner.new,
          environment: environment(home, fixture: fixture)
        )

        plan = provisioner.build_plan(agents: [ "agy" ], skills: [ "ce-brainstorm" ])
        assert_equal %w[plugin_install], plan.operations.map(&:kind)

        outcome = provisioner.execute(plan, consent_provenance: "test")
        assert_equal 0, outcome.exit_code, outcome.operation_results.map(&:message).join("; ")
        row = outcome.final_health.find { |health| health.capability_id == "ce-brainstorm" }
        assert_equal "healthy", row.health, row.explanation
        assert_empty provisioner
          .build_plan(agents: [ "agy" ], skills: [ "ce-brainstorm" ]).operations
      end
    end
  end

  def test_skills_resolution_and_inventory_handle_edge_and_failure_branches
    with_tmp_dir do |home|
      config_root = File.join(home, ".gemini", "config")
      plugins_root = File.join(config_root, "plugins")
      env = { "HOME" => home }
      native = Hive::AgentSkills::Manifest.load
        .package("compound-engineering").native_for("agy")

      # Invalid invocation returns :missing via ArgumentError rescue.
      invalid = Hive::AgentSupport::Agy::Skills.resolve("", environment: env)
      assert_equal :missing, invalid.status
      assert_match(/agy:/, invalid.message)

      # Absent plugin directory returns nil package in filesystem_inventory.
      absent = Hive::AgentSupport::Agy::Skills.filesystem_inventory(
        native_spec: native, root: config_root, read_json: ->(_path, default) { default }
      )
      assert_nil absent.fetch("package")

      # Plugin-qualified invocation resolves exact plugin directory and exercises
      # non-existent candidate canonical_path fallback for a missing skill.
      plugin_dir = File.join(plugins_root, "compound-engineering")
      write_ce_fixture(plugin_dir)
      qualified = Hive::AgentSupport::Agy::Skills.resolve(
        "/compound-engineering:ce-brainstorm", environment: env
      )
      assert_equal :present, qualified.status
      missing = Hive::AgentSupport::Agy::Skills.resolve(
        "/compound-engineering:no-such-skill", environment: env
      )
      assert_equal :missing, missing.status

      # Symlink escaping plugins root is rejected by jailed check.
      outside = File.join(home, "outside")
      FileUtils.mkdir_p(outside)
      File.write(File.join(outside, "SKILL.md"), "# outside\n")
      escaped_dir = File.join(plugins_root, "escaped-plugin")
      FileUtils.mkdir_p(File.join(escaped_dir, "skills"))
      File.write(File.join(escaped_dir, "plugin.json"), JSON.generate("name" => "escaped-plugin"))
      File.symlink(outside, File.join(escaped_dir, "skills", "escaped-skill"))
      escaped = Hive::AgentSupport::Agy::Skills.resolve("/escaped-skill", environment: env)
      assert_equal :missing, escaped.status
      assert_match(/escapes/, escaped.parse_errors.join("\n"))

      # Malformed config.json and plugin.json are recorded in parse_errors.
      File.write(File.join(config_root, "config.json"), "{bad json")
      broken_dir = File.join(plugins_root, "broken-plugin")
      FileUtils.mkdir_p(broken_dir)
      File.write(File.join(broken_dir, "plugin.json"), "{bad json")
      malformed = Hive::AgentSupport::Agy::Skills.resolve("/no-such-skill", environment: env)
      assert_equal :missing, malformed.status
      assert_operator malformed.parse_errors.size, :>=, 2

      # repository_source returns nil when no repository is declared or JSON is malformed.
      no_repo_dir = File.join(home, "no-repo")
      FileUtils.mkdir_p(no_repo_dir)
      File.write(File.join(no_repo_dir, "plugin.json"), JSON.generate("name" => "no-repo"))
      assert_nil Hive::AgentSupport::Agy::Skills.repository_source(no_repo_dir)
      assert_nil Hive::AgentSupport::Agy::Skills.repository_source(broken_dir)

      # Unreadable plugins root is caught by SystemCallError rescue.
      File.write(File.join(config_root, "config.json"), JSON.generate("plugins" => {}))
      File.chmod(0o000, plugins_root)
      begin
        unreadable = Hive::AgentSupport::Agy::Skills.resolve("/ce-brainstorm", environment: env)
        assert_equal :missing, unreadable.status
        refute_empty unreadable.parse_errors
      ensure
        File.chmod(0o700, plugins_root)
      end

      # live_inventory records an incompatible issue when `agy plugin list` fails.
      issues = []
      failed = Hive::AgentSkills::CommandResult.new(
        stdout: "[]", stderr: "boom", exit_status: 1, error: nil, timed_out: false
      )
      inventory = Hive::AgentSupport::Agy::Skills.live_inventory(
        bin: FAKE_BIN, native_spec: native, issues: issues,
        run: ->(_argv) { failed }, failure: ->(_res) { "exit 1" }
      )
      assert_nil inventory.fetch("package")
      assert_equal [ [ "incompatible", "agy plugin inventory failed: exit 1" ] ], issues
    end
  end
end
