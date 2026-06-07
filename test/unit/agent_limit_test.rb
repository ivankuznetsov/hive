require "test_helper"
require "hive/agent_limit"

class AgentLimitTest < Minitest::Test
  def test_detects_claude_usage_limit_menu
    text = <<~TEXT
      What do you want to do?
      ❯ 1. Stop and wait for limit to reset
        2. Add funds to continue with usage credits
        3. Switch to Team plan
    TEXT

    assert Hive::AgentLimit.limit_reached?(text)
    assert_match(/\Alimits reached for claude:/,
                 Hive::AgentLimit.error_message(text, agent: "claude"))
  end

  def test_detects_common_provider_quota_errors
    assert Hive::AgentLimit.limit_reached?("Error: RESOURCE_EXHAUSTED: quota exceeded")
    assert Hive::AgentLimit.limit_reached?("429 Too Many Requests")
    assert Hive::AgentLimit.limit_reached?("insufficient_quota")
  end

  def test_does_not_classify_unrelated_errors_as_limits
    refute Hive::AgentLimit.limit_reached?("tmux session terminated before writing expected output")
    refute Hive::AgentLimit.limit_reached?("exit_code=1")
    refute Hive::AgentLimit.limit_reached?("429        hive_state = File.join(project_root, \".hive-state\")")
    refute Hive::AgentLimit.limit_reached?("error output includes source line 429        hive_state = path")
    refute Hive::AgentLimit.limit_reached?("missing rate limit on /api/upload")
  end
end
