require "test_helper"
require "hive/plan_review/decision_triage"

class PlanReviewDecisionTriageTest < Minitest::Test
  def finding(source, classification = "gated_auto")
    Hive::PlanReview::Finding.new(
      "source" => source, "classification" => classification, "risk" => "high",
      "title" => "Add successful delivery coverage", "description" => "Test existing requirements",
      "evidence" => { "path" => "plan.md", "start_line" => 1, "end_line" => 1,
                      "anchor_digest" => Digest::SHA256.hexdigest("existing requirement") },
      "lifecycle" => "open", "display_order" => 1
    ).to_h
  end

  def assessment(entries, classification = "safe_auto")
    { "sources" => entries.map { |f| f.fetch("fingerprint") }, "classification" => classification,
      "title" => "Verify successful delivery", "disposition" => "Add the positive-path acceptance test.",
      "rationale" => "The plan already requires successful delivery; this adds no product scope.",
      "boundary" => nil }
  end

  def test_duplicate_high_risk_corrections_become_one_unverified_planner_disposition
    entries = [ finding("primary"), finding("adversarial") ]
    rows = [ assessment(entries) ]
    result = Hive::PlanReview::DecisionTriage.apply(entries, rows)
    assert_equal entries.map { |f| f["fingerprint"] }, result.take(2).map { |f| f["fingerprint"] }
    assert_equal %w[resolved resolved], result.take(2).map { |f| f["lifecycle"] }
    assert_equal "safe_auto", result.last["classification"]
    assert_equal "open", result.last["lifecycle"]
    assert_equal "high", result.last["risk"]
    refute result.last.key?("decision_id")
    assert_equal "open", entries.first["lifecycle"]
  end

  def test_actual_unanswered_replay_policy_stays_a_single_decision
    entries = [ finding("primary", "manual"), finding("adversarial", "manual") ]
    row = assessment(entries, "manual").merge(
      "boundary" => { "requirement" => "Rotation is required but replay behavior is explicitly unanswered.",
                      "change" => "A lost response retry may revoke the connection.",
                      "alternatives" => [ "Strict revocation", "Bounded retry grace" ] })
    result = Hive::PlanReview::DecisionTriage.apply(entries, [ row ])
    assert Hive::PlanReview::Finding.new(result.last).blocking?
    assert_includes result.last["description"], "Bounded retry grace"
  end

  def test_source_order_cannot_lower_risk_or_change_representative_evidence
    entries = [ finding("primary"), finding("adversarial") ]
    entries[1] = Hive::PlanReview::Finding.new(entries[1].except("fingerprint").merge("risk" => "critical")).to_h
    row = assessment(entries)
    forward = Hive::PlanReview::DecisionTriage.apply(entries, [ row ], display_order: 42)
    reverse = Hive::PlanReview::DecisionTriage.apply(entries, [ row.merge("sources" => row["sources"].reverse) ], display_order: 42)
    assert_equal forward, reverse
    assert_equal "critical", forward.last["risk"]
    assert_equal 43, forward.last["display_order"]
    assert_equal entries.first["evidence"], forward.last["evidence"]
  end

  def test_new_verifier_gate_is_reconciled_with_existing_unanswered_gates
    existing = finding("already-assessed", "manual")
    duplicate = finding("verification", "manual")
    approved = finding("operator-approved").merge("lifecycle" => "approved", "decision_id" => "decision-1")
    record = { "findings" => [ existing, approved ], "routes" => [ {
      "role" => "decision_triage", "triage_version" => Hive::PlanReview::DecisionTriage::VERSION,
      "assessed_fingerprints" => [ existing.fetch("fingerprint") ]
    } ] }
    assert_empty Hive::PlanReview::DecisionTriage.pending(record)
    record["findings"] << duplicate
    assert_equal [ existing, duplicate ], Hive::PlanReview::DecisionTriage.pending(record)
    assert_equal "approved", approved.fetch("lifecycle")
  end

  def test_missing_duplicate_unknown_or_unjustified_dispositions_cannot_remove_a_gate
    entries = [ finding("primary"), finding("adversarial") ]
    bad = [ [], [ assessment(entries.take(1)) ], [ assessment(entries), assessment(entries) ],
           [ assessment(entries).merge("sources" => [ "prf-#{'f' * 64}" ]) ],
           [ assessment(entries, "manual") ], [ assessment(entries, "fyi") ] ]
    bad.each do |rows|
      assert_raises(Hive::PlanReview::InvalidRecord) { Hive::PlanReview::DecisionTriage.apply(entries, rows) }
    end
  end
end
