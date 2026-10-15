require "test_helper"
require "json"
require "json_schemer"
require "stringio"
require "hive/commands/doctor"
require "hive/mcp/doctor_check"

class McpDoctorCheckTest < Minitest::Test
  include HiveTestHelper

  Candidate = Hive::Mcp::Discovery::Candidate

  CATALOG = {
    "linear" => { "url" => "https://mcp.linear.app/mcp", "oauth_logins" => [ "codex" ] },
    "internal" => { "url" => "https://internal.example/mcp", "bearer_token_env" => "INTERNAL_TOKEN", "imported_from" => "codex" },
    "gone" => { "command" => "gone", "imported_from" => "pi" }
  }.freeze

  def with_project(project, catalog: CATALOG, codex_config: nil)
    with_tmp_global_config(runtime: false) do |home|
      File.write(File.join(home, "config.yml"),
                 { "registered_projects" => [], "mcp" => { "servers" => catalog } }.to_yaml)
      with_tmp_dir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".hive-state"))
        File.write(File.join(dir, ".hive-state", "config.yml"), project.to_yaml)
        codex_home = File.join(dir, "codex")
        FileUtils.mkdir_p(codex_home)
        File.write(File.join(codex_home, "config.toml"), codex_config) if codex_config
        with_env("CODEX_HOME" => codex_home) { yield Hive::Config.load(dir), dir }
      end
    end
  end

  def discover_stub
    lambda do |_root|
      Hive::Mcp::Discovery::Result.new(
        candidates: [
          Candidate.new(name: "notion", agent: "claude", spec: { "url" => "https://mcp.notion.com/mcp" },
                        oauth: false, logged_in: false, exports: [], refusal: nil),
          Candidate.new(name: "internal", agent: "codex", spec: { "url" => "https://moved.example/mcp" },
                        oauth: false, logged_in: false, exports: [], refusal: nil)
        ],
        notices: []
      )
    end
  end

  def with_reviewers(config, *reviewers)
    config.merge("review" => config.fetch("review").merge("reviewers" => reviewers))
  end

  def rows(config, environment: {}, discover: nil, root: Dir.pwd)
    Hive::Mcp::DoctorCheck.rows(config: config, environment: environment, project_root: root, discover: discover)
  end

  def test_each_row_kind_and_env_values_never_printed
    project = {
      "mcp" => { "use" => %w[linear internal] },
      "review" => { "fix" => { "agent" => "grok" } },
      "execute" => { "agent" => "claude" }
    }
    with_project(project, codex_config: %(model = "gpt-5.6"\nservice_tier = "flex"\n[profiles.work]\nmodel = "x"\n)) do |config, dir|
      config = with_reviewers(config, { "name" => "pi-r", "agent" => "pi" }, "not-a-spec")
      found = rows(config, environment: { "OTHER" => "sekret-value", "CODEX_HOME" => ENV.fetch("CODEX_HOME") }, discover: discover_stub, root: dir)
      by_label = found.group_by { |row| row[:label] }

      assert(by_label.fetch("mcp/grok").any? { |row| row[:configured_skill] == "review.fix" })
      assert(by_label.fetch("mcp/pi").any? { |row| row[:message].include?("Pi runs review") })
      login = by_label.fetch("mcp/login").find { |row| row[:agent] == "claude" && row[:configured_skill] == "execute" }
      assert_includes login[:message], "run `hive mcp login linear --agent claude`"
      assert_equal [ "INTERNAL_TOKEN" ], by_label.fetch("mcp/env").map { |row| row[:skill] }
      codex = by_label.fetch("mcp/codex-config").first
      assert_equal "present", codex[:status]
      assert_equal "model,service_tier,profiles", codex[:skill]
      assert_includes by_label.fetch("mcp/personal").first[:message], "notion; run `hive mcp import`"
      drift = by_label.fetch("mcp/drift").map { |row| row[:skill] }
      assert_equal %w[gone internal], drift.sort
      refute_match(/sekret/, JSON.generate(found))
    end
  end

  def test_inherit_user_and_unreadable_catalog_short_circuit
    with_project({ "mcp" => { "inherit_user" => true } }) do |config|
      found = rows(config, discover: ->(_root) { raise "not called" })
      assert_equal [ "mcp/isolation" ], found.map { |row| row[:label] }
    end

    with_project({}) do |config|
      path = Hive::Config.global_config_path
      File.chmod(0o000, path)
      skip "running as root" if File.readable?(path)

      assert_equal [ "mcp/catalog" ], rows(config).map { |row| row[:label] }
    ensure
      File.chmod(0o600, path) if path
    end
  end

  def test_quiet_when_nothing_is_granted_or_configured
    with_project({}) do |config|
      assert_empty rows(config, environment: {})
    end
  end

  def test_doctor_json_validates_and_exit_code_ignores_mcp_warnings
    with_project({ "mcp" => { "use" => %w[internal] } }) do |config, dir|
      out = StringIO.new
      inspector = Struct.new(:inspect).new([])
      code = Hive::Commands::Doctor.new(
        config: config, project_root: dir, json: true, output: out, inspector: inspector,
        environment: {}, mcp_discover: discover_stub
      ).call
      payload = JSON.parse(out.string)
      schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-doctor"))))

      assert_equal 0, code
      assert_empty schemer.validate(payload).to_a
      assert(payload.fetch("checks").any? { |row| row["label"] == "mcp/env" })
    end
  end

  def test_doctor_default_discovery_runs_outside_tests
    with_project({}) do |config, dir|
      called = []
      fake = ->(cwd:) { called << cwd; Hive::Mcp::Discovery::Result.new(candidates: [], notices: []) }
      with_replaced_singleton_method(Hive::Mcp::Discovery, :discover, fake) do
        Hive::Commands::Doctor.new(
          config: config, project_root: dir, output: StringIO.new, inspector: Struct.new(:inspect).new([]),
          environment: {}, mcp_discover: :default
        ).call
      end
      assert_equal [ dir ], called
    end
  end

  def test_roles_cover_configured_agents_and_reviewers
    with_project({ "babysitter" => { "agent" => "codex" } }) do |config|
      config = with_reviewers(config, { "name" => "x", "agent" => "opencode" })
      roles = Hive::Mcp::DoctorCheck.roles(config)
      assert_includes roles, [ "babysitter", "codex" ]
      assert_includes roles, [ "review", "opencode" ]
      assert_includes roles, [ "artifacts.evidence.producer", config.dig("artifacts", "evidence", "producer", "agent") || "claude" ]
    end
  end
end
