require "test_helper"

require "hive/agent_skills/adapters/openclaw"

class AgentSkillsOpenClawTest < Minitest::Test
  include HiveTestHelper

  class Runner
    def initialize(responses)
      @responses = responses
    end

    def call(argv, **)
      @responses.fetch(argv)
    end
  end

  def result(stdout: "", status: 0, stderr: "")
    Hive::AgentSkills::CommandResult.new(
      stdout: stdout, stderr: stderr, exit_status: status, error: nil, timed_out: false
    )
  end

  def executable(path)
    FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
    File.write(path, "#!/bin/sh\nexit 0\n")
    File.chmod(0o700, path)
  end

  def projection_at(home)
    canonical = Hive::AgentSkills::CanonicalSkill.new.render("openclaw")
    workspace = File.join(home, ".openclaw", "workspace")
    root = File.join(workspace, "skills")
    relocated = Hive::AgentSkills::CanonicalSkill::Projection.new(
      platform: canonical.platform,
      invocation: canonical.invocation,
      destination_relative: "hive-cli",
      skill_version: canonical.skill_version,
      canonical_digest: canonical.canonical_digest,
      files: canonical.files
    ).freeze
    publisher = Hive::AgentSkills::DirectoryPublisher.new(
      root: root, trusted_root: home, projection: relocated
    )
    [ publisher, workspace, canonical ]
  end

  def documents(publisher, workspace, canonical, skill_digest: nil)
    path = File.join(publisher.destination, "SKILL.md")
    list = {
      "workspaceDir" => workspace,
      "managedSkillsDir" => File.join(File.dirname(workspace), "skills"),
      "skills" => [ { "name" => "hive" } ]
    }
    info = {
      "name" => "hive",
      "filePath" => path,
      "baseDir" => publisher.destination,
      "source" => "openclaw-workspace",
      "eligible" => true,
      "userInvocable" => true,
      "clawhub" => {
        "status" => "linked",
        "valid" => true,
        "slug" => "hive-cli",
        "installedVersion" => canonical.skill_version,
        "skillFile" => {
          "path" => "SKILL.md",
          "sha256" => skill_digest || Digest::SHA256.file(path).hexdigest
        }
      }
    }
    [ list, info ]
  end

  def inspect(home, bin, list:, info:, info_status: 0)
    responses = {
      [ bin, "--version" ] => result(stdout: "OpenClaw 2026.7.1\n"),
      [ bin, "skills", "list", "--json" ] => result(stdout: JSON.generate(list)),
      [ bin, "skills", "info", "hive", "--json" ] => result(
        stdout: info_status.zero? ? JSON.generate(info) : "", status: info_status, stderr: "not found"
      )
    }
    Hive::AgentSkills::Adapters::OpenClaw.new(
      runner: Runner.new(responses),
      environment: { "HOME" => home, "PATH" => "", "OPENCLAW_BIN" => bin }
    ).inspect
  end

  def test_healthy_clawhub_projection_is_verified_read_only
    with_tmp_dir do |home|
      bin = File.join(home, "bin", "openclaw")
      executable(bin)
      publisher, workspace, canonical = projection_at(home)
      publisher.publish(expected_snapshot: publisher.report.snapshot)
      list, info = documents(publisher, workspace, canonical)
      before = Digest::SHA256.file(File.join(publisher.destination, "SKILL.md")).hexdigest

      evidence = inspect(home, bin, list: list, info: info)

      assert_equal "healthy", evidence.health
      assert_equal "healthy", evidence.native.dig("projection", "state")
      assert_equal canonical.canonical_digest,
                   evidence.native.dig("projection", "manifest", "canonical_digest")
      assert_equal before, Digest::SHA256.file(File.join(publisher.destination, "SKILL.md")).hexdigest
    end
  end

  def test_linked_legacy_clawhub_skill_is_stale_and_user_drift_conflicts
    with_tmp_dir do |home|
      bin = File.join(home, "bin", "openclaw")
      executable(bin)
      publisher, workspace, canonical = projection_at(home)
      FileUtils.mkdir_p(publisher.destination, mode: 0o700)
      skill = File.join(publisher.destination, "SKILL.md")
      File.write(skill, canonical.files.fetch("SKILL.md"))
      File.chmod(0o600, skill)
      list, info = documents(publisher, workspace, canonical)

      stale = inspect(home, bin, list: list, info: info)
      assert_equal "stale", stale.health
      assert_match(/predates canonical provenance/, stale.explanation)
      assert_equal "openclaw skills update @ivankuznetsov/hive-cli", stale.remediation

      File.open(skill, "a") { |file| file.write("user edit\n") }
      conflict = inspect(home, bin, list: list, info: info)
      assert_equal "conflicting", conflict.health
      assert_match(/will not replace/, conflict.explanation)
    end
  end

  def test_absent_cli_and_missing_skill_are_distinct_without_mutation
    with_tmp_dir do |home|
      unavailable = Hive::AgentSkills::Adapters::OpenClaw.new(
        runner: Runner.new({}),
        environment: { "HOME" => home, "PATH" => "", "OPENCLAW_BIN" => File.join(home, "missing") }
      ).inspect
      assert_equal "unavailable", unavailable.health

      bin = File.join(home, "bin", "openclaw")
      executable(bin)
      publisher, workspace, canonical = projection_at(home)
      list = { "workspaceDir" => workspace, "managedSkillsDir" => File.join(home, ".openclaw", "skills"), "skills" => [] }
      missing = inspect(home, bin, list: list, info: {}, info_status: 1)
      assert_equal "missing", missing.health
      assert_equal "openclaw skills install @ivankuznetsov/hive-cli", missing.remediation
      refute File.exist?(publisher.destination)
      assert_equal canonical.skill_version, missing.expected.fetch("version")
    end
  end
end
