require "test_helper"
require "hive/proposals/evaluator_authority"

class ProposalEvaluatorAuthorityTest < Minitest::Test
  def test_mints_a_closed_historical_binding_from_matching_configuration
    authority = Hive::Proposals::EvaluatorAuthority.new(config)

    binding = authority.bind!(
      identity: "benchmark-reviewer", workflow: "coding",
      stage: "4-execute", agent_profile: "codex"
    )

    assert_equal "benchmark-reviewer", binding.fetch("id")
    assert_match(/\A[0-9a-f]{64}\z/, binding.fetch("fingerprint"))
    assert_match(/\A[0-9a-f]{64}\z/, binding.fetch("configuration_fingerprint"))
    assert_equal %w[coding], binding.dig("admission", "workflows")
    assert binding.frozen?
  end

  def test_rejects_unknown_or_mismatched_evaluators
    authority = Hive::Proposals::EvaluatorAuthority.new(config)

    assert_raises(Hive::Proposals::Unauthorized) do
      authority.bind!(identity: "unknown", workflow: "coding", stage: "4-execute", agent_profile: "codex")
    end
    assert_raises(Hive::Proposals::Unauthorized) do
      authority.bind!(
        identity: "benchmark-reviewer", workflow: "planning",
        stage: "4-execute", agent_profile: "codex"
      )
    end
  end

  def test_rejects_unbounded_or_duplicate_evaluator_admission_lists
    malformed = config
    malformed["evaluators"]["benchmark-reviewer"]["workflows"] = [ "coding", "coding" ]

    assert_raises(Hive::Proposals::InvalidRecord) do
      Hive::Proposals::EvaluatorAuthority.new(malformed).bind!(
        identity: "benchmark-reviewer", workflow: "coding",
        stage: "4-execute", agent_profile: "codex"
      )
    end
  end

  private

  def config
    {
      "evaluators" => {
        "benchmark-reviewer" => {
          "workflows" => [ "coding" ], "stages" => [ "4-execute" ],
          "agent_profiles" => [ "codex" ]
        }
      },
      "evidence" => {
        "visibility" => "project", "retention" => "project",
        "allowed_link_schemes" => [ "https" ]
      },
      "limits" => {}
    }
  end
end
