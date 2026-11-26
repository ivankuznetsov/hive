require "test_helper"

require "hive/agent_skills/inspector"
require "hive/agent_skills/provisioner"

# The canonical Hive operating skill projected for Antigravity CLI (`agy`):
# rendering, manifest wiring, and a full inspect -> publish -> healthy cycle
# into ~/.gemini/config/skills/hive.
class AgentSkillsAgySkillTest < Minitest::Test
  include HiveTestHelper

  FAKE_BIN = File.expand_path("../../fixtures/fake-agy", __dir__)

  class Runner
    attr_reader :calls

    def initialize(responses)
      @responses = responses
      @calls = []
    end

    def call(argv, **)
      @calls << argv
      @responses.fetch(argv)
    end
  end

  def result(stdout:)
    Hive::AgentSkills::CommandResult.new(
      stdout: stdout, stderr: "", exit_status: 0, error: nil, timed_out: false
    )
  end

  def config
    cfg = Marshal.load(Marshal.dump(Hive::Config::DEFAULTS))
    cfg["project_root"] = nil
    cfg["agents"]["agy"]["bin"] = FAKE_BIN
    cfg
  end

  def environment(home)
    {
      "HOME" => home,
      "PATH" => ""
    }
  end

  def test_agy_projection_renders_with_platform_wrapper
    projection = Hive::AgentSkills.render("agy")

    assert_equal "agy", projection.platform
    assert_equal "/hive", projection.invocation
    assert_equal "skills/hive", projection.destination_relative
    skill = projection.files.fetch("SKILL.md")
    assert_includes skill, "name: hive"
    assert_includes skill, "platform: agy"
    assert_includes skill, "Invoke this projection as `/hive`."
    assert_equal Hive::AgentSkills::CanonicalSkill.new.canonical_digest,
                 projection.canonical_digest
  end

  def test_manifest_declares_agy_operating_and_compound_engineering_skills
    manifest = Hive::AgentSkills::Manifest.load

    assert_equal "/hive", manifest.capability("hive").agent("agy").invocation
    assert_equal "agy", manifest.package("hive-operations").native_for("agy").provider
    native = manifest.package("compound-engineering").native_for("agy")
    assert_equal "compound-engineering", native.package
    assert_equal "https://github.com/EveryInc/compound-engineering-plugin.git",
                 native.source
    assert_equal "ce-plan",
                 manifest.capability_for(agent: "agy", invocation: "/ce-plan").id
  end

  def test_provisioner_publishes_agy_skill_into_gemini_config_skills
    with_tmp_dir do |home|
      project = File.join(home, "project")
      Dir.mkdir(project, 0o700)
      runner = Runner.new(
        [ FAKE_BIN, "--version" ] => result(stdout: "1.5.17\n")
      )
      provisioner = Hive::AgentSkills::Provisioner.new(
        config: config, project_root: project, runner: runner,
        environment: environment(home)
      )

      plan = provisioner.build_plan(agents: [ "agy" ], skills: [ "hive" ])
      assert_equal 1, plan.operations.size
      operation = plan.operations.fetch(0)
      assert_equal "bundled_skill_publish", operation.kind
      assert_equal "agy", operation.agent

      outcome = provisioner.execute(plan, consent_provenance: "test")
      assert_equal 0, outcome.exit_code
      assert_equal "healthy", outcome.final_health.fetch(0).health

      destination = File.join(
        home, ".gemini", "config", "skills", "hive", "SKILL.md"
      )
      assert File.file?(destination), "expected projected skill at #{destination}"
      assert_includes File.read(destination), "platform: agy"
      assert_empty provisioner.build_plan(agents: [ "agy" ], skills: [ "hive" ]).operations
    end
  end

  def test_inspector_reports_missing_agy_skill_without_touching_state
    with_tmp_dir do |home|
      project = File.join(home, "project")
      Dir.mkdir(project, 0o700)
      runner = Runner.new(
        [ FAKE_BIN, "--version" ] => result(stdout: "1.5.17\n")
      )
      row = Hive::AgentSkills::Inspector.new(
        config: config, project_root: project, runner: runner,
        environment: environment(home)
      ).inspect(agents: [ "agy" ], skills: [ "hive" ]).fetch(0)

      assert_equal "missing", row.health
      refute File.exist?(File.join(home, ".gemini", "config", "skills"))
    end
  end
end
