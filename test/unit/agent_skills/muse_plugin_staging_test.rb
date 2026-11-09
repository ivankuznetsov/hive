require "test_helper"
require "json"

require "hive/agent_skills/inspector"
require "hive/agent_support/muse"

# PluginStaging failure branches and the symlink jail. The git clone is
# simulated by a runner that copies (or builds) a tree in place, so each
# case controls exactly what the "upstream" repository contains.
class AgentSkillsMusePluginStagingTest < Minitest::Test
  include HiveTestHelper

  Staging = Hive::AgentSupport::Muse::PluginStaging

  class CloneRunner
    def initialize(result: nil, &build)
      @result = result
      @build = build
    end

    def call(argv, **)
      return @result if @result

      destination = argv.last
      FileUtils.mkdir_p(destination)
      @build&.call(destination)
      result(exit_status: 0)
    end

    def result(exit_status:, stderr: "", timed_out: false)
      Hive::AgentSkills::CommandResult.new(
        stdout: "", stderr: stderr, exit_status: exit_status, error: nil,
        timed_out: timed_out
      )
    end
  end

  def write_manifest(dir, version: "3.1.0")
    FileUtils.mkdir_p(File.join(dir, ".claude-plugin"))
    File.write(
      File.join(dir, ".claude-plugin", "plugin.json"),
      JSON.generate("name" => "compound-engineering", "version" => version)
    )
  end

  def stage(root, runner)
    Staging.stage(source: "https://example.test/ce", root: root, runner: runner, env: {})
  end

  def test_clone_failure_reports_the_first_stderr_line
    with_tmp_dir do |dir|
      runner = CloneRunner.new
      runner.instance_variable_set(
        :@result, runner.result(exit_status: 128, stderr: "fatal: repo not found\nmore")
      )

      error = assert_raises(Hive::Error) { stage(File.join(dir, "stage"), runner) }
      assert_match(/git clone .* failed: fatal: repo not found\z/, error.message)
    end
  end

  def test_clone_timeout_and_silent_failure_have_readable_details
    with_tmp_dir do |dir|
      runner = CloneRunner.new
      runner.instance_variable_set(:@result, runner.result(exit_status: 1))
      error = assert_raises(Hive::Error) { stage(File.join(dir, "a"), runner) }
      assert_match(/failed: exit 1\z/, error.message)

      runner.instance_variable_set(
        :@result, runner.result(exit_status: nil, timed_out: true)
      )
      error = assert_raises(Hive::Error) { stage(File.join(dir, "b"), runner) }
      assert_match(/failed: timed out\z/, error.message)
    end
  end

  def test_missing_manifest_or_version_is_refused
    with_tmp_dir do |dir|
      error = assert_raises(Hive::Error) do
        stage(File.join(dir, "a"), CloneRunner.new { |clone| File.write(File.join(clone, "README"), "x") })
      end
      assert_match(/no \.claude-plugin\/plugin\.json/, error.message)

      error = assert_raises(Hive::Error) do
        stage(File.join(dir, "b"), CloneRunner.new { |clone| write_manifest(clone, version: "") })
      end
      assert_match(/manifest has no version/, error.message)

      error = assert_raises(Hive::Error) do
        stage(File.join(dir, "c"), CloneRunner.new { |clone|
          FileUtils.mkdir_p(File.join(clone, ".claude-plugin"))
          File.write(File.join(clone, ".claude-plugin", "plugin.json"), "{not json")
        })
      end
      assert_match(/could not stage muse plugin/, error.message)
    end
  end

  def test_in_tree_symlinks_are_dereferenced_and_dangling_ones_dropped
    with_tmp_dir do |dir|
      root = File.join(dir, "stage")
      version = stage(root, CloneRunner.new { |clone|
        write_manifest(clone)
        FileUtils.mkdir_p(File.join(clone, "skills", "plan"))
        File.write(File.join(clone, "skills", "plan", "SKILL.md"), "plan")
        FileUtils.mkdir_p(File.join(clone, ".claude"))
        File.symlink("../skills", File.join(clone, ".claude", "skills"))
        File.symlink("missing-target", File.join(clone, "dangling"))
        File.symlink("skills/plan/SKILL.md", File.join(clone, "PLAN.md"))
      })

      package = Staging.package_dir(root)
      assert_equal "3.1.0", version
      assert_equal "plan", File.read(File.join(package, ".claude", "skills", "plan", "SKILL.md"))
      refute File.symlink?(File.join(package, ".claude", "skills"))
      refute File.exist?(File.join(package, "dangling"))
      refute File.symlink?(File.join(package, "dangling"))
      assert_equal "plan", File.read(File.join(package, "PLAN.md"))
      refute File.symlink?(File.join(package, "PLAN.md"))
    end
  end

  def test_symlinks_escaping_the_clone_are_refused
    with_tmp_dir do |dir|
      secret = File.join(dir, "secret")
      File.write(secret, "private key")

      [ secret, "../../secret", "/" ].each_with_index do |link, index|
        root = File.join(dir, "stage-#{index}")
        error = assert_raises(Hive::Error) do
          stage(root, CloneRunner.new { |clone|
            write_manifest(clone)
            File.symlink(link, File.join(clone, "leak"))
          })
        end
        assert_match(/symlink leak points outside the cloned repository/, error.message)
        refute File.exist?(File.join(Staging.package_dir(root), "leak"))
      end
    end
  end

  def test_symlink_cycles_are_refused
    with_tmp_dir do |dir|
      { "a/loop" => "..", "self" => "." }.each_with_index do |(link, target), index|
        error = assert_raises(Hive::Error) do
          stage(File.join(dir, "stage-#{index}"), CloneRunner.new { |clone|
            write_manifest(clone)
            path = File.join(clone, link)
            FileUtils.mkdir_p(File.dirname(path))
            File.symlink(target, path)
          })
        end
        assert_match(/symlink cycle/, error.message, link)
      end
    end
  end
  def test_a_symlink_left_in_the_staged_tree_is_refused
    # copy_tree never writes links, so this guard is a last line of
    # defence; simulate a staged tree that still reports one.
    with_tmp_dir do |dir|
      link = File.join(dir, "stray")
      File.symlink(dir, link)
      original = Find.method(:find)
      Find.singleton_class.send(:define_method, :find) { |*| [ link ].each }

      error = assert_raises(Hive::Error) do
        stage(File.join(dir, "stage"), CloneRunner.new { |clone| write_manifest(clone) })
      end
      assert_match(/still contains symlinks/, error.message)
    ensure
      Find.singleton_class.send(:define_method, :find, original)
    end
  end
end
