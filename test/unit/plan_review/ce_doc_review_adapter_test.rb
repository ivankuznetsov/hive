require "test_helper"
require "hive/plan_review/adapters/ce_doc_review"

class PlanReviewCeDocReviewAdapterTest < Minitest::Test
  def test_success_uses_disposable_plan_and_validates_machine_output
    with_request do |request, plan_path|
      original = File.binread(plan_path)
      runner = lambda do |prompt:, cwd:, output_path:, request:, **|
        refute_equal File.dirname(plan_path), cwd
        assert_includes prompt, "ce-doc-review"
        File.write(File.join(cwd, "plan.md"), "reviewer mutation")
        File.write(output_path, JSON.generate(valid_result(request)))
        { "status" => "ok", "actual_route" => request.reviewer }
      end
      adapter = Hive::PlanReview::Adapters::CeDocReview.new(
        runner:,
        capability_probe: ->(**) { { "status" => "present", "path" => "/skills/ce-doc-review/SKILL.md" } }
      )

      result = adapter.call(request)

      assert_equal "success", result.outcome
      assert_equal original, File.binread(plan_path)
      assert_equal 1, result.findings.length
    end
  end

  def test_stable_unsupported_does_not_invoke_runner
    calls = 0
    with_request do |request, _plan_path|
      adapter = Hive::PlanReview::Adapters::CeDocReview.new(
        runner: ->(**) { calls += 1 },
        capability_probe: ->(**) { { "status" => "unsupported", "diagnostic" => "missing skill" } }
      )
      result = adapter.call(request)
      assert_equal "unsupported", result.outcome
      assert_equal 0, calls
    end
  end

  def test_route_receipt_normalizes_model_family_before_attesting_independence
    with_request do |request, _plan_path|
      runner = lambda do |output_path:, request:, **|
        File.write(output_path, JSON.generate(valid_result(request)))
        {
          "status" => "ok",
          "actual_route" => request.reviewer.merge("family" => " CLAUDE ")
        }
      end
      adapter = adapter_for(runner)

      receipt = adapter.call(request).route_receipt

      refute receipt.fetch("independence_verified")
      assert_equal "same_model_family", receipt.fetch("independence_reason")
    end
  end

  def test_timeout_limit_retryable_and_canonical_mutation_are_distinct
    outcomes = {
      "timeout" => { "status" => "timeout" },
      "provider_limit" => { "status" => "provider_limit", "retry_at" => "2026-08-12T13:00:00Z" },
      "retryable_failure" => { "status" => "retryable_failure" }
    }
    outcomes.each do |expected, runner_result|
      with_request do |request, _plan_path|
        adapter = adapter_for(->(**) { runner_result })
        assert_equal expected, adapter.call(request).outcome
      end
    end

    with_request do |request, plan_path|
      adapter = adapter_for(lambda do |**|
        File.write(plan_path, "tampered")
        { "status" => "ok" }
      end)
      assert_equal "terminal_failure", adapter.call(request).outcome
    end
  end

  def test_result_nested_evidence_is_immutable
    result = Hive::PlanReview::Adapters::Base::Result.new(
      outcome: "success",
      coverage: [ { "name" => "whole_document", "status" => "completed" } ],
      route_receipt: { "actual" => { "family" => "openai" } }
    )

    assert_predicate result.coverage.first, :frozen?
    assert_predicate result.route_receipt.fetch("actual"), :frozen?
    assert_raises(FrozenError) { result.coverage.first["status"] = "failed" }
  end

  private

  def adapter_for(runner)
    Hive::PlanReview::Adapters::CeDocReview.new(
      runner:,
      capability_probe: ->(**) { { "status" => "present" } }
    )
  end

  def with_request
    Dir.mktmpdir("hive-plan-review-adapter") do |root|
      plan_path = File.join(root, "input-plan.md")
      File.write(plan_path, "# Plan\n")
      output = File.join(root, "output")
      FileUtils.mkdir_p(output)
      request = Hive::PlanReview::Adapters::Base::Request.new(
        plan_path:, plan_digest: Digest::SHA256.file(plan_path).hexdigest,
        document_type: "executable_plan", level: "standard",
        required_coverage: %w[whole_document adversarial],
        policy_fingerprint: "c" * 64,
        planner_identity: { "provider" => "claude", "family" => "claude" },
        reviewer: {
          "provider" => "codex", "model" => "gpt-5.6-sol", "family" => "openai",
          "effort" => "high", "route" => "native"
        },
        output_directory: output, timeout_sec: 60,
        attempt_id: "pra-#{'a' * 64}", kind: "primary", project_root: root
      )
      yield request, plan_path
    end
  end

  def valid_result(request)
    {
      "schema" => "hive-plan-review-adapter-result", "schema_version" => 1,
      "attempt_id" => request.attempt_id, "plan_digest" => request.plan_digest,
      "policy_fingerprint" => request.policy_fingerprint, "outcome" => "success",
      "findings" => [
        {
          "source" => "whole_document", "classification" => "safe_auto", "risk" => "low",
          "title" => "Clarify test", "description" => "Name the focused test.",
          "evidence" => {
            "path" => "plan.md", "start_line" => 1, "end_line" => 1,
            "anchor_digest" => Digest::SHA256.hexdigest("# Plan")
          },
          "lifecycle" => "open", "display_order" => 1
        }
      ],
      "coverage" => request.required_coverage.map do |name|
        { "name" => name, "required" => true, "status" => "completed" }
      end,
      "selected_lenses" => [ "coherence" ], "residual_evidence" => [], "diagnostic" => nil
    }
  end
end
