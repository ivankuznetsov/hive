require "test_helper"
require "hive/refactor_patrol/merge_classifier_runner"

class RefactorPatrolMergeClassifierRunnerTest < Minitest::Test
  include HiveTestHelper

  def test_uses_selected_profile_normal_execution_posture
    with_tmp_dir do |dir|
      captured = nil
      agent = Object.new
      agent.define_singleton_method(:run!) do
        {
          status: :ok,
          final_message: JSON.generate(
            "decision" => "feature", "rationale" => "Adds behavior",
            "evidence" => [ "production path" ]
          ),
          usage: { model: "gpt-5.6-sol", input: 10, output: 5 },
          session_id: "session-1"
        }
      end
      budget = Object.new
      budget.define_singleton_method(:acquire) { |**| true }
      recorded = []
      budget.define_singleton_method(:record!) { |**attributes| recorded << attributes }
      runner = Hive::RefactorPatrol::MergeClassifierRunner.new(
        project_root: dir,
        cfg: {
          "timeout_sec" => { "patrol" => 30 },
          "execute" => {
            "agent" => "codex", "model" => "gpt-5.6-sol", "effort" => "high"
          }
        },
        launch_budget: budget
      )

      result = with_replaced_singleton_method(Hive::Agent, :new, lambda { |**attributes|
        captured = attributes
        agent
      }) do
        runner.call("classify this merge")
      end

      assert_equal "feature", result.fetch("decision")
      assert_match(/\Aprovider:gpt-5\.6-sol:/, result.fetch("model_receipt"))
      assert_equal dir, captured.fetch(:cwd)
      assert_equal [], captured.fetch(:add_dirs)
      assert_equal :exit_code_only, captured.fetch(:status_mode)
      refute captured.key?(:permission_mode),
             "classifier must preserve the selected profile posture instead of forcing a sandbox"
      refute captured.keys.any? { |key| key.to_s.include?("scope") }
      assert_equal 1, recorded.size
      assert_equal "refactor-patrol-merge-classifier", recorded.first.fetch(:stage)
    end
  end

  def test_preserves_provider_retry_time
    with_tmp_dir do |dir|
      retry_at = Time.utc(2026, 8, 20, 18)
      agent = Object.new
      agent.define_singleton_method(:run!) do
        {
          status: :error, retry_at: retry_at,
          resource_exhaustion: { reason: "provider_limit", retry_at: retry_at }
        }
      end
      budget = Object.new
      budget.define_singleton_method(:acquire) { |**| true }
      budget.define_singleton_method(:record!) { |**| nil }
      runner = Hive::RefactorPatrol::MergeClassifierRunner.new(
        project_root: dir,
        cfg: {
          "execute" => {
            "agent" => "codex", "model" => "gpt-5.6-sol", "effort" => "high"
          }
        },
        launch_budget: budget
      )

      error = with_replaced_singleton_method(Hive::Agent, :new, ->(**) { agent }) do
        assert_raises(Hive::RefactorPatrol::MergeClassifierRunner::Error) do
          runner.call("classify")
        end
      end

      assert_equal retry_at, error.retry_at
    end
  end

  def test_rejects_budget_denial_and_malformed_provider_json
    with_tmp_dir do |dir|
      budget = Object.new
      budget.define_singleton_method(:acquire) { |**| false }
      budget.define_singleton_method(:exhaustion_message) { "daily limit" }
      runner = Hive::RefactorPatrol::MergeClassifierRunner.new(
        project_root: dir,
        cfg: { "execute" => { "agent" => "codex", "model" => "gpt-5.6-sol", "effort" => "high" } },
        launch_budget: budget
      )
      assert_raises(Hive::RefactorPatrol::MergeClassifierRunner::Error) do
        runner.call("classify")
      end

      budget.define_singleton_method(:acquire) { |**| true }
      budget.define_singleton_method(:record!) { |**| nil }
      agent = Object.new
      messages = [ JSON.generate("decision" => "unknown", "rationale" => "x", "evidence" => []), "{" ]
      agent.define_singleton_method(:run!) do
        { status: :ok, final_message: messages.shift, usage: {}, session_id: "session" }
      end
      2.times do
        with_replaced_singleton_method(Hive::Agent, :new, ->(**) { agent }) do
          assert_raises(Hive::RefactorPatrol::MergeClassifierRunner::Error) do
            runner.call("classify")
          end
        end
      end
    end
  end
end
