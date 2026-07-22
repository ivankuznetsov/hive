require "test_helper"
require "hive/digest"
require "hive/agent_skills/adapters/registry"

class AgentSkillAdaptersTest < Minitest::Test
  include HiveTestHelper

  class FakeRunner
    attr_reader :calls

    def initialize(&block)
      @block = block
      @calls = []
    end

    def call(argv, env: {}, timeout: 10)
      @calls << { argv: argv, env: env, timeout: timeout }
      return @block.call(argv, env, timeout) if @block

      Hive::AgentSkills::CommandResult.new(
        stdout: "{}", stderr: "", exit_status: 0, error: nil, timed_out: false
      )
    end
  end

  def command_result(status: 0, stdout: "{}", stderr: "", timed_out: false)
    Hive::AgentSkills::CommandResult.new(
      stdout: stdout, stderr: stderr, exit_status: status, error: nil, timed_out: timed_out
    )
  end

  def target(agent:, capability:, package:)
    Hive::AgentSkills::Target.new(
      surfaces: [ "test" ].freeze,
      kind: "stage",
      agent: agent,
      configured_skill: capability,
      invocation: Hive::AgentSkills::Manifest.load.capability(capability).agent(agent).invocation,
      capability_id: capability,
      package_id: package,
      managed: true
    )
  end

  def inspection(agent:, capability:, package:, health:, bin:, native_package: nil, marketplace: nil,
                 resolution: {})
    Hive::AgentSkills::Inspection.new(
      target: target(agent: agent, capability: capability, package: package),
      expected: {},
      native: {
        "available" => true,
        "bin" => bin,
        "package" => native_package,
        "marketplace" => marketplace
      },
      resolution: { "path" => nil, "alias_owned" => nil }.merge(resolution),
      health: health,
      severity: health == "healthy" ? "info" : "error",
      explanation: health,
      remediation: "repair"
    )
  end

  def adapter(klass, dir:, runner: FakeRunner.new, environment: {})
    klass.new(
      config: Marshal.load(Marshal.dump(Hive::Config::DEFAULTS)),
      project_root: dir,
      runner: runner,
      environment: { "HOME" => dir, "PATH" => "" }.merge(environment)
    )
  end

  def test_claude_fresh_install_emits_marketplace_and_one_deduplicated_package_operation
    with_tmp_dir do |dir|
      rows = %w[ce-brainstorm ce-code-review].map do |capability|
        inspection(agent: "claude", capability: capability, package: "compound-engineering",
                   health: "missing", bin: "/fake/claude")
      end

      plan = adapter(Hive::AgentSkills::Adapters::Claude, dir: dir).plan(rows)

      assert_equal 2, plan.operations.size
      marketplace, install = plan.operations
      assert_equal [ "/fake/claude", "plugin", "marketplace", "add", "EveryInc/compound-engineering-plugin", "--scope", "user" ], marketplace.argv
      assert_equal [ "/fake/claude", "plugin", "install", "compound-engineering@compound-engineering-plugin", "--scope", "user" ], install.argv
      assert_equal [ marketplace.id ], install.depends_on
      assert marketplace.frozen?
      assert marketplace.argv.frozen?
    end
  end

  def test_claude_stale_install_uses_native_update
    with_tmp_dir do |dir|
      row = inspection(
        agent: "claude", capability: "ce-brainstorm", package: "compound-engineering",
        health: "stale", bin: "/fake/claude",
        native_package: { "id" => "compound-engineering@compound-engineering-plugin", "version" => "2.9.0" },
        marketplace: { "name" => "compound-engineering-plugin", "source" => "EveryInc/compound-engineering-plugin" }
      )

      operation = adapter(Hive::AgentSkills::Adapters::Claude, dir: dir).plan([ row ]).operations.fetch(0)

      assert_equal [ "/fake/claude", "plugin", "update", "compound-engineering@compound-engineering-plugin", "--scope", "user" ], operation.argv
    end
  end

  def test_claude_plan_alias_is_atomic_and_depends_on_plugin_install
    with_tmp_dir do |dir|
      row = inspection(agent: "claude", capability: "wiki-plan", package: "llm-wiki",
                       health: "missing", bin: "/fake/claude")
      prerequisite = inspection(
        agent: "claude", capability: "ce-brainstorm", package: "compound-engineering",
        health: "healthy", bin: "/fake/claude"
      )
      adapter = adapter(Hive::AgentSkills::Adapters::Claude, dir: dir)
      plan = adapter.plan([ prerequisite, row ])
      alias_operation = plan.operations.find { |operation| operation.kind == "alias_write" }

      assert_equal [ File.join(dir, ".claude", "commands", "plan.md") ], alias_operation.files
      assert alias_operation.depends_on.any? { |id| id.end_with?(":plugin_install") }

      outcome = adapter.execute(alias_operation)
      assert_equal "succeeded", outcome.status
      assert_equal Hive::AgentSkills::Manifest.alias_content(
        Hive::AgentSkills::Manifest.load.capability("wiki-plan").agent("claude").alias_spec
      ), File.read(alias_operation.files.first)
    end
  end

  def test_declared_package_prerequisite_orders_llm_wiki_after_compound_engineering
    with_tmp_dir do |dir|
      ce = inspection(agent: "claude", capability: "ce-brainstorm", package: "compound-engineering",
                      health: "missing", bin: "/fake/claude")
      wiki = inspection(agent: "claude", capability: "wiki-plan", package: "llm-wiki",
                        health: "missing", bin: "/fake/claude")

      operations = adapter(Hive::AgentSkills::Adapters::Claude, dir: dir).plan([ ce, wiki ]).operations
      ce_final = operations.reverse.find { |operation| operation.package_id == "compound-engineering" }
      wiki_operations = operations.select { |operation| operation.package_id == "llm-wiki" }

      assert wiki_operations.all? { |operation| operation.depends_on.include?(ce_final.id) }
    end
  end

  def test_missing_uninspected_prerequisite_blocks_dependent_package
    with_tmp_dir do |dir|
      wiki = inspection(agent: "claude", capability: "wiki-plan", package: "llm-wiki",
                        health: "missing", bin: "/fake/claude")

      plan = adapter(Hive::AgentSkills::Adapters::Claude, dir: dir).plan([ wiki ])

      assert_empty plan.operations
      assert_equal 1, plan.conflicts.size
      assert_match(/llm-wiki requires compound-engineering.*not inspected/, plan.conflicts.first)
    end
  end

  def test_unhealthy_prerequisite_blocks_dependent_package
    with_tmp_dir do |dir|
      prerequisite = inspection(
        agent: "claude", capability: "ce-brainstorm", package: "compound-engineering",
        health: "incompatible", bin: "/fake/claude"
      )
      wiki = inspection(agent: "claude", capability: "wiki-plan", package: "llm-wiki",
                        health: "missing", bin: "/fake/claude")

      plan = adapter(Hive::AgentSkills::Adapters::Claude, dir: dir).plan([ prerequisite, wiki ])

      assert_empty plan.operations
      assert_match(/prerequisite is incompatible/, plan.conflicts.first)
    end
  end

  def test_user_owned_alias_is_never_scheduled
    with_tmp_dir do |dir|
      path = File.join(dir, ".claude", "commands", "plan.md")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "private\n")
      row = inspection(agent: "claude", capability: "wiki-plan", package: "llm-wiki",
                       health: "conflicting", bin: "/fake/claude")

      plan = adapter(Hive::AgentSkills::Adapters::Claude, dir: dir).plan([ row ])

      assert_empty plan.operations
      assert_equal "private\n", File.read(path)
    end
  end

  def test_codex_emits_supported_json_marketplace_and_plugin_add_argv
    with_tmp_dir do |dir|
      row = inspection(agent: "codex", capability: "ce-brainstorm", package: "compound-engineering",
                       health: "missing", bin: "/fake/codex")

      plan = adapter(Hive::AgentSkills::Adapters::Codex, dir: dir,
                     environment: { "CODEX_HOME" => File.join(dir, "codex") }).plan([ row ])

      assert_equal [
        [ "/fake/codex", "plugin", "marketplace", "add", "https://github.com/EveryInc/compound-engineering-plugin.git", "--json" ],
        [ "/fake/codex", "plugin", "add", "compound-engineering@compound-engineering-plugin", "--json" ]
      ], plan.operations.map(&:argv)
    end
  end

  def test_codex_executes_dependent_packages_against_the_advancing_config
    with_tmp_dir do |dir|
      codex_home = File.join(dir, "codex")
      config_path = File.join(codex_home, "config.toml")
      FileUtils.mkdir_p(codex_home)
      runner = FakeRunner.new do |argv, _env, _timeout|
        section = if argv[2] == "marketplace"
          name = argv[-2].include?("EveryInc") ? "compound-engineering-plugin" : "aikuznetsov-marketplace"
          "[marketplaces.#{name}]\nsource = \"#{argv[-2]}\"\n"
        else
          "[plugins.\"#{argv[3]}\"]\nenabled = true\n"
        end
        File.open(config_path, "a") { |file| file.write(section) }
        command_result
      end
      rows = [
        inspection(agent: "codex", capability: "ce-brainstorm", package: "compound-engineering",
                   health: "missing", bin: "/fake/codex"),
        inspection(agent: "codex", capability: "wiki-plan", package: "llm-wiki",
                   health: "missing", bin: "/fake/codex")
      ]
      instance = adapter(Hive::AgentSkills::Adapters::Codex, dir: dir, runner: runner,
                         environment: { "CODEX_HOME" => codex_home })

      outcomes = instance.plan(rows).operations.map { |operation| instance.execute(operation) }

      assert_equal %w[succeeded succeeded succeeded succeeded], outcomes.map(&:status),
                   outcomes.map(&:message).inspect
      assert_equal 4, runner.calls.size
    end
  end

  def test_codex_conflicting_marketplace_owner_is_preserved
    with_tmp_dir do |dir|
      codex_home = File.join(dir, "codex")
      config_path = File.join(codex_home, "config.toml")
      FileUtils.mkdir_p(codex_home)
      original = <<~TOML
        # operator comment
        [marketplaces.compound-engineering-plugin]
        source_type = "git"
        source = "https://example.test/private.git"
      TOML
      File.write(config_path, original)
      row = inspection(agent: "codex", capability: "ce-brainstorm", package: "compound-engineering",
                       health: "missing", bin: "/fake/codex")

      plan = adapter(Hive::AgentSkills::Adapters::Codex, dir: dir,
                     environment: { "CODEX_HOME" => codex_home }).plan([ row ])

      assert_empty plan.operations
      assert_match(/marketplace.*owned/, plan.conflicts.first)
      assert_equal original, File.read(config_path)
    end
  end

  def test_codex_digest_drift_aborts_before_runner
    with_tmp_dir do |dir|
      codex_home = File.join(dir, "codex")
      config_path = File.join(codex_home, "config.toml")
      FileUtils.mkdir_p(codex_home)
      File.write(config_path, "# before\n")
      runner = FakeRunner.new
      row = inspection(
        agent: "codex", capability: "ce-brainstorm", package: "compound-engineering",
        health: "missing", bin: "/fake/codex",
        marketplace: { "name" => "compound-engineering-plugin", "source" => "https://github.com/EveryInc/compound-engineering-plugin.git" }
      )
      adapter = adapter(Hive::AgentSkills::Adapters::Codex, dir: dir, runner: runner,
                        environment: { "CODEX_HOME" => codex_home })
      operation = adapter.plan([ row ]).operations.fetch(0)
      File.write(config_path, "# concurrent user edit\n")

      outcome = adapter.execute(operation)

      assert_equal "failed", outcome.status
      assert_match(/changed since preview/, outcome.message)
      assert_empty runner.calls
    end
  end

  def test_codex_dependent_operation_accepts_owned_config_drift_without_a_recorded_snapshot
    with_tmp_dir do |dir|
      codex_home = File.join(dir, "codex")
      config_path = File.join(codex_home, "config.toml")
      FileUtils.mkdir_p(codex_home)
      File.write(config_path, "")
      row = inspection(
        agent: "codex", capability: "ce-brainstorm", package: "compound-engineering",
        health: "missing", bin: "/fake/codex",
        marketplace: nil
      )
      codex = adapter(
        Hive::AgentSkills::Adapters::Codex, dir: dir,
        environment: { "CODEX_HOME" => codex_home }
      )
      operation = codex.plan([ row ]).operations.find { |item| item.kind == "plugin_install" }
      package = operation.metadata.fetch("native_package")
      File.write(config_path, "[plugins.\"#{package}\"]\nenabled = true\n")

      assert_nil codex.send(:validate_preconditions, operation)
    end
  end

  def test_codex_success_preserves_comments_unrelated_content_and_mode
    with_tmp_dir do |dir|
      codex_home = File.join(dir, "codex")
      config_path = File.join(codex_home, "config.toml")
      FileUtils.mkdir_p(codex_home)
      original = "# keep this\nmodel = \"gpt\"\n\n"
      File.write(config_path, original)
      File.chmod(0o600, config_path)
      runner = FakeRunner.new do |_argv, _env, _timeout|
        File.open(config_path, "a") { |file| file.write("[plugins.\"compound-engineering@compound-engineering-plugin\"]\nenabled = true\n") }
        File.chmod(0o644, config_path)
        command_result
      end
      row = inspection(
        agent: "codex", capability: "ce-brainstorm", package: "compound-engineering",
        health: "missing", bin: "/fake/codex",
        marketplace: { "name" => "compound-engineering-plugin", "source" => "https://github.com/EveryInc/compound-engineering-plugin.git" }
      )
      adapter = adapter(Hive::AgentSkills::Adapters::Codex, dir: dir, runner: runner,
                        environment: { "CODEX_HOME" => codex_home })

      outcome = adapter.execute(adapter.plan([ row ]).operations.fetch(0))

      assert_equal "succeeded", outcome.status
      assert File.read(config_path).start_with?(original)
      assert_equal 0o600, File.stat(config_path).mode & 0o777
    end
  end

  def test_codex_failed_torn_targeted_write_is_restored_but_concurrent_edit_is_not
    with_tmp_dir do |dir|
      codex_home = File.join(dir, "codex")
      config_path = File.join(codex_home, "config.toml")
      FileUtils.mkdir_p(codex_home)
      original = "# original\nmodel = \"gpt\"\n"
      File.write(config_path, original)
      row = inspection(
        agent: "codex", capability: "ce-brainstorm", package: "compound-engineering",
        health: "missing", bin: "/fake/codex",
        marketplace: { "name" => "compound-engineering-plugin", "source" => "https://github.com/EveryInc/compound-engineering-plugin.git" }
      )

      targeted_runner = FakeRunner.new do |_argv, _env, _timeout|
        File.open(config_path, "a") { |file| file.write("[plugins.\"compound-engineering@compound-engineering-plugin\"]\nenabled = true\n") }
        command_result(status: 1, stderr: "offline")
      end
      targeted_adapter = adapter(Hive::AgentSkills::Adapters::Codex, dir: dir, runner: targeted_runner,
                                 environment: { "CODEX_HOME" => codex_home })
      targeted_adapter.execute(targeted_adapter.plan([ row ]).operations.fetch(0))
      assert_equal original, File.read(config_path)

      concurrent_runner = FakeRunner.new do |_argv, _env, _timeout|
        File.open(config_path, "a") { |file| file.write("user_value = 1\n[plugins.\"compound-engineering@compound-engineering-plugin\"]\nenabled = true\n") }
        command_result(status: 1, stderr: "offline")
      end
      concurrent_adapter = adapter(Hive::AgentSkills::Adapters::Codex, dir: dir, runner: concurrent_runner,
                                   environment: { "CODEX_HOME" => codex_home })
      concurrent_adapter.execute(concurrent_adapter.plan([ row ]).operations.fetch(0))
      assert_includes File.read(config_path), "user_value = 1"
    end
  end

  def test_pi_uses_native_install_and_update_sources
    with_tmp_dir do |dir|
      fresh = inspection(agent: "pi", capability: "ce-brainstorm", package: "compound-engineering",
                         health: "missing", bin: "/fake/pi")
      stale = inspection(agent: "pi", capability: "ce-brainstorm", package: "compound-engineering",
                         health: "stale", bin: "/fake/pi",
                         native_package: { "id" => "source", "version" => "2.9.0" })
      adapter = adapter(Hive::AgentSkills::Adapters::Pi, dir: dir)

      assert_equal [ "/fake/pi", "install", "https://github.com/EveryInc/compound-engineering-plugin" ],
                   adapter.plan([ fresh ]).operations.fetch(0).argv
      assert_equal [ "/fake/pi", "update", "https://github.com/EveryInc/compound-engineering-plugin" ],
                   adapter.plan([ stale ]).operations.fetch(0).argv
    end
  end

  def test_execution_reports_timeout_without_shell_evaluation
    with_tmp_dir do |dir|
      runner = FakeRunner.new { |_argv, _env, _timeout| command_result(status: nil, timed_out: true) }
      row = inspection(agent: "pi", capability: "ce-brainstorm", package: "compound-engineering",
                       health: "missing", bin: "/fake/pi")
      adapter = adapter(Hive::AgentSkills::Adapters::Pi, dir: dir, runner: runner)

      outcome = adapter.execute(adapter.plan([ row ]).operations.fetch(0))

      assert_equal "failed", outcome.status
      assert_match(/timed out/, outcome.message)
      assert_equal "https://github.com/EveryInc/compound-engineering-plugin", runner.calls.first.fetch(:argv).last
    end
  end

  def test_registry_returns_the_provider_adapter
    with_tmp_dir do |dir|
      registry = Hive::AgentSkills::Adapters::Registry.new(
        config: Hive::Config::DEFAULTS, project_root: dir, environment: { "HOME" => dir }
      )

      assert_instance_of Hive::AgentSkills::Adapters::Claude, registry.fetch("claude")
      assert_instance_of Hive::AgentSkills::Adapters::Codex, registry.fetch("codex")
      assert_instance_of Hive::AgentSkills::Adapters::Pi, registry.fetch("pi")
    end
  end

  def test_base_defensive_execution_and_helpers
    with_tmp_dir do |dir|
      row = inspection(agent: "pi", capability: "ce-brainstorm", package: "compound-engineering",
                       health: "missing", bin: "/fake/pi")
      raising = FakeRunner.new { |_argv, _env, _timeout| raise IOError, "runner exploded" }
      pi = adapter(Hive::AgentSkills::Adapters::Pi, dir: dir, runner: raising)
      outcome = pi.execute(pi.plan([ row ]).operations.first)
      assert_equal "failed", outcome.status
      assert_match(/runner exploded/, outcome.message)

      abstract = Class.new(Hive::AgentSkills::Adapters::Base)
      abstract.const_set(:AGENT, "claude")
      abstract_adapter = adapter(abstract, dir: dir)
      claude_row = inspection(agent: "claude", capability: "ce-brainstorm", package: "compound-engineering",
                              health: "missing", bin: "/fake/claude")
      assert_raises(NotImplementedError) { abstract_adapter.plan([ claude_row ]) }

      codex_native = Hive::AgentSkills::Manifest.load.package("compound-engineering").native_for("codex")
      codex = adapter(Hive::AgentSkills::Adapters::Codex, dir: dir)
      assert_equal File.join(dir, ".codex"), codex.send(:config_root, codex_native)
      nested = { "items" => [ { "name" => "frozen" } ] }
      codex.send(:deep_freeze, nested)
      assert nested.dig("items", 0).frozen?
    end
  end

  def test_existing_alias_variants_are_not_scheduled_and_preview_drift_fails
    with_tmp_dir do |dir|
      row = inspection(agent: "claude", capability: "wiki-plan", package: "llm-wiki",
                       health: "missing", bin: "/fake/claude")
      prerequisite = inspection(
        agent: "claude", capability: "ce-brainstorm", package: "compound-engineering",
        health: "healthy", bin: "/fake/claude"
      )
      claude = adapter(Hive::AgentSkills::Adapters::Claude, dir: dir)
      path = File.join(dir, ".claude", "commands", "plan.md")
      spec = Hive::AgentSkills::Manifest.load.capability("wiki-plan").agent("claude").alias_spec
      FileUtils.mkdir_p(File.dirname(path))
      [ Hive::AgentSkills::Manifest.alias_content(spec), "private\n" ].each do |content|
        File.write(path, content)
        refute claude.plan([ prerequisite, row ]).operations.any? { |operation| operation.kind == "alias_write" }
      end

      FileUtils.rm_f(path)
      operation = claude.plan([ prerequisite, row ]).operations.find { |item| item.kind == "alias_write" }
      File.write(path, "appeared after preview\n")
      outcome = claude.execute(operation)
      assert_match(/changed since preview/, outcome.message)

      # Exercise the execute-time ownership guard independently of the
      # earlier digest precondition (defense in depth).
      outcome = claude.send(:execute_alias, operation)
      assert_match(/user-owned alias/, outcome.message)
    end
  end

  def test_command_error_object_is_reported
    with_tmp_dir do |dir|
      runner = FakeRunner.new do |_argv, _env, _timeout|
        Hive::AgentSkills::CommandResult.new(
          stdout: "", stderr: "", exit_status: nil, error: "spawn denied", timed_out: false
        )
      end
      row = inspection(agent: "pi", capability: "ce-brainstorm", package: "compound-engineering",
                       health: "missing", bin: "/fake/pi")
      outcome = adapter(Hive::AgentSkills::Adapters::Pi, dir: dir, runner: runner)
        .then { |instance| instance.execute(instance.plan([ row ]).operations.first) }
      assert_match(/spawn denied/, outcome.message)
    end
  end

  def test_codex_stale_marketplace_upgrade_unrelated_change_and_new_file_rollback
    with_tmp_dir do |dir|
      codex_home = File.join(dir, "codex")
      config_path = File.join(codex_home, "config.toml")
      FileUtils.mkdir_p(codex_home)
      row = inspection(
        agent: "codex", capability: "ce-brainstorm", package: "compound-engineering",
        health: "stale", bin: "/fake/codex",
        native_package: { "id" => "compound-engineering@compound-engineering-plugin", "version" => "2.9.0" },
        marketplace: { "name" => "compound-engineering-plugin",
                       "source" => "https://github.com/EveryInc/compound-engineering-plugin.git" }
      )
      codex = adapter(Hive::AgentSkills::Adapters::Codex, dir: dir,
                      environment: { "CODEX_HOME" => codex_home })
      assert codex.plan([ row ]).operations.any? { |operation| operation.kind == "marketplace_upgrade" }

      File.write(config_path, "# original\n")
      changing_runner = FakeRunner.new do |_argv, _env, _timeout|
        File.write(config_path, "# changed by codex\n")
        command_result
      end
      fresh = inspection(
        agent: "codex", capability: "ce-brainstorm", package: "compound-engineering",
        health: "missing", bin: "/fake/codex",
        marketplace: row.native.fetch("marketplace")
      )
      changing = adapter(Hive::AgentSkills::Adapters::Codex, dir: dir, runner: changing_runner,
                         environment: { "CODEX_HOME" => codex_home })
      outcome = changing.execute(changing.plan([ fresh ]).operations.first)
      assert_match(/changed comments or unrelated/, outcome.message)

      FileUtils.rm_f(config_path)
      failing_runner = FakeRunner.new do |_argv, _env, _timeout|
        FileUtils.mkdir_p(File.dirname(config_path))
        File.write(config_path, <<~TOML)
          [marketplaces.compound-engineering-plugin]
          source_type = "git"
          source = "https://github.com/EveryInc/compound-engineering-plugin.git"
        TOML
        command_result(status: 1, stderr: "offline")
      end
      missing_marketplace = inspection(agent: "codex", capability: "ce-brainstorm",
                                       package: "compound-engineering", health: "missing", bin: "/fake/codex")
      rolling = adapter(Hive::AgentSkills::Adapters::Codex, dir: dir, runner: failing_runner,
                        environment: { "CODEX_HOME" => codex_home })
      rolling.execute(rolling.plan([ missing_marketplace ]).operations.first)
      refute File.exist?(config_path)
    end
  end

  def test_registry_rejects_unknown_agent
    with_tmp_dir do |dir|
      registry = Hive::AgentSkills::Adapters::Registry.new(
        config: Hive::Config::DEFAULTS, project_root: dir, environment: { "HOME" => dir }
      )
      error = assert_raises(Hive::ConfigError) { registry.fetch("future") }
      assert_match(/no agent-skills adapter/, error.message)
    end
  end
end
