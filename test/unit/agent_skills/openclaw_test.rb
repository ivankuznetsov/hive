require "test_helper"

require "hive/agent_skills/adapters/openclaw"

class AgentSkillsOpenClawTest < Minitest::Test
  include HiveTestHelper

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

  def write_clawhub_metadata(base:, lock_root:, canonical:)
    origin = {
      "version" => 1,
      "registry" => "https://clawhub.ai",
      "slug" => "hive-cli",
      "installedVersion" => canonical.skill_version,
      "skillFile" => {
        "path" => "SKILL.md",
        "sha256" => Digest::SHA256.file(File.join(base, "SKILL.md")).hexdigest
      }
    }
    FileUtils.mkdir_p(File.join(base, ".clawhub"), mode: 0o700)
    File.write(File.join(base, ".clawhub", "origin.json"), JSON.generate(origin))
    FileUtils.mkdir_p(File.join(lock_root, ".clawhub"), mode: 0o700)
    File.write(
      File.join(lock_root, ".clawhub", "lock.json"),
      JSON.generate("version" => 1, "skills" => {
        "hive-cli" => origin.reject { |key, _| %w[slug installedVersion].include?(key) }
          .merge("version" => origin.fetch("installedVersion"))
      })
    )
  end

  def inspect(home, bin)
    Hive::AgentSkills::Adapters::OpenClaw.new(
      environment: { "HOME" => home, "PATH" => "", "OPENCLAW_BIN" => bin }
    ).inspect
  end

  def test_healthy_clawhub_projection_is_verified_read_only
    with_tmp_dir do |home|
      bin = File.join(home, "bin", "openclaw")
      executable(bin)
      publisher, workspace, canonical = projection_at(home)
      publisher.publish(expected_snapshot: publisher.report.snapshot)
      write_clawhub_metadata(base: publisher.destination, lock_root: workspace, canonical: canonical)
      before = Digest::SHA256.file(File.join(publisher.destination, "SKILL.md")).hexdigest

      evidence = inspect(home, bin)

      assert_equal "healthy", evidence.health
      assert_equal "filesystem", evidence.native.fetch("inventory_source")
      assert_empty evidence.native.fetch("commands")
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
      write_clawhub_metadata(base: publisher.destination, lock_root: workspace, canonical: canonical)

      stale = inspect(home, bin)
      assert_equal "stale", stale.health
      assert_match(/predates canonical provenance/, stale.explanation)
      assert_equal "openclaw skills update @ivankuznetsov/hive-cli", stale.remediation

      File.open(skill, "a") { |file| file.write("user edit\n") }
      conflict = inspect(home, bin)
      assert_equal "conflicting", conflict.health
      assert_match(/will not replace/, conflict.explanation)
    end
  end

  def test_absent_cli_and_missing_skill_are_distinct_without_mutation
    with_tmp_dir do |home|
      unavailable = Hive::AgentSkills::Adapters::OpenClaw.new(
        environment: { "HOME" => home, "PATH" => "", "OPENCLAW_BIN" => File.join(home, "missing") }
      ).inspect
      assert_equal "unavailable", unavailable.health

      bin = File.join(home, "bin", "openclaw")
      executable(bin)
      publisher, workspace, canonical = projection_at(home)
      missing = inspect(home, bin)
      assert_equal "missing", missing.health
      assert_equal "openclaw skills install @ivankuznetsov/hive-cli", missing.remediation
      refute File.exist?(publisher.destination)
      assert_equal canonical.skill_version, missing.expected.fetch("version")
    end
  end

  def test_filesystem_only_inspection_verifies_clawhub_projection_without_commands
    with_tmp_dir do |home|
      bin = File.join(home, "bin", "openclaw")
      executable(bin)
      publisher, workspace, canonical = projection_at(home)
      publisher.publish(expected_snapshot: publisher.report.snapshot)
      write_clawhub_metadata(base: publisher.destination, lock_root: workspace, canonical: canonical)
      state = File.join(home, ".openclaw")
      File.write(File.join(state, "openclaw.json"), JSON.generate(
        "agents" => { "defaults" => { "workspace" => workspace } }
      ))
      evidence = Hive::AgentSkills::Adapters::OpenClaw.new(
        environment: { "HOME" => home, "PATH" => "", "OPENCLAW_BIN" => bin }
      ).inspect

      assert_equal "healthy", evidence.health
      assert_equal "filesystem", evidence.native.fetch("inventory_source")
      assert_equal canonical.skill_version, evidence.native.dig("clawhub", "installedVersion")
      assert_empty evidence.native.fetch("commands")
    end
  end

  def test_filesystem_only_inspection_accepts_openclaw_managed_skill_root
    with_tmp_dir do |home|
      bin = File.join(home, "bin", "openclaw")
      executable(bin)
      state = File.join(home, ".openclaw")
      workspace = File.join(state, "workspace")
      canonical = Hive::AgentSkills::CanonicalSkill.new.render("openclaw")
      relocated = Hive::AgentSkills::CanonicalSkill::Projection.new(
        platform: canonical.platform,
        invocation: canonical.invocation,
        destination_relative: "hive-cli",
        skill_version: canonical.skill_version,
        canonical_digest: canonical.canonical_digest,
        files: canonical.files
      ).freeze
      publisher = Hive::AgentSkills::DirectoryPublisher.new(
        root: File.join(state, "skills"), trusted_root: home, projection: relocated
      )
      publisher.publish(expected_snapshot: publisher.report.snapshot)
      write_clawhub_metadata(base: publisher.destination, lock_root: state, canonical: canonical)
      FileUtils.mkdir_p(workspace, mode: 0o700)
      File.write(File.join(state, "openclaw.json"), JSON.generate(
        "agents" => { "defaults" => { "workspace" => workspace } }
      ))

      evidence = Hive::AgentSkills::Adapters::OpenClaw.new(
        environment: { "HOME" => home, "PATH" => "", "OPENCLAW_BIN" => bin }
      ).inspect

      assert_equal "healthy", evidence.health
      assert_equal File.join(publisher.destination, "SKILL.md"), evidence.resolution.fetch("path")
    end
  end

  def test_multiple_filesystem_candidates_are_reported_as_conflicting
    with_tmp_dir do |home|
      bin = File.join(home, "bin", "openclaw")
      executable(bin)
      publisher, workspace, canonical = projection_at(home)
      publisher.publish(expected_snapshot: publisher.report.snapshot)
      write_clawhub_metadata(base: publisher.destination, lock_root: workspace, canonical: canonical)

      duplicate = File.join(home, ".openclaw", "skills", "hive", "SKILL.md")
      FileUtils.mkdir_p(File.dirname(duplicate), mode: 0o700)
      File.write(duplicate, canonical.files.fetch("SKILL.md"))

      evidence = inspect(home, bin)

      assert_equal "conflicting", evidence.health
      assert_match(/multiple OpenClaw Hive skill directories/, evidence.explanation)
      assert_equal 2, evidence.resolution.fetch("candidates").length
    end
  end

  def test_malformed_filesystem_inventory_is_incompatible
    with_tmp_dir do |home|
      bin = File.join(home, "bin", "openclaw")
      executable(bin)
      state = File.join(home, ".openclaw")
      FileUtils.mkdir_p(state, mode: 0o700)
      File.write(File.join(state, "openclaw.json"), "{")

      malformed = inspect(home, bin)
      assert_equal "incompatible", malformed.health
      assert_match(/filesystem inventory is malformed/, malformed.explanation)

      File.write(File.join(state, "openclaw.json"), JSON.generate([]))
      wrong_shape = inspect(home, bin)
      assert_equal "incompatible", wrong_shape.health
      assert_match(/must contain an object/, wrong_shape.explanation)
    end
  end

  def test_publisher_errors_are_reported_as_conflicting
    with_tmp_dir do |home|
      bin = File.join(home, "bin", "openclaw")
      executable(bin)
      adapter = Hive::AgentSkills::Adapters::OpenClaw.new(
        environment: { "HOME" => home, "PATH" => "", "OPENCLAW_BIN" => bin }
      )
      skill = File.join(home, ".openclaw", "workspace", "skills", "hive", "SKILL.md")
      FileUtils.mkdir_p(File.dirname(skill), mode: 0o700)
      File.write(skill, "---\nname: hive\n---\n")
      adapter.define_singleton_method(:projection_report) do |**|
        raise Hive::AgentSkills::DirectoryPublisher::Error, "unsafe OpenClaw skill directory"
      end

      evidence = adapter.inspect

      assert_equal "conflicting", evidence.health
      assert_equal "unsafe OpenClaw skill directory", evidence.explanation
    end
  end

  def test_valid_clawhub_metadata_with_old_version_is_stale
    with_tmp_dir do |home|
      bin = File.join(home, "bin", "openclaw")
      executable(bin)
      publisher, workspace, canonical = projection_at(home)
      publisher.publish(expected_snapshot: publisher.report.snapshot)
      write_clawhub_metadata(base: publisher.destination, lock_root: workspace, canonical: canonical)

      origin_path = File.join(publisher.destination, ".clawhub", "origin.json")
      origin = JSON.parse(File.read(origin_path))
      origin["installedVersion"] = "0.0.1"
      File.write(origin_path, JSON.generate(origin))
      lock_path = File.join(workspace, ".clawhub", "lock.json")
      lock = JSON.parse(File.read(lock_path))
      lock.dig("skills", "hive-cli")["version"] = "0.0.1"
      File.write(lock_path, JSON.generate(lock))

      evidence = inspect(home, bin)

      assert_equal "stale", evidence.health
      assert_match(/0\.0\.1 does not match/, evidence.explanation)
    end
  end

  def test_binary_resolution_searches_path_and_handles_a_path_miss
    with_tmp_dir do |home|
      bin = File.join(home, "bin", "openclaw")
      executable(bin)

      found = Hive::AgentSkills::Adapters::OpenClaw.new(
        environment: { "HOME" => home, "PATH" => File.dirname(bin) }
      ).inspect
      assert_equal "missing", found.health
      assert_equal bin, found.native.fetch("bin")

      missing = Hive::AgentSkills::Adapters::OpenClaw.new(
        environment: { "HOME" => home, "PATH" => "" }
      ).inspect
      assert_equal "unavailable", missing.health
    end
  end
end
