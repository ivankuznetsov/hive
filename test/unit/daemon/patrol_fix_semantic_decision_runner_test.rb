require "test_helper"
require "hive/patrol/state_store"
require "hive/daemon/patrol_fix_semantic_decision_runner"

class DaemonPatrolFixSemanticDecisionRunnerTest < Minitest::Test
  include HiveTestHelper

  def test_strict_success_returns_model_receipt
    with_tmp_dir do |dir|
      result = invoke(dir, {
        status: :ok,
        final_message: JSON.generate(
          "decision" => "same_root", "candidate_identity" => "task:repair-refresh",
          "rationale" => "Both repair the same refresh owner.",
          "evidence" => [ "Both cite the same state transition." ]
        ),
        usage: { model: "gpt-5.6-sol", input: 10, output: 5 },
        session_id: "session-1"
      })

      assert_equal "same_root", result.fetch("decision")
      assert_equal "task:repair-refresh", result.fetch("candidate_identity")
      assert_match(/\Aprovider:gpt-5\.6-sol:/, result.fetch("model_receipt"))
    end
  end

  def test_malformed_provider_output_fails_closed
    with_tmp_dir do |dir|
      assert_raises(Hive::Daemon::PatrolFixSemanticDecisionRunner::Error) do
        invoke(dir, { status: :ok, final_message: "{}" })
      end
    end
  end

  def test_provider_retry_time_is_preserved
    with_tmp_dir do |dir|
      retry_at = Time.utc(2026, 8, 21, 18)
      error = assert_raises(Hive::Daemon::PatrolFixSemanticDecisionRunner::Error) do
        invoke(dir, {
          status: :error, retry_at: retry_at,
          resource_exhaustion: { reason: "provider_limit", retry_at: retry_at }
        })
      end

      assert_equal retry_at, error.retry_at
    end
  end

  private

  def invoke(dir, agent_result)
    agent = Object.new
    agent.define_singleton_method(:run!) { agent_result }
    budget = Object.new
    budget.define_singleton_method(:acquire) { |**| true }
    budget.define_singleton_method(:record!) { |**| nil }
    runner = Hive::Daemon::PatrolFixSemanticDecisionRunner.new(
      project_root: dir, cfg: {
        "execute" => {
          "agent" => "codex", "model" => "gpt-5.6-sol", "effort" => "high"
        }
      },
      state: Hive::Patrol::StateStore.new(dir), launch_budget: budget
    )

    with_replaced_singleton_method(Hive::Agent, :new, ->(**) { agent }) do
      runner.call(
        "candidate_set_digest" => "a" * 64, "current_head" => "b" * 40,
        "source" => { "identity" => "finding-1" },
        "candidates" => [ { "identity" => "task:repair-refresh" } ]
      )
    end
  end
end
