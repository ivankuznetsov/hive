require "test_helper"

require "hive/agent_skills/inspector"
require "hive/agent_skills/directory_publisher"
require "hive/agent_skills/provisioner"

class AgentSkillsBundledSkillTest < Minitest::Test
  include HiveTestHelper

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

  def result(stdout: "", status: 0)
    Hive::AgentSkills::CommandResult.new(
      stdout: stdout, stderr: "", exit_status: status, error: nil, timed_out: false
    )
  end

  def config(bin)
    cfg = Marshal.load(Marshal.dump(Hive::Config::DEFAULTS))
    cfg["project_root"] = nil
    cfg["agents"]["claude"]["bin"] = bin
    cfg
  end

  def inspect_hive(home:, project:, bin:, runner:)
    Hive::AgentSkills::Inspector.new(
      config: config(bin), project_root: project, runner: runner,
      environment: {
        "HOME" => home,
        "PATH" => "",
        "CLAUDE_CONFIG_DIR" => File.join(home, ".claude")
      }
    ).inspect(agents: [ "claude" ], skills: [ "hive" ]).fetch(0)
  end

  def make_executable(path)
    FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
    File.write(path, "#!/bin/sh\nexit 0\n")
    File.chmod(0o700, path)
  end

  def publisher(home, hive_version: Hive::VERSION)
    Hive::AgentSkills::DirectoryPublisher.new(
      root: File.join(home, ".claude"),
      trusted_root: home,
      projection: Hive::AgentSkills::CanonicalSkill.new(hive_version: hive_version).render("claude")
    )
  end

  def publish(target)
    target.publish(expected_snapshot: target.report.snapshot)
  end

  def test_missing_and_healthy_bundled_skill_have_provenance_and_exact_resolution
    with_tmp_dir do |home|
      project = File.join(home, "project")
      Dir.mkdir(project, 0o700)
      bin = File.join(home, "bin", "claude")
      make_executable(bin)
      runner = Runner.new([ bin, "--version" ] => result(stdout: "2.1.179\n"))

      missing = inspect_hive(home: home, project: project, bin: bin, runner: runner)
      assert_equal "missing", missing.health
      assert_equal "bundled", missing.expected.fetch("distribution")
      assert_equal "absent", missing.native.dig("projection", "state")
      refute File.exist?(File.join(home, ".claude"))

      publish(publisher(home))
      healthy = inspect_hive(home: home, project: project, bin: bin, runner: runner)
      assert_equal "healthy", healthy.health
      assert_equal "healthy", healthy.native.dig("projection", "state")
      assert_equal Hive::AgentSkills::CanonicalSkill.new.canonical_digest,
                   healthy.native.dig("projection", "manifest", "canonical_digest")
      assert_equal File.join(home, ".claude", "skills", "hive", "SKILL.md"),
                   healthy.resolution.fetch("path")
    end
  end

  def test_intact_old_projection_is_stale_but_modified_content_conflicts
    with_tmp_dir do |home|
      project = File.join(home, "project")
      Dir.mkdir(project, 0o700)
      bin = File.join(home, "bin", "claude")
      make_executable(bin)
      runner = Runner.new([ bin, "--version" ] => result(stdout: "2.1.179\n"))
      publish(publisher(home, hive_version: "0.0.1"))

      stale = inspect_hive(home: home, project: project, bin: bin, runner: runner)
      assert_equal "stale", stale.health
      assert_match(/canonical/, stale.explanation)

      File.open(File.join(home, ".claude", "skills", "hive", "SKILL.md"), "a") do |file|
        file.write("private edit\n")
      end
      conflict = inspect_hive(home: home, project: project, bin: bin, runner: runner)
      assert_equal "conflicting", conflict.health
      assert_match(/will not replace/, conflict.explanation)
    end
  end

  def test_project_shadow_and_orphan_publish_state_conflict
    with_tmp_dir do |home|
      project = File.join(home, "project")
      Dir.mkdir(project, 0o700)
      bin = File.join(home, "bin", "claude")
      make_executable(bin)
      runner = Runner.new([ bin, "--version" ] => result(stdout: "2.1.179\n"))
      target = publisher(home)
      publish(target)
      shadow = File.join(project, ".claude", "skills", "hive", "SKILL.md")
      FileUtils.mkdir_p(File.dirname(shadow), mode: 0o700)
      File.write(shadow, "---\nname: hive\ndescription: private\n---\n")

      conflict = inspect_hive(home: home, project: project, bin: bin, runner: runner)
      assert_equal "conflicting", conflict.health
      assert_match(/higher-precedence/, conflict.explanation)

      FileUtils.rm_rf(File.join(project, ".claude"))
      orphan = File.join(target.parent, "#{Hive::AgentSkills::DirectoryPublisher::STAGE_PREFIX}claude-crash")
      Dir.mkdir(orphan, 0o700)
      conflict = inspect_hive(home: home, project: project, bin: bin, runner: runner)
      assert_equal "conflicting", conflict.health
      assert_includes conflict.explanation, orphan
    end
  end

  def test_absent_agent_binary_is_visible_and_does_not_touch_user_state
    with_tmp_dir do |home|
      project = File.join(home, "project")
      Dir.mkdir(project, 0o700)
      runner = Runner.new({})
      row = inspect_hive(
        home: home, project: project, bin: File.join(home, "missing-claude"), runner: runner
      )

      assert_equal "unavailable", row.health
      assert_empty runner.calls
      refute File.exist?(File.join(home, ".claude"))
    end
  end

  def test_provisioner_uses_one_directory_operation_and_second_run_is_noop
    with_tmp_dir do |home|
      project = File.join(home, "project")
      Dir.mkdir(project, 0o700)
      bin = File.join(home, "bin", "claude")
      make_executable(bin)
      runner = Runner.new([ bin, "--version" ] => result(stdout: "2.1.179\n"))
      env = {
        "HOME" => home,
        "PATH" => "",
        "CLAUDE_CONFIG_DIR" => File.join(home, ".claude")
      }
      provisioner = Hive::AgentSkills::Provisioner.new(
        config: config(bin), project_root: project, runner: runner, environment: env
      )

      plan = provisioner.build_plan(agents: [ "claude" ], skills: [ "hive" ])
      assert_equal 1, plan.operations.size
      operation = plan.operations.fetch(0)
      assert_equal "bundled_skill_publish", operation.kind
      assert_empty operation.argv
      assert_equal "absent", operation.preconditions.dig("directory", "state")

      result = provisioner.execute(plan, consent_provenance: "test")
      assert_equal 0, result.exit_code
      assert_equal "succeeded", result.operation_results.fetch(0).status
      assert_equal "healthy", result.final_health.fetch(0).health
      assert_empty provisioner.build_plan(agents: [ "claude" ], skills: [ "hive" ]).operations
    end
  end

  def test_bundled_skill_root_outside_home_is_a_conflict
    with_tmp_dir do |home|
      project = File.join(home, "project")
      Dir.mkdir(project, 0o700)
      bin = File.join(home, "bin", "claude")
      make_executable(bin)
      outside = File.join(File.dirname(home), "outside-claude-#{Process.pid}")
      inspector = Hive::AgentSkills::Inspector.new(
        config: config(bin), project_root: project,
        runner: Runner.new([ bin, "--version" ] => result(stdout: "2.1.179\n")),
        environment: { "HOME" => home, "PATH" => "", "CLAUDE_CONFIG_DIR" => outside }
      )

      row = inspector.inspect(agents: [ "claude" ], skills: [ "hive" ]).fetch(0)

      assert_equal "conflicting", row.health
      assert_match(/beneath the trusted user root/, row.explanation)
    ensure
      FileUtils.rm_rf(outside) if outside
    end
  end

  def test_bundled_resolution_reports_missing_and_system_errors
    with_tmp_dir do |home|
      project = File.join(home, "project")
      destination = File.join(home, ".claude", "skills", "hive")
      FileUtils.mkdir_p(destination, mode: 0o700)
      bin = File.join(home, "bin", "claude")
      make_executable(bin)
      inspector = Hive::AgentSkills::Inspector.new(
        config: config(bin), project_root: project, runner: Runner.new({}),
        environment: { "HOME" => home, "PATH" => "", "CLAUDE_CONFIG_DIR" => File.join(home, ".claude") }
      )
      target = Hive::AgentSkills::TargetResolver.new(
        config: config(bin), project_root: project
      ).resolve(agents: [ "claude" ], skills: [ "hive" ]).fetch(0)
      contract = Hive::AgentSkills::Manifest.load.capability("hive").agent("claude")
      resolver = Object.new
      resolver.define_singleton_method(:resolve) do |*|
        Hive::SkillCheck::Resolution.new(
          status: :missing, path: nil, message: "not resolved", candidates: [], parse_errors: []
        )
      end
      inspector.define_singleton_method(:skill_module) { |_| resolver }

      missing = inspector.send(:inspect_bundled_resolution, target, contract, destination)
      assert_match(/installed Hive operating skill does not resolve/, missing.fetch("issues").first.last)

      resolver.define_singleton_method(:resolve) { |*| raise Errno::EACCES, destination }
      failure = inspector.send(:inspect_bundled_resolution, target, contract, destination)
      assert_equal "missing", failure.fetch("status")
      assert_match(/could not inspect bundled skill resolution/, failure.fetch("issues").first.last)
    end
  end
end
