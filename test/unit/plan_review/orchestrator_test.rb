require "test_helper"
require "hive/config"
require "hive/plan_review/orchestrator"

class PlanReviewOrchestratorTest < Minitest::Test
  Workflow = Struct.new(:id, keyword_init: true)
  Task = Struct.new(
    :folder, :project_root, :slug, :id, :workflow, :meta_yml_path,
    keyword_init: true
  )

  class FakeAdapter
    attr_reader :calls

    def initialize(&response)
      @response = response
      @calls = []
    end

    def call(request)
      @calls << request
      @response.call(request)
    end
  end

  class FakeRevision
    attr_reader :calls

    def initialize(candidate)
      @candidate = candidate
      @calls = []
    end

    def call(**arguments)
      @calls << arguments
      Hive::PlanReview::PlannerRevision::Result.new(
        outcome: "success", candidate_bytes: @candidate,
        candidate_digest: Digest::SHA256.hexdigest(@candidate),
        route_receipt: arguments.fetch(:planner_identity), diagnostic: nil
      )
    end
  end

  def test_skip_records_clearance_without_any_reviewer_call
    with_task(skip_plan) do |task, cfg|
      adapter = FakeAdapter.new { flunk "skip must not invoke a reviewer" }
      projection = orchestrator(task, cfg, adapter:).advance!

      assert_equal "skipped", projection.record.state
      assert projection.record.execution_allowed?
      assert_empty adapter.calls
      assert_equal 0, projection.summary.fetch("attempt_count")
    end
  end

  def test_standard_safe_change_uses_one_revision_and_one_verification
    revised = standard_plan.sub("# Plan", "# Revised plan")
    with_task(standard_plan) do |task, cfg|
      finding = finding("safe_auto", "Clarify tests")
      adapter = success_adapter(primary_findings: [ finding ])
      revision = FakeRevision.new(revised)
      projection = orchestrator(task, cfg, adapter:, planner_revision: revision).advance!

      assert_equal "cleared", projection.record.state
      assert projection.record.execution_allowed?
      assert_equal %w[primary adversarial verification], adapter.calls.map(&:kind)
      assert_equal 1, revision.calls.length
      assert_equal revised, File.binread(File.join(task.folder, "plan.md"))
      assert_equal 3, projection.record["attempt_ids"].length
      assert_equal "verified", projection.record["findings"].first.fetch("lifecycle")
    end
  end

  def test_manual_finding_pauses_before_revision_or_verification
    with_task(standard_plan) do |task, cfg|
      adapter = success_adapter(primary_findings: [ finding("manual", "Choose rollback") ])
      revision = FakeRevision.new(standard_plan)
      projection = orchestrator(task, cfg, adapter:, planner_revision: revision).advance!

      assert_equal "awaiting_decision", projection.record.state
      assert_equal %w[primary adversarial], adapter.calls.map(&:kind)
      assert_empty revision.calls
      assert_equal 1, projection.summary.dig("finding_counts", "open_manual")
    end
  end

  def test_exact_scoped_policy_approves_gated_finding_with_a_receipt
    revised = standard_plan.sub("# Plan", "# Revised plan")
    with_task(standard_plan) do |task, cfg|
      cfg["plan_review"]["approval_policies"] = [
        {
          "id" => "plan_wording", "version" => 1,
          "action" => "approve_finding", "risk" => "low",
          "paths" => [ "plan.md" ],
          "valid_from" => "2026-08-12T00:00:00Z",
          "valid_until" => "2026-08-13T00:00:00Z", "revoked" => false
        }
      ]
      adapter = success_adapter(primary_findings: [ finding("gated_auto", "Clarify tests") ])
      revision = FakeRevision.new(revised)
      projection = orchestrator(task, cfg, adapter:, planner_revision: revision).advance!

      assert_equal "cleared", projection.record.state
      assert_equal 1, projection.record["decisions"].length
      decision = projection.record["decisions"].first
      assert_equal "policy", decision.fetch("origin")
      assert_equal "plan_wording", decision.dig("policy_receipt", "policy_id")
      assert_equal 1, revision.calls.length
    end
  end

  def test_coverage_rows_have_stable_review_bound_fingerprints
    with_task(standard_plan) do |task, cfg|
      adapter = success_adapter
      projection = orchestrator(task, cfg, adapter:).advance!

      projection.record["coverage"].each do |entry|
        assert_equal Hive::PlanReview::Identity.coverage(
          review_id: projection.record.review_id, name: entry.fetch("name"),
          policy_fingerprint: projection.record.policy_fingerprint
        ), entry.fetch("fingerprint")
      end
    end
  end

  def test_standard_total_unavailability_degrades_but_mandatory_blocks
    [ [ standard_plan, "degraded_cleared", "review_unavailable" ],
      [ mandatory_plan, "blocked", nil ] ].each do |plan, state, degradation|
      with_task(plan) do |task, cfg|
        adapter = FakeAdapter.new do |_request|
          Hive::PlanReview::Adapters::Base::Result.new(outcome: "unsupported")
        end
        projection = orchestrator(task, cfg, adapter:).advance!

        assert_equal state, projection.record.state
        degradation ? assert_equal(degradation, projection.record["degradation_reason"]) :
          assert_nil(projection.record["degradation_reason"])
        assert_equal %w[primary adversarial], adapter.calls.map(&:kind)
      end
    end
  end

  def test_new_verification_finding_blocks_without_a_second_revision
    revised = standard_plan.sub("# Plan", "# Revised plan")
    with_task(standard_plan) do |task, cfg|
      initial = finding("safe_auto", "Clarify tests")
      regression = finding("safe_auto", "New regression", line: 2)
      adapter = success_adapter(
        primary_findings: [ initial ], verification_findings: [ regression ]
      )
      revision = FakeRevision.new(revised)
      projection = orchestrator(task, cfg, adapter:, planner_revision: revision).advance!

      assert_equal "blocked", projection.record.state
      assert_equal 1, revision.calls.length
      assert_equal 1, adapter.calls.count { |request| request.kind == "verification" }
      assert_equal standard_plan, File.binread(File.join(task.folder, "plan.md"))
    end
  end

  def test_transient_attempt_retries_within_bound_but_unsupported_does_not
    with_task(standard_plan) do |task, cfg|
      primary_calls = 0
      adapter = FakeAdapter.new do |request|
        if request.kind == "primary" && (primary_calls += 1) == 1
          Hive::PlanReview::Adapters::Base::Result.new(outcome: "timeout")
        else
          successful_result(request)
        end
      end
      projection = orchestrator(task, cfg, adapter:).advance!

      assert_equal "cleared", projection.record.state
      assert_equal 2, adapter.calls.count { |request| request.kind == "primary" }
      assert_equal 4, projection.record["attempt_ids"].length
    end

    with_task(standard_plan) do |task, cfg|
      adapter = FakeAdapter.new do |request|
        request.kind == "primary" ?
          Hive::PlanReview::Adapters::Base::Result.new(outcome: "unsupported") :
          successful_result(request)
      end
      projection = orchestrator(task, cfg, adapter:).advance!

      assert_equal "degraded_cleared", projection.record.state
      assert_equal 1, adapter.calls.count { |request| request.kind == "primary" }
    end
  end

  def test_optional_specialist_failure_is_distinct_partial_coverage
    with_task(standard_plan) do |task, cfg|
      cfg["plan_review"]["coverage"]["optional"] = [ "security" ]
      adapter = FakeAdapter.new do |request|
        if request.kind == "primary"
          coverage = request.required_coverage.map do |name|
            {
              "name" => name, "required" => name != "security",
              "status" => name == "security" ? "failed" : "completed"
            }
          end
          Hive::PlanReview::Adapters::Base::Result.new(
            outcome: "partial_coverage", coverage:
          )
        else
          successful_result(request)
        end
      end
      projection = orchestrator(task, cfg, adapter:).advance!

      assert_equal "degraded_cleared", projection.record.state
      assert_equal "partial_coverage", projection.record["degradation_reason"]
      assert_equal 1, adapter.calls.count { |request| request.kind == "verification" }
    end
  end

  private

  def orchestrator(task, cfg, adapter:, planner_revision: FakeRevision.new(standard_plan))
    Hive::PlanReview::Orchestrator.new(
      task:, cfg:, planner_identity: planner_identity, adapter:,
      planner_revision:, route_resolver: method(:resolve_route),
      clock: -> { Time.utc(2026, 8, 12, 12) }
    )
  end

  def resolve_route(role:, **)
    candidate = {
      "provider" => role == "adversarial" ? "grok" : "codex",
      "model" => role == "adversarial" ? "grok-4.6" : "gpt-5.6-sol",
      "family" => role == "adversarial" ? "grok" : "openai",
      "effort" => "high", "route" => "native_#{role}"
    }
    Hive::PlanReview::RouteResolver::Resolution.new(
      status: "resolved", candidate: candidate,
      receipt: {
        "role" => role, "requested" => candidate, "actual" => candidate,
        "capability_result" => "present", "independence_verified" => true
      }
    )
  end

  def success_adapter(primary_findings: [], verification_findings: [])
    FakeAdapter.new do |request|
      findings = case request.kind
      when "primary" then primary_findings
      when "verification" then verification_findings
      else []
      end
      successful_result(request, findings:)
    end
  end

  def successful_result(request, findings: [])
    Hive::PlanReview::Adapters::Base::Result.new(
        outcome: "success", findings:,
        coverage: request.required_coverage.map do |name|
          { "name" => name, "required" => true, "status" => "completed" }
        end,
        route_receipt: {
          "role" => request.kind, "requested" => request.reviewer,
          "actual" => request.reviewer, "capability_result" => "present",
          "independence_verified" => true
        }
      )
  end

  def finding(classification, title, line: 1)
    Hive::PlanReview::Finding.new(
      "source" => "whole_document", "classification" => classification,
      "risk" => classification == "manual" ? "high" : "low",
      "title" => title, "description" => "#{title} in the executable plan.",
      "evidence" => {
        "path" => "plan.md", "start_line" => line, "end_line" => line,
        "anchor_digest" => Digest::SHA256.hexdigest("line #{line}")
      },
      "lifecycle" => "open", "display_order" => line
    )
  end

  def with_task(plan)
    Dir.mktmpdir("hive-plan-orchestrator") do |project|
      folder = File.join(project, ".hive-state", "stages", "3-plan", "demo-task")
      FileUtils.mkdir_p(folder)
      meta = File.join(folder, "meta.yml")
      File.write(meta, "id: task-1\nslug: demo-task\nworkflow: coding\n")
      File.write(File.join(folder, "plan.md"), plan)
      task = Task.new(
        folder:, project_root: project, slug: "demo-task", id: "task-1",
        workflow: Workflow.new(id: :coding), meta_yml_path: meta
      )
      cfg = Marshal.load(Marshal.dump(Hive::Config::DEFAULTS))
      cfg["project_root"] = project
      yield task, cfg
    end
  end

  def skip_plan
    <<~MD
      ---
      files:
        - lib/demo.rb
        - test/demo_test.rb
      ---
      # Plan
      ## Test scenarios
      - The focused test passes.
      ## Rollback
      Revert the local change; it is reversible.
      <!-- COMPLETE -->
    MD
  end

  def standard_plan
    <<~MD
      ---
      files:
        - lib/demo.rb
        - test/demo_test.rb
      ---
      # Plan
      ## Test scenarios
      - The focused test passes.
      <!-- COMPLETE -->
    MD
  end

  def mandatory_plan
    standard_plan.sub("# Plan", "# Plan\nUpdate authentication permissions")
  end

  def planner_identity
    {
      "provider" => "claude", "model" => "opus", "family" => "anthropic",
      "effort" => "high", "route" => "native_claude"
    }
  end
end
