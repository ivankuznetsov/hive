# frozen_string_literal: true

require "test_helper"
require_relative "../../../templates/builtins/bench/runtime/harness/profiles/candidates"
require_relative "../../../templates/builtins/bench/runtime/harness/lib/hive_config"
candidate_harness = File.expand_path("../../../templates/builtins/bench/runtime/harness", __dir__)
$LOAD_PATH.unshift(candidate_harness)
require "lib/hive_driver"
$LOAD_PATH.delete(candidate_harness)

class BenchCampaignCandidatesTest < Minitest::Test
  include HiveTestHelper

  def test_native_pi_does_not_mount_openrouter_catalog_even_with_an_opencode_openrouter_stage
    data = campaign
    profile = data["candidate_profiles"]["deepseek-single"]
    profile["credential_env"] = [ "ANTHROPIC_API_KEY" ]
    profile["stages"].each_value { |route| route.replace("agent" => "pi", "model" => "anthropic/test-model") }
    with_tmp_dir do |root|
      [ false, true ].each do |mixed|
        profile["stages"]["execute"] = { "agent" => "opencode", "model" => "openrouter/test-model" } if mixed
        candidate = HiveBench::Candidates.for_campaign(data).first
        mounts = HiveBench::HiveDriver.new(reuse_existing: false, reuse_unverified: false).send(:auth_mounts, candidate, root)
        refute mounts.any? { |value| value.include?("pi-openrouter-models.json") }
        assert_includes mounts, "HIVE_PI_BIN=/opt/hb/pi-bench-launcher"
      end
    end
  end

  def test_legacy_pi_still_mounts_its_openrouter_catalog
    with_tmp_dir do |root|
      candidate = HiveBench::Candidates.by_id("all-ox-alpha@max")
      mounts = HiveBench::HiveDriver.new(reuse_existing: false, reuse_unverified: false).send(:auth_mounts, candidate, root)
      assert_includes mounts, "#{HiveBench::HiveDriver::PI_OPENROUTER_MODELS}:/opt/hb/pi-openrouter-models.json:ro"
    end
  end

  def campaign
    route = { "agent" => "opencode", "model" => "opencode-go/deepseek-v4.1-flash" }
    { "candidates" => [ "deepseek-single" ], "candidate_profiles" => {
      "deepseek-single" => {
        "model_version" => "deepseek-v4.1-flash",
        "credential_env" => [ "OPENCODE_API_KEY" ],
        "stages" => %w[plan execute review].to_h { |stage| [ stage, route.dup ] }
      }
    } }
  end

  def test_campaign_declares_a_single_model_without_editing_the_registry
    candidate = HiveBench::Candidates.for_campaign(campaign).fetch(0)
    config = HiveBench::HiveConfig.to_h(candidate)
    assert_equal "deepseek-single", candidate.id
    assert_equal false, config.dig("plan_review", "enabled")
    %w[plan execute open_pr review_ci review_triage review_fix].each do |stage|
      assert_equal "opencode-go/deepseek-v4.1-flash", config.dig("models", stage, "model")
    end
    assert_equal "opencode-go/deepseek-v4.1-flash", config.dig("review", "reviewers", 0, "model")
    refute_includes config.dig("agents", "opencode", "credential_env"), "OPENROUTER_API_KEY"
    assert_equal [ "OPENCODE_API_KEY" ], config.dig("agents", "opencode", "credential_env")
  end

  def test_mixed_stages_preserve_native_effort_and_explicit_plan_review_routes
    data = campaign
    profile = data["candidate_profiles"]["deepseek-single"]
    profile["stages"]["plan"] = { "agent" => "codex", "model" => "test-planner", "effort" => "medium" }
    profile["plan_review"] = { "enabled" => true, "routes" => {
      "primary" => { "agent" => "codex", "model" => "test-planner", "family" => "openai", "effort" => "medium" },
      "adversarial" => { "agent" => "opencode", "model" => "opencode-go/deepseek-v4.1-flash", "family" => "deepseek" },
      "verification" => { "agent" => "codex", "model" => "test-planner", "family" => "openai", "effort" => "medium" }
    } }
    config = HiveBench::HiveConfig.to_h(HiveBench::Candidates.for_campaign(data).first)
    assert_equal "medium", config.dig("models", "plan", "effort")
    assert_equal profile["plan_review"], config["plan_review"]
  end

  def test_legacy_candidates_remain_available
    assert_equal HiveBench::Candidates.by_id("all-ox-alpha@max"),
                 HiveBench::Candidates.for_campaign("candidates" => [ "all-ox-alpha@max" ]).first
  end

  def test_invalid_profiles_fail_before_launch
    data = campaign
    profile = data["candidate_profiles"]["deepseek-single"]
    profile["stages"]["execute"]["agent"] = "typo"
    assert_raises(ArgumentError) { HiveBench::Candidates.for_campaign(data) }
    profile["stages"]["execute"]["agent"] = "opencode"
    profile["stages"]["execute"].delete("model")
    assert_raises(ArgumentError) { HiveBench::Candidates.for_campaign(data) }
  end

  def test_custom_profiles_cannot_shadow_historical_candidate_ids
    data = campaign
    data["candidate_profiles"]["all-ox-alpha@max"] = data["candidate_profiles"].delete("deepseek-single")
    data["candidates"] = [ "all-ox-alpha@max" ]
    assert_raises(ArgumentError) { HiveBench::Candidates.for_campaign(data) }
  end

  def test_plan_review_cannot_inherit_an_undeclared_production_model
    data = campaign
    data["candidate_profiles"]["deepseek-single"]["plan_review"] = { "enabled" => true }
    assert_raises(ArgumentError) { HiveBench::Candidates.for_campaign(data) }
  end

  def test_pi_catalog_requires_environment_references_not_literal_secrets
    data = campaign
    profile = data["candidate_profiles"]["deepseek-single"]
    profile["pi_catalog"] = { "providers" => { "zai" => {
      "baseUrl" => "https://api.z.ai/api/coding/paas/v4",
      "api" => "openai-completions", "apiKey" => "$ZAI_API_KEY",
      "models" => [ { "id" => "glm-5.3-flash", "reasoning" => true } ]
    } } }
    profile["credential_env"] = [ "ZAI_API_KEY" ]
    assert_equal profile["pi_catalog"], HiveBench::Candidates.for_campaign(data).first.pi_catalog
    profile["stages"].each_value { |route| route.replace("agent" => "pi", "model" => "zai/glm-5.3-flash") }
    with_tmp_dir do |root|
      candidate = HiveBench::Candidates.for_campaign(data).first
      mounts = HiveBench::HiveDriver.new(reuse_existing: false, reuse_unverified: false).send(:auth_mounts, candidate, root)
      assert_includes mounts, "HB_PI_CUSTOM_CATALOG=1"
      assert_equal profile["pi_catalog"], JSON.parse(File.read(File.join(root, "pi-models.json")))
    end
    profile["pi_catalog"]["providers"]["zai"]["apiKey"] = "literal-secret"
    assert_raises(ArgumentError) { HiveBench::Candidates.for_campaign(data) }
  end
end
