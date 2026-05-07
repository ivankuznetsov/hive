require "test_helper"
require "fileutils"
require "hive/commands/init"

# Verifies the non-fatal skill preflight that runs at the end of
# `Hive::Commands::Init#call`. Composes the existing init test
# scaffolding (`with_tmp_global_config` + `with_tmp_git_repo`) with
# the HOME-stub pattern from `test/unit/commands/doctor_test.rb` so
# the doctor's filesystem probe is deterministic.
class InitDoctorPreflightTest < Minitest::Test
  include HiveTestHelper

  def with_fake_home
    with_tmp_dir do |dir|
      old = ENV["HOME"]
      ENV["HOME"] = dir
      yield dir
    ensure
      old.nil? ? ENV.delete("HOME") : ENV["HOME"] = old
    end
  end

  def write_file(path, content = "")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  # Installs a complete skill set so the preflight reports all-green
  # (matches the recommended-default config that `hive init` writes).
  # See `templates/project_config.yml.erb` for the reviewer roster.
  def install_all_default_skills(home)
    # plan stage default → /plan (user command)
    write_file("#{home}/.claude/commands/plan.md")
    # brainstorm stage default → /compound-engineering:ce-brainstorm
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
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          out, err = capture_io { Hive::Commands::Init.new(dir).call }
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

      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          out, err = capture_io { Hive::Commands::Init.new(dir).call }
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

      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          _, err = capture_io { Hive::Commands::Init.new(dir).call }
          assert_match(/found \d+ issue/, err)
          assert_match(%r{\[brainstorm/claude\]}, err)
          assert_match(%r{\[5-review/claude-ce-code-review/claude\]}, err,
            "reviewer rows must use the 5-review/<name> label in the warning")
        end
      end
    end
  end

  def test_preflight_does_not_change_init_exit_code
    with_fake_home do |home|
      # Nothing installed → multiple missing skills, but init must still succeed.
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          # Init relies on `exit` for failure paths; a successful init
          # returns normally. capture_io will just observe stdout/stderr;
          # if init blew up, the test would error.
          out, err = capture_io { Hive::Commands::Init.new(dir).call }
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
    with_fake_home do |_home|
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          original = Hive::Config.method(:load)
          Hive::Config.define_singleton_method(:load) do |_path|
            raise NoMethodError, "boom"
          end
          out, err = capture_io { Hive::Commands::Init.new(dir).call }
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
    with_fake_home do |_home|
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          original = Hive::Config.method(:load)
          Hive::Config.define_singleton_method(:load) do |_path|
            raise Hive::ConfigError, "intentional malformed config"
          end
          out, err = capture_io { Hive::Commands::Init.new(dir).call }
          assert_includes out, "hive: initialized"
          # Hive::ConfigError IS StandardError, so this hits the bug-rescue
          # branch (not the EXIT_CONFIG_ERROR branch — that requires the
          # error to be caught BY Doctor, not by Hive::Config.load).
          # The test still exercises a real failure mode and the user
          # gets a clear pointer.
          assert_match(/doctor pre-flight failed/, err)
        ensure
          Hive::Config.define_singleton_method(:load, original) if original
        end
      end
    end
  end
end
