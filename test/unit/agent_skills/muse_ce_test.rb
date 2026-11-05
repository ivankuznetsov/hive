require "test_helper"
require "json"

require "hive/agent_skills/inspector"
require "hive/agent_skills/provisioner"
require "hive/agent_support/muse"

# Compound Engineering for Muse. Muse refuses plugin bundles containing
# symlinks, so Hive stages a dereferenced copy of the upstream git source
# and installs/updates the plugin from that staged tree. The fake-muse
# fixture mirrors the real registry shapes (and the symlink refusal), and
# the git clone is dispatched to a local fixture tree so the whole
# inspect -> stage -> install -> healthy cycle stays hermetic.
class AgentSkillsMuseCeTest < Minitest::Test
  include HiveTestHelper

  FAKE_BIN = File.expand_path("../../fixtures/fake-muse", __dir__)
  REPOSITORY = "https://github.com/EveryInc/compound-engineering-plugin"

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
          stdout: "{}", stderr: "", exit_status: 0, error: nil, timed_out: false
        )
      end
    end
  end

  # Simulates `git clone` from a local fixture tree and delegates every
  # other command (the fake muse binary) to the real command runner.
  class DispatchRunner
    def initialize(fixture:)
      @fixture = fixture
      @real = Hive::AgentSkills::CommandRunner.new
    end

    def call(argv, env: {}, timeout: 10, chdir: nil)
      if argv[0] == "git" && argv[1] == "clone"
        FileUtils.rm_rf(argv.last)
        FileUtils.cp_r(@fixture, argv.last)
        return Hive::AgentSkills::CommandResult.new(
          stdout: "", stderr: "", exit_status: 0, error: nil, timed_out: false
        )
      end

      @real.call(argv, env: env, timeout: timeout, chdir: chdir)
    end
  end

  def environment(home)
    {
      "HOME" => home,
      "PATH" => ENV.fetch("PATH", ""),
      "XDG_CONFIG_HOME" => File.join(home, "xdg-config"),
      "XDG_DATA_HOME" => File.join(home, "xdg-data")
    }
  end

  def config
    cfg = Marshal.load(Marshal.dump(Hive::Config::DEFAULTS))
    cfg["project_root"] = nil
    cfg["agents"]["muse"]["bin"] = FAKE_BIN
    cfg["brainstorm"]["agent"] = "muse"
    cfg
  end

  def write_ce_fixture(root, version: "3.1.0")
    FileUtils.mkdir_p(File.join(root, ".claude-plugin"))
    File.write(
      File.join(root, ".claude-plugin", "plugin.json"),
      JSON.generate(
        "name" => "compound-engineering", "version" => version,
        "repository" => REPOSITORY
      )
    )
    %w[ce-brainstorm ce-plan ce-code-review ce-doc-review ce-test-browser].each do |skill|
      dir = File.join(root, "skills", skill)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "SKILL.md"), "---\nname: #{skill}\n---\n#{skill}\n")
    end
    # The upstream shape that makes Muse refuse a direct install.
    FileUtils.mkdir_p(File.join(root, ".agy"))
    FileUtils.ln_s("../skills", File.join(root, ".agy", "skills"))
    root
  end

  def target(capability)
    Hive::AgentSkills::Target.new(
      surfaces: [ "test" ].freeze, kind: "stage", agent: "muse",
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
    Hive::AgentSupport::Muse::SetupAdapter.new(
      config: config, project_root: home, runner: runner,
      environment: environment(home)
    )
  end

  def staging_package(home)
    File.join(
      home, "xdg-data", "muse", "hive", "compound-engineering", "package"
    )
  end

  def test_missing_package_plans_stage_then_install
    with_tmp_dir do |home|
      row = inspection(capability: "ce-brainstorm", health: "missing")

      plan = adapter(home).plan([ row ])

      assert_equal %w[plugin_stage plugin_install], plan.operations.map(&:kind)
      stage, install = plan.operations
      assert_equal(
        [ FAKE_BIN, "plugins", "install", staging_package(home), "--json" ],
        install.argv
      )
      assert_equal [ stage.id ], install.depends_on
    end
  end

  def test_stale_package_plans_stage_then_update
    with_tmp_dir do |home|
      row = inspection(
        capability: "ce-brainstorm", health: "stale",
        native_package: { "id" => "compound-engineering", "version" => "2.9.0" }
      )

      plan = adapter(home).plan([ row ])

      assert_equal %w[plugin_stage plugin_update], plan.operations.map(&:kind)
      assert_equal [ FAKE_BIN, "plugins", "update", "compound-engineering", "--json" ],
                   plan.operations.fetch(1).argv
    end
  end

  def test_disabled_package_plans_only_enable
    with_tmp_dir do |home|
      row = inspection(
        capability: "ce-brainstorm", health: "missing",
        native_package: {
          "id" => "compound-engineering", "version" => "3.1.0", "enabled" => false
        },
        resolution: { "path" => "/somewhere/SKILL.md" }
      )

      plan = adapter(home).plan([ row ])

      assert_equal %w[plugin_enable], plan.operations.map(&:kind)
    end
  end

  def test_foreign_installed_plugin_is_an_ownership_conflict
    with_tmp_dir do |home|
      env = environment(home)
      registry = File.join(
        env.fetch("XDG_DATA_HOME"), "muse", "plugins", "installed.json"
      )
      FileUtils.mkdir_p(File.dirname(registry))
      File.write(registry, JSON.generate(
        "plugins" => {
          "compound-engineering" => {
            "id" => "compound-engineering", "version" => "3.1.0",
            "enabled" => true, "cache_path" => "plugins/cache/local/x/package",
            "source" => { "path" => File.join(home, "my-own-copy") }
          }
        }
      ))
      row = inspection(capability: "ce-brainstorm", health: "missing")

      plan = adapter(home).plan([ row ])

      assert_empty plan.operations
      assert_match(/will not replace/, plan.conflicts.join("\n"))
    end
  end

  def test_staging_dereferences_symlinks_from_a_real_git_clone
    with_tmp_git_repo do |repo|
      write_ce_fixture(repo)
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "fixture", "--quiet")

      with_tmp_dir do |home|
        root = File.join(home, "stage")
        version = Hive::AgentSupport::Muse::PluginStaging.stage(
          source: repo, root: root,
          runner: Hive::AgentSkills::CommandRunner.new,
          env: { "HOME" => home, "PATH" => ENV.fetch("PATH", "") }
        )

        assert_equal "3.1.0", version
        package = File.join(root, "package")
        assert File.file?(File.join(package, "skills", "ce-plan", "SKILL.md"))
        assert File.file?(File.join(package, ".agy", "skills", "ce-plan", "SKILL.md"))
        refute File.exist?(File.join(package, ".git"))
        assert_empty Dir.glob(File.join(package, "**", "*"), File::FNM_DOTMATCH)
                        .select { |path| File.symlink?(path) }
      end
    end
  end

  def test_live_and_filesystem_inventories_read_the_plugin_registry
    with_tmp_dir do |home|
      env = environment(home)
      data = File.join(env.fetch("XDG_DATA_HOME"), "muse")
      cache = File.join(
        data, "plugins", "cache", "local", "compound-engineering", "abc", "package"
      )
      FileUtils.mkdir_p(File.join(cache, ".claude-plugin"))
      File.write(
        File.join(cache, ".claude-plugin", "plugin.json"),
        JSON.generate("name" => "compound-engineering", "repository" => REPOSITORY)
      )
      FileUtils.mkdir_p(File.join(cache, "skills", "ce-plan"))
      File.write(File.join(cache, "skills", "ce-plan", "SKILL.md"), "plan\n")
      registry = File.join(data, "plugins", "installed.json")
      FileUtils.mkdir_p(File.dirname(registry))
      File.write(registry, JSON.generate(
        "plugins" => {
          "compound-engineering" => {
            "id" => "compound-engineering", "version" => "3.1.0",
            "enabled" => true,
            "cache_path" => "plugins/cache/local/compound-engineering/abc/package",
            "source" => { "path" => "/stage/package" }
          }
        }
      ))
      native = Hive::AgentSkills::Manifest.load
        .package("compound-engineering").native_for("muse")
      skills = Hive::AgentSupport::Muse::Skills

      filesystem = skills.filesystem_inventory(
        native_spec: native, environment: env,
        read_json: lambda { |path, default|
          File.file?(path) ? JSON.parse(File.read(path)) : default
        }
      )
      assert_equal "3.1.0", filesystem.dig("package", "version")
      assert_equal cache, filesystem.dig("package", "install_path")
      assert_equal REPOSITORY, filesystem.dig("package", "source")

      status, path = nil
      with_env(env) { status, path = skills.verify("/ce-plan") }
      assert_equal :present, status
      assert_equal File.join(cache, "skills", "ce-plan", "SKILL.md"), path
    end
  end

  def test_provisioner_stages_installs_and_reaches_healthy
    with_tmp_dir do |home|
      fixture = write_ce_fixture(File.join(home, "ce-fixture"))
      project = File.join(home, "project")
      Dir.mkdir(project, 0o700)
      provisioner = Hive::AgentSkills::Provisioner.new(
        config: config, project_root: project,
        runner: DispatchRunner.new(fixture: fixture),
        environment: environment(home)
      )

      plan = provisioner.build_plan(agents: [ "muse" ], skills: [ "ce-brainstorm" ])
      assert_equal %w[plugin_stage plugin_install], plan.operations.map(&:kind)

      outcome = provisioner.execute(plan, consent_provenance: "test")

      assert_equal 0, outcome.exit_code, outcome.operation_results.map(&:message).join("; ")
      row = outcome.final_health.find { |health| health.capability_id == "ce-brainstorm" }
      assert_equal "healthy", row.health, row.explanation
      assert_empty provisioner
        .build_plan(agents: [ "muse" ], skills: [ "ce-brainstorm" ]).operations
    end
  end
end
