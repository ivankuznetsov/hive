require "test_helper"
require "hive/refactor_patrol/policy"

class RefactorPatrolPolicyTest < Minitest::Test
  def test_capture_retains_v4_shape_without_action_authority
    time = Time.utc(2026, 7, 10, 12, 0, 0)
    policy = Hive::RefactorPatrol::Policy.capture(config, now: time)

    assert_equal true, policy.fetch("discovery")
    assert_equal false, policy.fetch("auto_fix")
    assert_equal false, policy.fetch("issue_filing")
    assert_equal "main", policy.dig("action", "default_branch")
    assert_equal "codex", policy.dig("action", "auto_fix_agent")
    assert_equal "bin/test", policy.dig("action", "commands", "test")
    assert_match(/\A[a-f0-9]{64}\z/, policy.fetch("epoch"))
    assert_equal time.iso8601, policy.fetch("captured_at")
  end

  private

  def config
    {
      "default_branch" => "main",
      "execute" => {
        "agent" => "codex", "model" => "gpt-5.6-sol", "effort" => "high"
      },
      "refactor_patrol" => {
        "enabled" => true,
        "auto_fix" => { "enabled" => true, "agent" => "codex" },
        "issue_filing" => { "enabled" => true },
        "min_confidence" => "medium",
        "commands" => {
          "docs" => nil, "format" => nil, "lint" => nil,
          "public_contract" => nil, "typecheck" => nil, "test" => "bin/test"
        },
        "caps" => {
          "single_feature_only" => true,
          "allow_dependency_bumps" => false,
          "allow_public_api_changes" => false,
          "allow_cross_feature" => false
        }
      }
    }
  end
end
