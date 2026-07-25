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

  def grok_responses(bin:, plugins:, loaded_plugins:, version: "0.2.102")
    {
      [ bin, "--version" ] => result(stdout: "grok #{version}\n"),
      [ bin, "plugin", "list", "--json" ] => result(stdout: JSON.generate(plugins)),
      [ bin, "inspect", "--json" ] => result(
        stdout: JSON.generate("plugins" => loaded_plugins, "skills" => [])
      )
    }
  end

  def inspect_rows(cfg:, project:, runner:, environment: {})
    Hive::AgentSkills::Inspector.new(
      config: cfg,
      project_root: project,
      runner: runner,
      environment: { "HOME" => project, "PATH" => "" }.merge(environment)
    ).inspect.reject { |row| row.capability_id == "hive" }
  end

  def test_target_resolver_derives_stages_reviewers_and_optional_browser_skill
    reviewer = { "name" => "codex-ce", "kind" => "agent", "agent" => "codex", "skill" => "ce-code-review" }
    cfg = config(reviewers: [ reviewer ], browser: true)
    resolver = Hive::AgentSkills::TargetResolver.new(config: cfg, project_root: "/tmp/project")

    targets = resolver.resolve

    assert_equal %w[ce-brainstorm wiki-plan ce-code-review ce-test-browser hive hive hive].sort,
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

  def test_filesystem_only_inventory_reads_claude_state_without_native_commands
    with_tmp_dir do |dir|
      bin = File.join(dir, "bin", "claude")
      executable(bin)
      config_root = File.join(dir, "claude")
      install = File.join(
        config_root, "plugins", "cache",
        "compound-engineering-plugin", "compound-engineering", "3.19.0"
      )
      write(File.join(install, "skills", "ce-brainstorm", "SKILL.md"))
      write(
        File.join(config_root, "plugins", "installed_plugins.json"),
        JSON.generate(
          "version" => 2,
          "plugins" => {
            "compound-engineering@compound-engineering-plugin" => [ {
              "scope" => "user", "installPath" => install,
              "version" => "3.19.0"
            } ]
          }
        )
      )
      write(
        File.join(config_root, "plugins", "known_marketplaces.json"),
        JSON.generate(
          "compound-engineering-plugin" => {
            "source" => { "source" => "github", "repo" => "EveryInc/compound-engineering-plugin" }
          }
        )
      )
      runner = FakeRunner.new

      row = Hive::AgentSkills::Inspector.new(
        config: config(bin: bin), project_root: dir, runner: runner,
        environment: { "HOME" => dir, "PATH" => "", "CLAUDE_CONFIG_DIR" => config_root },
        native_commands: false
      ).inspect(skills: [ "ce-brainstorm" ]).find { |entry| entry.capability_id == "ce-brainstorm" }

      assert_equal "healthy", row.health
      assert_equal "filesystem", row.native.fetch("inventory_source")
      assert_equal "3.19.0", row.native.dig("package", "version")
      assert_empty row.native.fetch("commands")
      assert_empty runner.calls
    end
  end

  def test_filesystem_only_inventory_honors_claude_disabled_state
    with_tmp_dir do |dir|
      bin = File.join(dir, "bin", "claude")
      executable(bin)
      config_root = File.join(dir, "claude")
      install = File.join(
        config_root, "plugins", "cache",
        "compound-engineering-plugin", "compound-engineering", "3.19.0"
      )
      write(File.join(install, "skills", "ce-brainstorm", "SKILL.md"))
      write(File.join(config_root, "plugins", "installed_plugins.json"), JSON.generate(
        "version" => 2,
        "plugins" => {
          "compound-engineering@compound-engineering-plugin" => [ {
            "scope" => "user", "installPath" => install, "version" => "3.19.0"
          } ]
        }
      ))
      write(File.join(config_root, "plugins", "known_marketplaces.json"), JSON.generate(
        "compound-engineering-plugin" => {
          "source" => { "repo" => "EveryInc/compound-engineering-plugin" }
        }
      ))
      write(File.join(config_root, "settings.json"), JSON.generate(
        "enabledPlugins" => { "compound-engineering@compound-engineering-plugin" => false }
      ))

      row = Hive::AgentSkills::Inspector.new(
        config: config(bin: bin), project_root: dir, runner: FakeRunner.new,
        environment: { "HOME" => dir, "PATH" => "", "CLAUDE_CONFIG_DIR" => config_root },
        native_commands: false
      ).inspect(skills: [ "ce-brainstorm" ]).find { |entry| entry.capability_id == "ce-brainstorm" }

      assert_equal "missing", row.health
      assert_match(/disabled/, row.explanation)
      assert_equal false, row.native.dig("package", "enabled")
    end
  end

  def test_filesystem_only_inventory_reads_codex_and_pi_state_without_native_commands
    with_tmp_dir do |dir|
      runner = FakeRunner.new

      codex_bin = File.join(dir, "bin", "codex")
      executable(codex_bin)
      codex_root = File.join(dir, "codex")
      codex_install = File.join(
        codex_root, "plugins", "cache",
        "compound-engineering-plugin", "compound-engineering", "3.19.0"
      )
      write(File.join(codex_install, "skills", "ce-brainstorm", "SKILL.md"))
      write(File.join(codex_install, ".codex-plugin", "plugin.json"), JSON.generate("version" => "3.19.0"))
      write(File.join(codex_root, "config.toml"), <<~TOML)
        [features]
        enabled = ["unrelated", "values"]

        [marketplaces.compound-engineering-plugin]
        source = "https://github.com/EveryInc/compound-engineering-plugin.git"

        [plugins."compound-engineering@compound-engineering-plugin"]
        enabled = true
      TOML
      codex_row = Hive::AgentSkills::Inspector.new(
        config: config(agent: "codex", bin: codex_bin), project_root: dir, runner: runner,
        environment: { "HOME" => dir, "PATH" => "", "CODEX_HOME" => codex_root },
        native_commands: false
      ).inspect(skills: [ "ce-brainstorm" ]).find { |entry| entry.capability_id == "ce-brainstorm" }

      assert_equal "healthy", codex_row.health
      assert_equal "3.19.0", codex_row.native.dig("package", "version")

      pi_bin = File.join(dir, "bin", "pi")
      executable(pi_bin)
      pi_root = File.join(dir, "pi")
      pi_install = File.join(pi_root, "git", "github.com", "EveryInc", "compound-engineering-plugin")
      write(File.join(pi_install, "skills", "ce-brainstorm", "SKILL.md"))
      write(File.join(pi_install, "package.json"), JSON.generate(
        "version" => "3.19.0", "pi" => { "skills" => [ "./skills" ] }
      ))
      pi_row = Hive::AgentSkills::Inspector.new(
        config: config(agent: "pi", bin: pi_bin), project_root: dir, runner: runner,
        environment: { "HOME" => dir, "PATH" => "", "PI_CODING_AGENT_DIR" => pi_root },
        native_commands: false
      ).inspect(skills: [ "ce-brainstorm" ]).find { |entry| entry.capability_id == "ce-brainstorm" }

      assert_equal "healthy", pi_row.health
      assert_equal "3.19.0", pi_row.native.dig("package", "version")
      assert_empty runner.calls
    end
  end

  def test_command_runner_timeout_terminates_and_reaps_the_process_group
    with_tmp_dir do |dir|
      script = File.join(dir, "hang")
      pid_file = File.join(dir, "pids")
      File.write(script, <<~SH)
        #!/bin/sh
        trap '' TERM
        sleep 30 &
        child=$!
        printf '%s %s\n' "$$" "$child" > "$1"
        wait
      SH
      FileUtils.chmod(0o755, script)

      result = Hive::AgentSkills::CommandRunner.new.call([ script, pid_file ], timeout: 0.1)

      assert result.timed_out
      assert_match(/timed out/, result.error)
      pids = File.read(pid_file).split.map { |value| Integer(value, 10) }
      assert_equal 2, pids.size
      pids.each do |pid|
        process_state, _err, status = Open3.capture3("ps", "-o", "stat=", "-p", pid.to_s)
        running = status.success? && !process_state.lstrip.start_with?("Z")
        refute running, "timed-out provisioning pid #{pid} must not remain running"
      end
    end
  end

  def test_command_runner_classifies_spawn_errors
    result = Hive::AgentSkills::CommandRunner.new.call([ "/definitely/missing/hive-agent-skill-command" ])

    refute result.timed_out
    assert_match(/ENOENT/, result.error)
  end

  def test_command_runner_defensive_io_and_process_group_errors_are_bounded
    runner = Hive::AgentSkills::CommandRunner.new
    stdin = StringIO.new
    stdout = Object.new
    stdout.define_singleton_method(:read) { "" }
    stdout.define_singleton_method(:closed?) { false }
    stdout.define_singleton_method(:close) { raise IOError, "synthetic close failure" }
    stderr = StringIO.new
    status = Struct.new(:exitstatus).new(0)
    waiter = Object.new
    waiter.define_singleton_method(:alive?) { false }
    waiter.define_singleton_method(:value) { status }

    result = with_replaced_singleton_method(
      Open3, :popen3, ->(*_args, **_kwargs) { [ stdin, stdout, stderr, waiter ] }
    ) do
      runner.call([ "ignored" ])
    end
    assert result.success?

    unreadable = Object.new
    unreadable.define_singleton_method(:read) { raise IOError, "synthetic read failure" }
    assert_equal "", runner.send(:capture_reader, unreadable).value

    uncloseable = Object.new
    uncloseable.define_singleton_method(:closed?) { false }
    uncloseable.define_singleton_method(:close) { raise IOError, "synthetic close failure" }
    runner.send(:stop_readers, [], uncloseable)

    with_replaced_singleton_method(Process, :kill, ->(*_args) { raise Errno::ESRCH }) do
      assert_nil runner.send(:signal_process_group, "TERM", 123)
      refute runner.send(:process_group_alive?, 123)
    end
    with_replaced_singleton_method(Process, :kill, ->(*_args) { raise Errno::EPERM }) do
      assert runner.send(:process_group_alive?, 123)
    end
  end

  def test_target_resolver_covers_adhoc_patrol_filters_and_serialization
    cfg = config
    cfg["review"]["adhoc"] = {
      "reviewers" => [ { "name" => "", "kind" => "agent", "agent" => "claude", "skill" => "private-review" } ]
    }
    cfg["patrol"] = {
      "mode" => "medium",
      "review" => {
        "reviewers" => [ { "name" => "", "kind" => "codex_review", "agent" => "codex", "skill" => "" } ]
      }
    }
    resolver = Hive::AgentSkills::TargetResolver.new(config: cfg, project_root: "/tmp/project")

    targets = resolver.resolve
    assert targets.any? { |target| target.surfaces == [ "review.adhoc.reviewers[0]" ] }
    assert targets.any? { |target| target.surfaces == [ "patrol.review.reviewers[0]" ] }
    assert_equal "brainstorm", resolver.resolve(agents: [ "claude" ], skills: [ "ce-brainstorm" ]).first.to_h.fetch("surfaces").first
    wiki_targets = resolver.resolve(agents: [ "claude" ], skills: [ "wiki-plan" ])
    assert_equal %w[compound-engineering llm-wiki], wiki_targets.map(&:package_id).sort,
                 "a filtered package must retain its declared prerequisite"
    assert_raises(Hive::ConfigError) { resolver.resolve(agents: [ "ghost" ]) }
    assert_raises(Hive::ConfigError) { resolver.resolve(skills: [ "ghost-skill" ]) }
  end

  def test_target_resolver_rejects_a_prerequisite_without_an_agent_capability
    package = Struct.new(:prerequisites).new([ "missing-package" ])
    manifest = Object.new
    manifest.define_singleton_method(:package) { |_id| package }
    manifest.define_singleton_method(:capability_for_package) { |agent:, package_id:| nil }
    resolver = Hive::AgentSkills::TargetResolver.new(
      config: config, project_root: "/tmp/project", manifest: manifest
    )
    target = Hive::AgentSkills::Target.new(
      surfaces: [ "test" ], kind: "stage", agent: "codex",
      configured_skill: "dependent", invocation: "/dependent",
      capability_id: "dependent", package_id: "dependent-package", managed: true
    )

    error = assert_raises(Hive::ConfigError) do
      resolver.send(:with_prerequisites, [ target ])
    end
    assert_match(/missing-package.*no codex capability/, error.message)
  end

  def test_unmanaged_targets_are_inspected_when_available_or_unavailable
    with_tmp_dir do |dir|
      bin = File.join(dir, "bin", "claude")
      executable(bin)
      reviewer = { "name" => "private", "kind" => "agent", "agent" => "claude", "skill" => "private-review" }
      cfg = config(reviewers: [ reviewer ], bin: bin)
      inspector = Hive::AgentSkills::Inspector.new(
        config: cfg, project_root: dir, runner: FakeRunner.new,
        environment: { "HOME" => dir, "PATH" => "", "CLAUDE_CONFIG_DIR" => File.join(dir, ".claude") }
      )
      missing = inspector.inspect(skills: [ "private-review" ]).first
      assert_equal "missing", missing.health
      write(File.join(dir, ".claude", "skills", "private-review", "SKILL.md"))
      assert_equal "healthy", inspector.inspect(skills: [ "private-review" ]).first.health

      native_cfg = config(reviewers: [ { "name" => "lint", "kind" => "linter", "agent" => "", "skill" => "rubocop" } ])
      unavailable = Hive::AgentSkills::Inspector.new(
        config: native_cfg, project_root: dir, runner: FakeRunner.new,
        environment: { "HOME" => dir, "PATH" => "" }
      ).inspect(skills: [ "rubocop" ]).first
      assert_equal "unavailable", unavailable.health
    end
  end

  def test_grok_native_compound_engineering_reviewer_is_managed_and_healthy
    with_tmp_dir do |dir|
      bin = File.join(dir, "bin", "grok")
      executable(bin)
      grok_home = File.join(dir, ".grok")
      install = File.join(grok_home, "installed-plugins", "compound-engineering-plugin-abc123")
      write(File.join(install, "skills", "ce-code-review", "SKILL.md"))
      write(
        File.join(grok_home, "installed-plugins", "registry.json"),
        JSON.generate(
          "version" => 1,
          "repos" => {
            "compound-engineering-plugin-abc123" => {
              "path" => install,
              "plugins" => { "compound-engineering" => { "version" => "3.20.0" } }
            }
          }
        )
      )
      write(File.join(grok_home, "config.toml"), "[plugins]\nenabled = [\"compound-engineering\"]\n")
      reviewer = {
        "name" => "grok-ce", "kind" => "agent",
        "agent" => "grok", "skill" => "ce-code-review"
      }
      cfg = config(reviewers: [ reviewer ])
      cfg["agents"]["grok"]["bin"] = bin
      runner = FakeRunner.new(
        grok_responses(
          bin: bin,
          plugins: [
            {
              "status" => "installed",
              "name" => "compound-engineering",
              "version" => "3.20.0",
              "path" => install,
              "source" => "https://github.com/EveryInc/compound-engineering-plugin"
            }
          ],
          loaded_plugins: [
            { "name" => "compound-engineering", "path" => install, "enabled" => true }
          ]
        )
      )

      row = Hive::AgentSkills::Inspector.new(
        config: cfg, project_root: dir, runner: runner,
        environment: { "HOME" => dir, "PATH" => "", "GROK_HOME" => grok_home }
      ).inspect(skills: [ "ce-code-review" ]).first

      assert_equal true, row.managed
      assert_equal "healthy", row.health
      assert_equal "info", row.severity
      assert_equal "present", row.resolution.fetch("status")
      assert_equal install, row.native.dig("package", "install_path")
      assert_equal "hive setup-agents --agent grok --skill ce-code-review", row.remediation
    end
  end

  def test_grok_runtime_plugin_shadow_is_a_conflict
    with_tmp_dir do |dir|
      bin = File.join(dir, "bin", "grok")
      executable(bin)
      native = Hive::AgentSkills::Manifest.load.package("compound-engineering").native_for("grok")
      installed = File.join(dir, ".grok", "installed-plugins", "compound-engineering-plugin-abc123")
      shadow = File.join(dir, "project", ".grok", "plugins", "compound-engineering")
      runner = FakeRunner.new(
        grok_responses(
          bin: bin,
          plugins: [
            {
              "status" => "installed",
              "name" => native.package,
              "version" => "3.20.0",
              "path" => installed,
              "source" => native.source
            }
          ],
          loaded_plugins: [
            { "name" => native.package, "path" => shadow, "enabled" => true }
          ]
        )
      )
      cfg = config(agent: "grok", bin: bin)
      inspector = Hive::AgentSkills::Inspector.new(
        config: cfg,
        project_root: dir,
        runner: runner,
        environment: { "HOME" => dir, "PATH" => "", "GROK_HOME" => File.join(dir, ".grok") }
      )

      evidence = inspector.send(
        :inspect_native,
        profile: Hive::AgentProfiles.lookup("grok", cfg: cfg),
        bin: bin,
        native_spec: native
      )

      assert_match(/runtime plugin .* resolves from/, evidence.fetch("issues").first.last)
    end
  end

  def test_available_unmanaged_native_reviewer_is_non_blocking
    with_tmp_dir do |dir|
      bin = File.join(dir, "bin", "claude")
      executable(bin)
      reviewer = {
        "name" => "lint", "kind" => "linter",
        "agent" => "claude", "skill" => "rubocop"
      }
      cfg = config(reviewers: [ reviewer ], bin: bin)

      row = Hive::AgentSkills::Inspector.new(
        config: cfg, project_root: dir, runner: FakeRunner.new,
        environment: { "HOME" => dir, "PATH" => "" }
      ).inspect(skills: [ "rubocop" ]).first

      refute row.managed
      assert_equal "healthy", row.health
      assert_equal "info", row.severity
      assert_includes row.remediation, "native reviewer"
    end
  end

  def test_version_probe_failure_old_cli_disabled_package_and_invalid_package_version
    with_tmp_dir do |dir|
      bin = File.join(dir, "bin", "claude")
      executable(bin)
      cfg = config(bin: bin)
      cfg["plan"]["skill"] = "/ce-brainstorm"
      cache = File.join(dir, "claude", "plugins", "cache", "compound-engineering-plugin", "compound-engineering", "3.19.0")
      write(File.join(cache, "skills", "ce-brainstorm", "SKILL.md"))

      bad_version = claude_responses(bin: bin, plugins: [], marketplaces: [], version: "not-semver")
      row = inspect_rows(cfg: cfg, project: dir, runner: FakeRunner.new(bad_version),
                         environment: { "CLAUDE_CONFIG_DIR" => File.join(dir, "claude") }).first
      assert_equal "incompatible", row.health

      old_cli = claude_responses(bin: bin, plugins: [], marketplaces: [], version: "1.0.0")
      row = inspect_rows(cfg: cfg, project: dir, runner: FakeRunner.new(old_cli),
                         environment: { "CLAUDE_CONFIG_DIR" => File.join(dir, "claude") }).first
      assert_equal "incompatible", row.health

      %w[disabled invalid].each do |variant|
        version = variant == "invalid" ? "(" : "3.19.0"
        enabled = variant != "disabled"
        responses = claude_responses(
          bin: bin,
          plugins: [ { "id" => "compound-engineering@compound-engineering-plugin", "version" => version,
                       "enabled" => enabled, "installPath" => cache } ],
          marketplaces: [ { "name" => "compound-engineering-plugin", "repo" => "EveryInc/compound-engineering-plugin" } ]
        )
        row = inspect_rows(cfg: cfg, project: dir, runner: FakeRunner.new(responses),
                           environment: { "CLAUDE_CONFIG_DIR" => File.join(dir, "claude") }).first
        assert_equal variant == "disabled" ? "missing" : "incompatible", row.health
      end
    end
  end

  def test_native_codex_and_pi_inventory_contracts
    with_tmp_dir do |dir|
      manifest = Hive::AgentSkills::Manifest.load
      package = manifest.package("compound-engineering")

      codex_bin = File.join(dir, "bin", "codex")
      executable(codex_bin)
      codex_native = package.native_for("codex")
      codex_runner = FakeRunner.new(
        [ codex_bin, "--version" ] => result(stdout: "codex-cli 0.144.0"),
        [ codex_bin, "plugin", "list", "--available", "--json" ] => result(
          status: 1,
          stdout: JSON.generate("installed" => [
            {
              "pluginId" => codex_native.package,
              "version" => "3.19.0",
              "source" => { "url" => codex_native.source }
            }
          ])
        ),
        [ codex_bin, "plugin", "marketplace", "list", "--json" ] => result(
          status: 1,
          stdout: JSON.generate("marketplaces" => [
            {
              "name" => codex_native.marketplace,
              "marketplaceSource" => { "source" => codex_native.source }
            }
          ])
        )
      )
      codex = Hive::AgentSkills::Inspector.new(
        config: config(agent: "codex", bin: codex_bin),
        project_root: dir,
        runner: codex_runner,
        environment: { "HOME" => dir, "PATH" => "", "CODEX_HOME" => File.join(dir, "codex") }
      ).send(
        :inspect_native,
        profile: Hive::AgentProfiles.lookup("codex", cfg: config(agent: "codex", bin: codex_bin)),
        bin: codex_bin,
        native_spec: codex_native
      )

      assert_equal codex_native.package, codex.dig("package", "id")
      assert_equal codex_native.source, codex.dig("marketplace", "source")
      assert_equal 2, codex.fetch("issues").size

      pi_bin = File.join(dir, "bin", "pi")
      executable(pi_bin)
      pi_native = package.native_for("pi")
      pi_install = File.join(dir, "pi", "git", "compound-engineering")
      write(File.join(pi_install, "package.json"), JSON.generate("version" => "3.19.0"))
      pi_runner = FakeRunner.new(
        [ pi_bin, "--version" ] => result(stdout: "0.80.6"),
        [ pi_bin, "list" ] => result(
          status: 1,
          stdout: "User packages:\n  #{pi_native.source}\n    #{pi_install}\n"
        )
      )
      pi = Hive::AgentSkills::Inspector.new(
        config: config(agent: "pi", bin: pi_bin),
        project_root: dir,
        runner: pi_runner,
        environment: { "HOME" => dir, "PATH" => "", "PI_CODING_AGENT_DIR" => File.join(dir, "pi") }
      ).send(
        :inspect_native,
        profile: Hive::AgentProfiles.lookup("pi", cfg: config(agent: "pi", bin: pi_bin)),
        bin: pi_bin,
        native_spec: pi_native
      )

      assert_equal pi_native.package, pi.dig("package", "id")
      assert_equal "3.19.0", pi.dig("package", "version")
      assert_equal 1, pi.fetch("issues").size
    end
  end

  def test_inspector_defensive_provider_alias_source_and_path_helpers
    with_tmp_dir do |dir|
      bin = File.join(dir, "bin", "claude")
      executable(bin)
      cfg = config(bin: bin)
      runner = FakeRunner.new({ [ bin, "--version" ] => result(stdout: "2.1.179") })
      inspector = Hive::AgentSkills::Inspector.new(
        config: cfg, project_root: dir, runner: runner,
        environment: { "HOME" => dir, "PATH" => "", "CLAUDE_CONFIG_DIR" => File.join(dir, "claude") }
      )
      manifest = Hive::AgentSkills::Manifest.load
      package = manifest.package("compound-engineering")
      native = package.native_for("claude").with(provider: "future")
      profile = Hive::AgentProfiles.lookup("claude", cfg: cfg)
      evidence = inspector.send(:inspect_native, profile: profile, bin: bin, native_spec: native)
      assert_match(/unsupported provider/, evidence.fetch("issues").first.last)

      assert_raises(Hive::ConfigError) { inspector.send(:skill_module, "future") }
      source_issues = inspector.send(
        :source_issues, package.native_for("claude"),
        { "marketplace" => { "source" => "someone/private-marketplace" },
          "package" => { "source" => "someone/private" } }
      )
      assert_equal 2, source_issues.size
      assert_match(/marketplace .* is owned by/, source_issues.first.last)
      assert_match(/installed package source/, source_issues.last.last)
      missing_source = inspector.send(
        :source_issues, package.native_for("pi"),
        { "marketplace" => nil, "package" => { "source" => nil } }
      )
      assert_match(/source is unavailable/, missing_source.first.last)

      empty_package = File.join(dir, "empty-package")
      FileUtils.mkdir_p(empty_package)
      assert_nil inspector.send(:package_version_from, empty_package)
      write(File.join(empty_package, "package.json"), "{")
      assert_nil inspector.send(:package_version_from, empty_package)
      assert_equal File.join(dir, ".codex"), inspector.send(:config_root_for, manifest.package("compound-engineering").native_for("codex"))
      assert_equal File.join(dir, ".pi", "agent"), inspector.send(:config_root_for, manifest.package("compound-engineering").native_for("pi"))

      cfg["agents"]["claude"]["bin"] = "missing-bare-name"
      unavailable = Hive::AgentSkills::Inspector.new(
        config: cfg, project_root: dir, runner: FakeRunner.new,
        environment: { "HOME" => dir, "PATH" => "" }
      ).inspect.first
      assert_equal "unavailable", unavailable.health
    end
  end

  def test_alias_inspection_system_error_is_a_conflict
    with_tmp_dir do |dir|
      bin = File.join(dir, "bin", "claude")
      executable(bin)
      alias_path = File.join(dir, "claude", "commands", "plan.md")
      write(alias_path, "private")
      cfg = config(bin: bin)
      cfg["brainstorm"]["skill"] = "/plan"
      inspector = Hive::AgentSkills::Inspector.new(
        config: cfg, project_root: dir, runner: FakeRunner.new,
        environment: { "HOME" => dir, "PATH" => "", "CLAUDE_CONFIG_DIR" => File.join(dir, "claude") }
      )
      target = Hive::AgentSkills::TargetResolver.new(config: cfg, project_root: dir).resolve.find do |row|
        row.capability_id == "wiki-plan"
      end
      contract = Hive::AgentSkills::Manifest.load.capability("wiki-plan").agent("claude")
      original = File.method(:read)
      with_replaced_singleton_method(File, :read, lambda { |path, *args|
        raise Errno::EACCES, path if path == alias_path
        original.call(path, *args)
      }) do
        resolution = inspector.send(:inspect_resolution, target, contract, { "package" => nil })
        assert_match(/could not inspect alias/, resolution.fetch("issues").first.last)
      end
    end
  end
end
