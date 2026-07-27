require "test_helper"
require "hive/refactor_patrol/agent_identity"

class RefactorPatrolAgentIdentityTest < Minitest::Test
  include HiveTestHelper

  def test_review_and_fix_inherit_the_complete_execute_identity_by_default
    cfg = {
      "project_root" => "/tmp/project",
      "execute" => { "agent" => "codex", "model" => "gpt-5.6-sol", "effort" => "high" },
      "refactor_patrol" => { "auto_fix" => {} }
    }

    identity = Hive::RefactorPatrol::AgentIdentity.new(cfg: cfg)

    assert_identity identity.review, provider: "codex", model: "gpt-5.6-sol", effort: "high"
    assert_identity identity.fix, provider: "codex", model: "gpt-5.6-sol", effort: "high"
    assert_equal [ "--model", "gpt-5.6-sol", "-c", "model_reasoning_effort=high" ],
                 identity.fix.native_arguments
  end

  def test_provider_override_without_model_uses_that_providers_concrete_default
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".claude"))
      File.write(
        File.join(dir, ".claude", "settings.json"),
        JSON.generate("model" => "claude-sonnet-4-6")
      )
      cfg = {
        "project_root" => dir,
        "execute" => { "agent" => "codex", "model" => "gpt-5.6-sol", "effort" => "high" },
        "refactor_patrol" => { "agent" => "claude", "auto_fix" => {} }
      }

      identity = Hive::RefactorPatrol::AgentIdentity.new(cfg: cfg)

      assert_identity identity.review,
                      provider: "claude", model: "claude-sonnet-4-6", effort: "high"
      assert_identity identity.fix,
                      provider: "claude", model: "claude-sonnet-4-6", effort: "high"
    end
  end

  def test_auto_fix_can_override_identity_fields_independently
    cfg = {
      "project_root" => "/tmp/project",
      "execute" => { "agent" => "codex", "model" => "gpt-5.6-sol", "effort" => "high" },
      "refactor_patrol" => {
        "model" => "gpt-5.6-terra",
        "auto_fix" => { "model" => "gpt-5.6-sol", "effort" => "xhigh" }
      }
    }

    identity = Hive::RefactorPatrol::AgentIdentity.new(cfg: cfg)

    assert_identity identity.review,
                    provider: "codex", model: "gpt-5.6-terra", effort: "high"
    assert_identity identity.fix,
                    provider: "codex", model: "gpt-5.6-sol", effort: "xhigh"
  end

  def test_patrol_routes_are_frozen_into_review_and_fix_identities
    cfg = {
      "project_root" => "/tmp/project",
      "execute" => {
        "agent" => "codex", "model" => "gpt-5.6-terra", "effort" => "medium"
      },
      "models" => {
        "patrol" => { "effort" => "high" },
        "patrol_review" => { "model" => "gpt-5.6-review" },
        "patrol_fix" => { "model" => "gpt-5.6-fix", "effort" => "xhigh" }
      },
      "refactor_patrol" => { "auto_fix" => {} }
    }

    identity = Hive::RefactorPatrol::AgentIdentity.new(cfg: cfg)

    assert_identity identity.review,
                    provider: "codex", model: "gpt-5.6-review", effort: "high"
    assert_identity identity.fix,
                    provider: "codex", model: "gpt-5.6-fix", effort: "xhigh"
    assert_empty identity.review.native_arguments
    assert_equal "patrol_review", identity.review.routing.fetch("stage")
    assert_equal [
      "--model", "gpt-5.6-review", "-c", "model_reasoning_effort=high"
    ], identity.review.routing_arguments(
      Hive::AgentProfiles.lookup(:codex)
    ).global_arguments
  end

  def test_blank_provider_override_fails_closed
    cfg = {
      "execute" => { "agent" => "codex", "model" => "gpt-5.6-sol", "effort" => "high" },
      "refactor_patrol" => { "agent" => " ", "auto_fix" => {} }
    }

    error = assert_raises(Hive::ImplementationIdentity::ResolutionError) do
      Hive::RefactorPatrol::AgentIdentity.new(cfg: cfg).review
    end

    assert_includes error.message, "must identify a provider"
  end

  private

  def assert_identity(identity, provider:, model:, effort:)
    assert_equal provider, identity.provider
    assert_equal model, identity.model
    assert_equal effort, identity.requested_effort
  end
end
