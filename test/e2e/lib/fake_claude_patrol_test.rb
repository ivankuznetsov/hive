require_relative "../../test_helper"
require "open3"
require_relative "paths"

class E2EFakeClaudePatrolTest < Minitest::Test
  def test_capability_probe_is_side_effect_free_in_patrol_mode
    Dir.mktmpdir("fake-claude-patrol") do |dir|
      root = File.join(dir, "runs")
      stdout, stderr, status = Open3.capture3(
        {
          "HIVE_FAKE_CLAUDE_PATROL_EMPTY" => "1",
          "HIVE_FAKE_CLAUDE_PATROL_OUTPUT_ROOT" => root,
          "HIVE_FAKE_CLAUDE_LOG_DIR" => File.join(dir, "logs")
        },
        Hive::E2E::Paths.fake_claude,
        "--safe-mode", "--disable-slash-commands",
        "--tools", "Read,Grep,Glob,Write", "--help"
      )

      assert status.success?, stderr
      assert_includes stdout, "--safe-mode"
      refute Dir.exist?(root)
    end
  end

  def test_writes_only_the_prompt_named_findings_file_under_the_patrol_root
    Dir.mktmpdir("fake-claude-patrol") do |dir|
      root = File.join(dir, "runs")
      output = File.join(root, "review-safe_1", "findings.json")
      prompt = "Write a JSON object to this exact path:\n#{output}\n"

      _stdout, stderr, status = Open3.capture3(
        {
          "HIVE_FAKE_CLAUDE_PATROL_EMPTY" => "1",
          "HIVE_FAKE_CLAUDE_PATROL_OUTPUT_ROOT" => root,
          "HIVE_FAKE_CLAUDE_LOG_DIR" => File.join(dir, "logs")
        },
        Hive::E2E::Paths.fake_claude, "--print", prompt
      )

      assert status.success?, stderr
      assert_equal({ "findings" => [] }, JSON.parse(File.read(output)))
    end
  end

  def test_rejects_a_prompt_path_outside_the_patrol_root
    Dir.mktmpdir("fake-claude-patrol") do |dir|
      root = File.join(dir, "runs")
      outside = File.join(dir, "review-escape", "findings.json")

      _stdout, stderr, status = Open3.capture3(
        {
          "HIVE_FAKE_CLAUDE_PATROL_EMPTY" => "1",
          "HIVE_FAKE_CLAUDE_PATROL_OUTPUT_ROOT" => root,
          "HIVE_FAKE_CLAUDE_LOG_DIR" => File.join(dir, "logs")
        },
        Hive::E2E::Paths.fake_claude, "--print", outside
      )

      refute status.success?
      assert_match(/output path was not found/, stderr)
      refute File.exist?(outside)
    end
  end
end
