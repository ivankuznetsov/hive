require "test_helper"
require "json"
require "open3"
require "rbconfig"
require "hive/commands/init"
require "hive/task_meta"

class CliVersionTest < Minitest::Test
  include HiveTestHelper

  def test_bin_hive_version_outputs_version
    out = run!(RbConfig.ruby, "-Ilib", "bin/hive", "--version")

    assert_equal "#{Hive::VERSION}\n", out
  end

  def test_bin_hive_help_after_option_value_shows_command_usage
    out, err, status = Open3.capture3(
      RbConfig.ruby, "-Ilib", "bin/hive", "approve", "--from", "2-brainstorm", "--help"
    )

    assert status.success?, "bin/hive approve --from 2-brainstorm --help should exit 0, stderr was: #{err}"
    assert_includes out, "Usage:"
    assert_includes out, "approve"
    refute_includes err, "No value provided for required arguments"
  end

  def test_bin_hive_accepts_json_before_status_command
    with_tmp_global_config do
      leading = JSON.parse(run!(RbConfig.ruby, "-Ilib", "bin/hive", "--json", "status"))
      trailing = JSON.parse(run!(RbConfig.ruby, "-Ilib", "bin/hive", "status", "--json"))

      assert_equal without_generated_at(trailing), without_generated_at(leading)
    end
  end

  def test_bin_hive_accepts_leading_json_true_before_status_command
    with_tmp_global_config do
      leading = JSON.parse(run!(RbConfig.ruby, "-Ilib", "bin/hive", "--json=true", "status"))
      trailing = JSON.parse(run!(RbConfig.ruby, "-Ilib", "bin/hive", "status", "--json=true"))

      assert_equal without_generated_at(trailing), without_generated_at(leading)
    end
  end

  def test_bin_hive_rejects_unsupported_json_assignments_before_target_dispatch
    with_tmp_global_config do
      %w[--json=1 --json=yes].each do |flag|
        out, err, status = Open3.capture3(RbConfig.ruby, "-Ilib", "bin/hive", "run", flag)

        assert_equal 64, status.exitstatus, "#{flag}: malformed JSON flag should be a usage error"
        assert_empty out, "#{flag}: unsupported JSON assignments must not request JSON mode"
        assert_match(/invalid boolean value for --json/, err)
        refute_match(/slug '#{Regexp.escape(flag.split("=", 2).last)}'/, err)
      end
    end
  end

  def test_bin_hive_usage_error_respects_last_json_boolean_flag
    with_tmp_global_config do
      [
        %w[--json --no-json],
        %w[--json --json=false]
      ].each do |flags|
        out, err, status = Open3.capture3(RbConfig.ruby, "-Ilib", "bin/hive", "run", *flags)

        assert_equal 64, status.exitstatus, "#{flags.join(" ")}: missing target should be a usage error"
        assert_empty out, "#{flags.join(" ")}: final false JSON flag must force prose output"
        assert_match(/Usage: "hive run TARGET"/, err)
      end
    end
  end

  def test_bin_hive_new_treats_help_flag_as_task_text_after_project
    with_cli_project do |dir, project|
      out, err, status = run_bin_hive("new", project, "add", "--help", "docs")

      assert status.success?, "hive new should capture --help as text after PROJECT, stderr was: #{err}"
      assert_includes out, "hive: captured"
      refute_includes out, "Usage:"
      assert_new_idea_includes(dir, "add --help docs")
    end
  end

  def test_bin_hive_new_treats_json_assignment_as_task_text_after_project
    with_cli_project do |dir, project|
      out, err, status = run_bin_hive("new", project, "literal", "--json=yes", "text")

      assert status.success?, "hive new should capture --json=yes as text after PROJECT, stderr was: #{err}"
      assert_includes out, "hive: captured"
      refute_match(/invalid boolean value for --json/, err)
      assert_new_idea_includes(dir, "literal --json=yes text")
    end
  end

  def test_bin_hive_new_accepts_workflow_option_before_project
    with_cli_project do |dir, project|
      out, err, status = run_bin_hive("new", "--workflow", "coding", project, "workflow", "flag")

      assert status.success?, "hive new should parse --workflow before PROJECT, stderr was: #{err}"
      assert_includes out, "hive: captured"
      folder = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "workflow-flag-*")].first
      assert_equal "coding", Hive::TaskMeta.read(folder)[:workflow]
    end
  end

  def test_bin_hive_new_treats_workflow_option_as_task_text_after_project
    with_cli_project do |dir, project|
      out, err, status = run_bin_hive("new", project, "literal", "--workflow", "coding")

      assert status.success?, "hive new should capture --workflow as text after PROJECT, stderr was: #{err}"
      assert_includes out, "hive: captured"
      assert_new_idea_includes(dir, "literal --workflow coding")
    end
  end

  private

  def with_cli_project
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        yield dir, File.basename(dir)
      end
    end
  end

  def run_bin_hive(*args)
    Open3.capture3(
      { "HIVE_BIN" => "/nonexistent/hive" },
      RbConfig.ruby, "-Ilib", "bin/hive", *args
    )
  end

  def assert_new_idea_includes(dir, text)
    idea_paths = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*", "idea.md")]
    assert_equal 1, idea_paths.size, "expected one captured idea, got #{idea_paths.inspect}"
    assert_includes File.read(idea_paths.first), text
  end

  def without_generated_at(payload)
    payload.reject { |key, _value| key == "generated_at" }
  end
end
