require "test_helper"
require_relative "../../packaging/live_agent_skills/openclaw_creator_proof"

# Authenticated CI adapter only. Deterministic proof mechanics live under
# packaging/live_agent_skills/openclaw_creator_proof and are unit-tested without
# credentials; this test merely selects the live boundary and reports its typed
# evidence when the authenticated run fails.
class LiveHiveWorkflowCreatorSmokeTest < Minitest::Test
  def test_openclaw_workflow_creator_proof
    availability!(
      ENV["HIVE_LIVE_AGENT_SKILLS"] == "1",
      "set HIVE_LIVE_AGENT_SKILLS=1 to run authenticated workflow-creator proof"
    )

    evidence = HiveLiveAgentProof::OpenClawCreatorProof::Runner.from_env.call

    assert_equal(
      "passed",
      evidence.fetch("result"),
      [
        evidence.fetch("phase", "unknown"),
        evidence.fetch("reason", "unknown"),
        evidence.fetch("detail", "no failure detail")
      ].join(": ")
    )
  end

  private

  def availability!(condition, message)
    return if condition
    raise Minitest::Assertion, message if ENV["HIVE_RELEASE_GATE"] == "1"

    skip message
  end
end
