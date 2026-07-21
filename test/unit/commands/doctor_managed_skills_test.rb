require "test_helper"
require "digest"
require "fileutils"
require "json"
require "stringio"
require "hive/commands/doctor"

class HiveCommandsDoctorManagedSkillsTest < Minitest::Test
  include HiveTestHelper

  def base_config
    {
      "claude" => { "mode" => "headless" },
      "brainstorm" => { "agent" => "claude" },
      "plan" => { "agent" => "claude" }
    }
  end

  def test_v2_managed_health_reports_unavailable_as_non_blocking_and_exact_remediation
    unavailable_target = Hive::AgentSkills::Target.new(
      surfaces: [ "brainstorm" ], kind: "stage", agent: "claude",
      configured_skill: "/ce-brainstorm", invocation: "/ce-brainstorm",
      capability_id: "ce-brainstorm", package_id: "compound-engineering", managed: true
    )
    unavailable = Hive::AgentSkills::Inspection.new(
      target: unavailable_target,
      expected: { "package" => "compound-engineering@compound-engineering-plugin" },
      native: { "available" => false }, resolution: { "path" => nil },
      health: "unavailable", severity: "warning", explanation: "claude is absent",
      remediation: "hive setup-agents --agent claude --skill ce-brainstorm"
    )
    inspector = Struct.new(:rows) { def inspect = rows }.new([ unavailable ])
    out = StringIO.new

    exit_code = Hive::Commands::Doctor.new(
      config: base_config,
      project_root: nil,
      json: true,
      output: out,
      inspector: inspector
    ).call

    assert_equal 0, exit_code
    payload = JSON.parse(out.string)
    assert_equal "hive-doctor.v2", payload.fetch("schema")
    assert_equal 1, payload.dig("summary", "managed", "unavailable")
    assert_equal "hive setup-agents --agent claude --skill ce-brainstorm",
                 payload.dig("managed_skills", 0, "remediation")
  end

  def test_v2_conflict_is_actionable_and_preserves_winning_path_evidence
    target = Hive::AgentSkills::Target.new(
      surfaces: [ "plan" ], kind: "stage", agent: "claude",
      configured_skill: "/plan", invocation: "/plan",
      capability_id: "wiki-plan", package_id: "llm-wiki", managed: true
    )
    conflict = Hive::AgentSkills::Inspection.new(
      target: target, expected: { "package" => "llm-wiki@aikuznetsov-marketplace" },
      native: { "available" => true },
      resolution: { "path" => "/repo/.claude/commands/plan.md" },
      health: "conflicting", severity: "error",
      explanation: "user-owned alias /repo/.claude/commands/plan.md wins; Hive will not replace it",
      remediation: "hive setup-agents --agent claude --skill wiki-plan"
    )
    inspector = Struct.new(:rows) { def inspect = rows }.new([ conflict ])
    out = StringIO.new

    exit_code = Hive::Commands::Doctor.new(
      config: base_config, project_root: nil, output: out, inspector: inspector
    ).call

    assert_equal Hive::Commands::Doctor::EXIT_MISSING_SKILL, exit_code
    assert_includes out.string, "/repo/.claude/commands/plan.md"
    assert_includes out.string, "Hive will not replace it"
  end

  def test_doctor_requests_read_only_openclaw_evidence_from_default_inspector
    captured = nil
    fake = Struct.new(:rows) { def inspect = rows }.new([])
    replacement = lambda do |**kwargs|
      captured = kwargs
      fake
    end

    with_replaced_singleton_method(Hive::AgentSkills::Inspector, :new, replacement) do
      Hive::Commands::Doctor.new(
        config: base_config, project_root: nil, output: StringIO.new
      ).call
    end

    assert_equal true, captured.fetch(:include_openclaw)
    assert_equal false, captured.fetch(:native_commands)
  end

  def test_default_doctor_does_not_invoke_agent_inventory_commands
    with_tmp_dir do |home|
      bin_dir = File.join(home, "bin")
      FileUtils.mkdir_p(bin_dir)
      bins = %w[claude codex pi openclaw].to_h do |name|
        path = File.join(bin_dir, name)
        File.write(path, <<~SH)
          #!/bin/sh
          printf '%s\n' #{name} > #{File.join(home, "native-command-ran")}
          exit 0
        SH
        FileUtils.chmod(0o700, path)
        [ name, path ]
      end
      marker = File.join(home, "native-command-ran")
      cfg = Marshal.load(Marshal.dump(Hive::Config::DEFAULTS))
      %w[claude codex pi].each { |agent| cfg.fetch("agents").fetch(agent)["bin"] = bins.fetch(agent) }
      snapshot = lambda do
        Dir.glob(File.join(home, "**", "*"), File::FNM_DOTMATCH).sort.to_h do |path|
          next [ path, [ "directory", File.stat(path).mode & 0o777 ] ] if File.directory?(path)

          [ path, [ "file", File.stat(path).mode & 0o777, Digest::SHA256.file(path).hexdigest ] ]
        end
      end
      before = snapshot.call

      exit_code = Hive::Commands::Doctor.new(
        config: cfg,
        project_root: nil,
        json: true,
        output: StringIO.new,
        environment: {
          "HOME" => home,
          "PATH" => bin_dir,
          "CLAUDE_CONFIG_DIR" => File.join(home, "claude"),
          "CODEX_HOME" => File.join(home, "codex"),
          "PI_CODING_AGENT_DIR" => File.join(home, "pi"),
          "OPENCLAW_BIN" => bins.fetch("openclaw"),
          "OPENCLAW_STATE_DIR" => File.join(home, "openclaw")
        }
      ).call

      assert_equal Hive::Commands::Doctor::EXIT_MISSING_SKILL, exit_code
      refute File.exist?(marker)
      assert_equal before, snapshot.call
    end
  end

  def test_openclaw_drift_is_actionable_but_never_setup_managed
    target = Hive::AgentSkills::Target.new(
      surfaces: [ "hive.operations" ], kind: "openclaw", agent: "openclaw",
      configured_skill: "hive", invocation: "/hive", capability_id: "hive",
      package_id: "hive-operations", managed: false
    )
    row = Hive::AgentSkills::Inspection.new(
      target: target,
      expected: { "distribution" => "clawhub", "version" => "0.1.2" },
      native: { "available" => true, "clawhub" => { "installedVersion" => "0.1.1" } },
      resolution: { "path" => "/home/me/.openclaw/workspace/skills/hive-cli/SKILL.md" },
      health: "stale", severity: "warning", explanation: "ClawHub Hive skill is stale",
      remediation: "openclaw skills update @ivankuznetsov/hive-cli"
    )
    inspector = Struct.new(:rows) { def inspect = rows }.new([ row ])
    output = StringIO.new

    exit_code = Hive::Commands::Doctor.new(
      config: base_config, project_root: nil, output: output, inspector: inspector
    ).call

    assert_equal Hive::Commands::Doctor::EXIT_MISSING_SKILL, exit_code
    assert_includes output.string, "openclaw skills update @ivankuznetsov/hive-cli"
    refute row.managed
  end
end
