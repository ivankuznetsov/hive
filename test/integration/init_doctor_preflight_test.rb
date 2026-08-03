require "test_helper"
require "fileutils"
require "hive/commands/init"
require "hive/agent_skills/inspector"
require "hive/agent_skills/canonical_skill"
require "hive/agent_skills/directory_publisher"

# Verifies the non-fatal skill preflight that runs at the end of
# `Hive::Commands::Init#call`. Composes the existing init test
# scaffolding (`with_tmp_global_config` + `with_tmp_git_repo`) with
# the HOME-stub pattern from `test/unit/commands/doctor_test.rb` so
# the doctor's filesystem probe is deterministic.
class InitDoctorPreflightTest < Minitest::Test
  include HiveTestHelper

  class ResolutionInspector
    def initialize(config:, project_root:)
      @config = config
      @project_root = project_root
    end

    def inspect
      Hive::AgentSkills::TargetResolver.new(config: @config, project_root: @project_root).resolve.map do |target|
        resolver = case target.agent
        when "claude" then Hive::SkillCheck::Claude
        when "codex" then Hive::SkillCheck::Codex
        when "pi" then Hive::SkillCheck::Pi
        end
        found = resolver.resolve(target.invocation, project_root: @project_root)
        health = found.status == :present ? "healthy" : "missing"
        Hive::AgentSkills::Inspection.new(
          target: target, expected: {}, native: { "available" => true },
          resolution: { "path" => found.path }, health: health,
          severity: health == "healthy" ? "info" : "error", explanation: found.message,
          remediation: "hive setup-agents --agent #{target.agent} --skill #{target.capability_id}"
        )
      end
    end
  end

  def with_fake_home
    with_tmp_dir do |dir|
      old = ENV["HOME"]
      original_inspector_new = Hive::AgentSkills::Inspector.method(:new)
      ENV["HOME"] = dir
      Hive::AgentSkills::Inspector.define_singleton_method(:new) do |config:, project_root:, **|
        ResolutionInspector.new(config: config, project_root: project_root)
      end
      yield dir
    ensure
      Hive::AgentSkills::Inspector.define_singleton_method(:new, original_inspector_new) if original_inspector_new
      old.nil? ? ENV.delete("HOME") : ENV["HOME"] = old
    end
  end

  def write_file(path, content = "")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def run_init_with_preflight(dir)
    Hive::Commands::Init.new(dir, agent_skill_preflight: true).call
  end

  # Installs a complete skill set so the preflight reports all-green
  # (matches the recommended-default config that `hive init` writes).
  # See `templates/project_config.yml.erb` for the reviewer roster.
  def install_all_default_skills(home)
    roots = {
      "claude" => File.join(home, ".claude"),
      "codex" => File.join(home, ".codex"),
      "pi" => File.join(home, ".pi", "agent")
    }
    roots.each do |platform, root|
      publisher = Hive::AgentSkills::DirectoryPublisher.new(
        root: root,
        trusted_root: home,
        projection: Hive::AgentSkills::CanonicalSkill.new.render(platform)
      )
      publisher.publish(expected_snapshot: publisher.report.snapshot)
    end
    # plan stage default → /plan (user command)
    write_file("#{home}/.claude/commands/plan.md")
    # brainstorm stage default → /ce-brainstorm
    write_file("#{home}/.claude/plugins/cache/mp/compound-engineering/3.0.1/skills/ce-brainstorm/SKILL.md")
    # review.reviewers default set: claude-ce-code-review +
    # codex-ce-code-review + pr-review-toolkit:review-pr
    write_file("#{home}/.claude/skills/ce-code-review/SKILL.md")
    write_file("#{home}/.codex/skills/ce-code-review/SKILL.md")
    write_file("#{home}/.claude/plugins/cache/mp/pr-review-toolkit/1.0/skills/review-pr/SKILL.md")
  end

  def test_all_green_emits_no_preflight_output
    with_fake_home do |home|
      install_all_default_skills(home)
      with_tmp_global_config(home: home) do
        with_tmp_git_repo do |dir|
          out, err = capture_io { run_init_with_preflight(dir) }
          assert_includes out, "hive: initialized"
          refute_match(/doctor pre-flight/, err,
            "all-green preflight must emit nothing on stderr")
        end
      end
    end
  end

  def test_one_missing_skill_emits_stderr_warning_and_init_exits_zero
    with_fake_home do |home|
      install_all_default_skills(home)
      # Remove the brainstorm stage skill so the preflight surfaces it.
      FileUtils.rm_rf("#{home}/.claude/plugins/cache/mp/compound-engineering")

      with_tmp_global_config(home: home) do
        with_tmp_git_repo do |dir|
          out, err = capture_io { run_init_with_preflight(dir) }
          assert_includes out, "hive: initialized"
          assert_match(/hive: doctor pre-flight — found \d+ issue/, err)
          assert_match(%r{\[brainstorm/claude\]}, err,
            "warning row carries the brainstorm/agent label")
          assert_match(/See `hive doctor` for details/, err)
        end
      end
    end
  end

  def test_multiple_missing_skills_includes_reviewer_row
    with_fake_home do |home|
      # Only install plan; everything else missing (including reviewers).
      write_file("#{home}/.claude/commands/plan.md")

      with_tmp_global_config(home: home) do
        with_tmp_git_repo do |dir|
          _, err = capture_io { run_init_with_preflight(dir) }
          assert_match(/found \d+ issue/, err)
          assert_match(%r{\[brainstorm/claude\]}, err)
          assert_match(%r{\[6-review/claude-ce-code-review/claude\]}, err,
            "reviewer rows must use the 6-review/<name> label in the warning")
        end
      end
    end
  end

  def test_preflight_does_not_change_init_exit_code
    with_fake_home do |home|
      # Nothing installed → multiple missing skills, but init must still succeed.
      with_tmp_global_config(home: home) do
        with_tmp_git_repo do |dir|
          # Init relies on `exit` for failure paths; a successful init
          # returns normally. capture_io will just observe stdout/stderr;
          # if init blew up, the test would error.
          out, err = capture_io { run_init_with_preflight(dir) }
          assert_includes out, "hive: initialized"
          assert_match(/found \d+ issue/, err)
          # No exception, no exit — init returned normally despite the
          # preflight finding missing skills.
        end
      end
    end
  end

  def test_preflight_crash_logs_bug_hint_and_init_still_succeeds
    # Forces the StandardError rescue path: monkey-patch
    # Hive::Config.load to raise an unexpected (non-ConfigError) class
    # so the doctor's own rescue does NOT catch it and it propagates
    # to init's preflight rescue. Restore around the test so other
    # tests in the suite see the original method.
    with_fake_home do |home|
      with_tmp_global_config(home: home) do
        with_tmp_git_repo do |dir|
          original = Hive::Config.method(:load)
          Hive::Config.define_singleton_method(:load) do |_path|
            raise NoMethodError, "boom"
          end
          out, err = capture_io { run_init_with_preflight(dir) }
          assert_includes out, "hive: initialized", "init must complete successfully"
          assert_match(/doctor pre-flight failed: NoMethodError: boom/, err)
          assert_match(/this may be a hive bug/, err)
        ensure
          Hive::Config.define_singleton_method(:load, original) if original
        end
      end
    end
  end

  def test_preflight_handles_config_error_with_pointer_message
    # If Doctor's own rescue catches a Hive::ConfigError internally
    # (returns EXIT_CONFIG_ERROR), init's preflight surfaces a
    # pointer line rather than going silent. This is the case-2 path
    # in run_init_preflight!.
    with_fake_home do |home|
      with_tmp_global_config(home: home) do
        with_tmp_git_repo do |dir|
          original = Hive::Config.method(:load)
          Hive::Config.define_singleton_method(:load) do |_path|
            raise Hive::ConfigError, "intentional malformed config"
          end
          out, err = capture_io { run_init_with_preflight(dir) }
          assert_includes out, "hive: initialized"
          assert_match(/doctor pre-flight — config issue detected/, err)
          assert_match(/run `hive doctor` for details/, err)
        ensure
          Hive::Config.define_singleton_method(:load, original) if original
        end
      end
    end
  end
end
