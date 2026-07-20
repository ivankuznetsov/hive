require "test_helper"
require "hive/refactor_patrol/policy"

class RefactorPatrolPolicyTest < Minitest::Test
  T0 = Time.utc(2026, 7, 10, 12, 0, 0)

  def test_capture_persists_every_action_policy_input
    policy = Hive::RefactorPatrol::Policy.capture(config, now: T0)

    assert_equal true, policy.fetch("discovery")
    assert_equal true, policy.fetch("auto_fix")
    assert_equal true, policy.fetch("issue_filing")
    assert_equal "main", policy.dig("action", "default_branch")
    assert_equal "codex", policy.dig("action", "auto_fix_agent")
    assert_equal "medium", policy.dig("action", "min_confidence")
    assert_equal "bin/test", policy.dig("action", "commands", "test")
    refute policy.dig("action", "caps").key?("max_files")
    refute policy.dig("action", "caps").key?("max_diff_lines")
    assert_equal 0.4, policy.dig("action", "issue_min_leverage_score")
    assert_match(/\A[a-f0-9]{64}\z/, policy.fetch("epoch"))
    assert_equal T0.iso8601, policy.fetch("captured_at")
  end

  def test_effective_policy_intersects_guards_and_thresholds_in_the_stricter_direction
    snapshot = Hive::RefactorPatrol::Policy.capture(config, now: T0)
    current = config
    current["refactor_patrol"]["caps"].merge!(
      "allow_dependency_bumps" => true,
      "allow_public_api_changes" => true,
      "allow_cross_feature" => true,
      "single_feature_only" => false
    )
    current["refactor_patrol"]["min_confidence"] = "low"
    current["refactor_patrol"]["issue_filing"]["min_leverage_score"] = 0.1

    result = Hive::RefactorPatrol::Policy.intersect(snapshot, current)

    assert result.authorized?("fix")
    assert result.authorized?("issue")
    refute result.config.dig("refactor_patrol", "caps").key?("max_files")
    refute result.config.dig("refactor_patrol", "caps").key?("max_diff_lines")
    assert_equal false, result.config.dig("refactor_patrol", "caps", "allow_dependency_bumps")
    assert_equal false, result.config.dig("refactor_patrol", "caps", "allow_public_api_changes")
    assert_equal false, result.config.dig("refactor_patrol", "caps", "allow_cross_feature")
    assert_equal true, result.config.dig("refactor_patrol", "caps", "single_feature_only")
    assert_equal "medium", result.config.dig("refactor_patrol", "min_confidence")
    assert_equal 0.4, result.config.dig("refactor_patrol", "issue_filing", "min_leverage_score")
  end

  def test_current_policy_can_narrow_a_snapshot
    snapshot = Hive::RefactorPatrol::Policy.capture(config, now: T0)
    current = config
    current["refactor_patrol"]["caps"]["single_feature_only"] = true
    current["refactor_patrol"]["min_confidence"] = "high"
    current["refactor_patrol"]["issue_filing"]["min_leverage_score"] = 0.8

    result = Hive::RefactorPatrol::Policy.intersect(snapshot, current)

    assert_equal true, result.config.dig("refactor_patrol", "caps", "single_feature_only")
    assert_equal "high", result.config.dig("refactor_patrol", "min_confidence")
    assert_equal 0.8, result.config.dig("refactor_patrol", "issue_filing", "min_leverage_score")
  end

  def test_legacy_size_limits_are_accepted_but_removed_from_effective_policy
    snapshot = Hive::RefactorPatrol::Policy.capture(config, now: T0)
    snapshot.fetch("action").fetch("caps").merge!("max_files" => 8, "max_diff_lines" => 400)
    current = config
    current.fetch("refactor_patrol").fetch("caps").merge!("max_files" => 2, "max_diff_lines" => 20)

    result = Hive::RefactorPatrol::Policy.intersect(snapshot, current)

    assert result.authorized?("fix")
    refute result.config.dig("refactor_patrol", "caps").key?("max_files")
    refute result.config.dig("refactor_patrol", "caps").key?("max_diff_lines")
  end

  def test_changed_agent_or_validation_command_revokes_new_fix_effects
    snapshot = Hive::RefactorPatrol::Policy.capture(config, now: T0)
    current = config
    current["refactor_patrol"]["auto_fix"]["agent"] = "claude"
    current["refactor_patrol"]["commands"]["test"] = "bin/test --changed"

    result = Hive::RefactorPatrol::Policy.intersect(snapshot, current)

    refute result.authorized?("fix")
    assert result.authorized?("issue")
    assert_nil result.config.dig("refactor_patrol", "commands", "test")
    assert_includes result.reasons.fetch("fix"), "auto_fix_agent_changed"
    assert_includes result.reasons.fetch("fix"), "validation_commands_changed"
  end

  def test_current_enablement_never_broadens_a_disabled_snapshot
    original = config
    original["refactor_patrol"]["auto_fix"]["enabled"] = false
    original["refactor_patrol"]["issue_filing"]["enabled"] = false
    snapshot = Hive::RefactorPatrol::Policy.capture(original, now: T0)

    result = Hive::RefactorPatrol::Policy.intersect(snapshot, config)

    refute result.authorized?("fix")
    refute result.authorized?("issue")
  end

  def test_missing_action_snapshot_fails_closed
    snapshot = {
      "discovery" => true, "auto_fix" => true, "issue_filing" => true,
      "captured_at" => T0.iso8601
    }

    result = Hive::RefactorPatrol::Policy.intersect(snapshot, config)

    refute result.authorized?("fix")
    refute result.authorized?("issue")
    assert_equal "policy_snapshot_missing", result.error
  end

  def test_malformed_action_snapshot_fails_closed
    snapshot = Hive::RefactorPatrol::Policy.capture(config, now: T0)
    snapshot.fetch("action")["min_confidence"] = "absolute"

    result = Hive::RefactorPatrol::Policy.intersect(snapshot, config)

    refute result.authorized?("fix")
    refute result.authorized?("issue")
    assert_equal "policy_snapshot_invalid", result.error
  end

  private

  def config
    Marshal.load(Marshal.dump(
      "default_branch" => "main",
      "refactor_patrol" => {
        "enabled" => true,
        "auto_fix" => { "enabled" => true, "agent" => "codex" },
        "issue_filing" => { "enabled" => true, "min_leverage_score" => 0.4 },
        "min_confidence" => "medium",
        "commands" => {
          "docs" => "bin/docs", "format" => nil, "lint" => "bin/lint", "public_contract" => nil,
          "typecheck" => nil, "test" => "bin/test"
        },
        "caps" => {
          "single_feature_only" => true,
          "allow_dependency_bumps" => false,
          "allow_public_api_changes" => false,
          "allow_cross_feature" => false
        }
      }
    ))
  end
end
