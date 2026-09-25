require "test_helper"
require "stringio"
require "hive/commands/plan_review_show"

class PlanReviewShowCommandTest < Minitest::Test
  include HiveTestHelper

  FakeProjection = Struct.new(:summary, :record)
  FakeTask = Struct.new(:slug, :folder, :project_root)

  def projection
    summary = {
      "review_id" => "pr-1", "task_generation" => 7, "policy_fingerprint" => "f" * 64,
      "observation_digest" => "a" * 64, "state" => "awaiting_decision", "outcome" => nil,
      "execution_allowed" => false, "required_action" => "approve gated plan finding prf-2"
    }
    findings = [
      { "fingerprint" => "prf-2", "classification" => "gated_auto", "risk" => "high",
        "lifecycle" => "open", "title" => "second", "display_order" => 2 },
      { "fingerprint" => "prf-1", "classification" => "manual", "risk" => "medium",
        "lifecycle" => "open", "title" => "first", "display_order" => 1 },
      { "fingerprint" => "prf-3", "classification" => "safe_auto", "risk" => "low",
        "lifecycle" => "resolved", "title" => "done", "display_order" => 3 }
    ]
    FakeProjection.new(summary, { "findings" => findings })
  end

  def run_show(json:, freshness: { "status" => "current", "reason" => nil })
    task = FakeTask.new("demo-task", "/tmp/demo-task", "/tmp/demo-project")
    out = StringIO.new
    payload = nil
    fixture = projection
    with_replaced_singleton_method(Hive::PlanReview::Projection, :load, ->(task_folder:) { fixture }) do
      original = $stdout
      $stdout = out
      begin
        payload = Hive::Commands::PlanReviewShow.new(
          "demo-task", json: json, resolver: -> { task }, freshness: ->(*) { freshness }
        ).call
      ensure
        $stdout = original
      end
    end
    [ payload, out.string ]
  end

  def test_show_returns_live_decision_identities_and_open_findings_in_order
    payload, stdout = run_show(json: true)

    schema = JSON.parse(File.read(File.expand_path("../../../schemas/hive-plan-review-show.v1.json", __dir__)))
    assert_equal schema.fetch("required").sort, payload.keys.sort
    assert_equal payload, JSON.parse(stdout)
    assert_equal "hive-plan-review-show", payload["schema"]
    assert_equal "7", payload["task_generation"], "generation is a string, as the decision flags expect"
    assert_equal "a" * 64, payload["observation_digest"]
    assert_equal %w[prf-1 prf-2], payload["open_findings"].map { |finding| finding["fingerprint"] }
    assert_equal %w[classification fingerprint lifecycle risk title], payload["open_findings"].first.keys.sort
  end

  def test_show_prints_a_human_summary_without_json
    _payload, stdout = run_show(json: false)

    assert_match(/plan review pr-1 awaiting_decision for demo-task/, stdout)
    assert_match(/observation_digest: a{64}/, stdout)
    assert_match(/prf-1 \[manual, medium\] first/, stdout)
    refute_match(/prf-3/, stdout)
  end

  def test_show_reports_a_stale_review_so_decisions_are_not_attempted
    stale = { "status" => "stale", "reason" => "canonical plan changed after plan review" }
    payload, = run_show(json: true, freshness: stale)
    assert_equal stale, payload["freshness"]

    _payload, stdout = run_show(json: false, freshness: stale)
    assert_match(/freshness: stale \(canonical plan changed after plan review\); decisions need a linked review first/, stdout)
  end

  def test_default_dependencies_resolve_the_task_and_calculate_freshness
    task = FakeTask.new("demo-task", "/tmp/demo-task", "/tmp/demo-project")
    resolver = Struct.new(:resolve).new(task)
    freshness = { status: "current", reason: nil }
    fixture = projection
    config_root = nil
    freshness_inputs = nil

    with_replaced_singleton_method(Hive::TaskResolver, :new, ->(*) { resolver }) do
      with_replaced_singleton_method(Hive::Config, :load, ->(root) { config_root = root; {} }) do
        with_replaced_singleton_method(
          Hive::PlanReview::TransitionGuard, :freshness,
          ->(task:, projection:, config:) { freshness_inputs = [ task, projection, config ]; freshness }
        ) do
          with_replaced_singleton_method(Hive::PlanReview::Projection, :load, ->(task_folder:) { fixture }) do
            payload = nil
            capture_io { payload = Hive::Commands::PlanReviewShow.new("demo-task", json: true).call }
            assert_equal({ "status" => "current", "reason" => nil }, payload.fetch("freshness"))
          end
        end
      end
    end

    assert_equal task.project_root, config_root
    assert_equal [ task, fixture, {} ], freshness_inputs
  end

  def test_envelope_error_kind_classifies_resolver_and_plan_review_errors
    command = Hive::Commands::PlanReviewShow.new("demo-task", resolver: -> { raise "not called" })

    {
      Hive::AmbiguousSlug.new("ambiguous", slug: "demo-task", candidates: []) => "ambiguous_slug",
      Hive::InvalidTaskPath.new("bad path") => "invalid_task_path",
      Hive::PlanReview::Error.new("review unavailable") => "plan_review_unavailable",
      StandardError.new("unclassified") => "error"
    }.each do |error, expected|
      assert_equal expected, command.envelope_error_kind(error), error.class.name
    end
  end
end
