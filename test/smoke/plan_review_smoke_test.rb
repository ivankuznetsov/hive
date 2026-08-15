require "test_helper"
require "digest"
require "json"
require "hive/agent_runtime"
require "hive/plan_review/adapters/ce_doc_review"
require "hive/plan_review/route_resolver"
require "hive/task_meta"

# Opt-in authenticated proof for the preferred independent adversarial route.
# The default suite never launches a paid provider. Run explicitly with:
#
#   HIVE_LIVE_PLAN_REVIEW=1 rake smoke
class PlanReviewSmokeTest < Minitest::Test
  include HiveTestHelper

  def test_native_grok_46_produces_a_valid_independent_review_receipt
    unless ENV["HIVE_LIVE_PLAN_REVIEW"] == "1"
      skip "set HIVE_LIVE_PLAN_REVIEW=1 to run authenticated plan review"
    end

    with_tmp_git_repo do |project_root|
      task = build_task(project_root)
      cfg = Hive::Config.load(project_root)
      planner = {
        "provider" => "claude", "model" => "opus", "family" => "anthropic",
        "effort" => "high", "route" => "native_claude"
      }
      route = Hive::PlanReview::RouteResolver.resolve(
        role: "adversarial", planner_identity: planner, cfg:
      )
      unless route.resolved?
        skip "native Grok plan-review route unavailable: #{route.receipt.fetch('capability_result')}"
      end

      plan_path = File.join(task.folder, "plan.md")
      plan_digest = Digest::SHA256.file(plan_path).hexdigest
      request = Hive::PlanReview::Adapters::Base::Request.new(
        plan_path:, plan_digest:, document_type: "executable_plan",
        level: "mandatory", required_coverage: [ "adversarial" ],
        policy_fingerprint: Digest::SHA256.hexdigest("live-plan-review-policy-v1"),
        planner_identity: planner, reviewer: route.candidate,
        output_directory: File.join(task.folder, "live-plan-review"),
        timeout_sec: 900,
        attempt_id: "pra-#{Digest::SHA256.hexdigest('live-plan-review-attempt-v1')}",
        kind: "adversarial", project_root:
      )
      result = Hive::PlanReview::Adapters::CeDocReview.new(
        runner: Hive::PlanReview::Adapters::CeDocReview::HiveRunner.new(task:, cfg:)
      ).call(request)

      assert result.successful?, result.diagnostic
      assert_equal "grok", result.route_receipt.dig("requested", "provider")
      assert_equal "grok-4.6", result.route_receipt.dig("requested", "model")
      assert_equal "grok", result.route_receipt.dig("actual", "provider")
      assert_equal "grok-4.6", result.route_receipt.dig("actual", "model")
      assert_equal "high", result.route_receipt.dig("actual", "effort")
      assert result.route_receipt.fetch("independence_verified")
      assert(result.coverage.any? do |entry|
        entry["name"] == "adversarial" && entry["status"] == "completed"
      end)
      assert_credentials_absent(result)
    end
  end

  private

  def build_task(project_root)
    folder = File.join(
      project_root, ".hive-state", "stages", "3-plan", "native-grok-plan-review"
    )
    FileUtils.mkdir_p(folder)
    Hive::TaskMeta.write(
      folder, id: 1, slug: "native-grok-plan-review",
      display_name: "Native Grok plan-review smoke"
    )
    File.write(File.join(folder, "task.md"), "# Native Grok plan-review smoke\n")
    File.write(
      File.join(folder, "plan.md"),
      <<~PLAN
        # Plan

        Update `lib/example.rb` and add focused tests in `test/example_test.rb`.

        ## Test scenarios

        - Run the focused unit test for success and failure behavior.

        ## Rollback

        Revert the local commit; there is no persistent data change.
        <!-- COMPLETE -->
      PLAN
    )
    Hive::Task.new(folder)
  end

  def assert_credentials_absent(result)
    serialized = JSON.generate(result.to_h)
    %w[XAI_API_KEY GROK_CODE_XAI_API_KEY].filter_map { |name| ENV[name] }.each do |credential|
      next if credential.empty?

      refute_includes serialized, credential
    end
  end
end
