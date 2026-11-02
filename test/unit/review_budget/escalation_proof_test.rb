require "test_helper"
require "hive/review_budget"

class ReviewBudgetEscalationProofTest < Minitest::Test
  Proof = Hive::ReviewBudget::EscalationProof

  def test_qa_proof_allows_only_filling_original_empty_answers
    original = "# Context\n### Q1. Decide?\n### A1.\n\n### Q2. Prior decision?\n### A2.\nKeep it.\n"
    before = Proof.capture("escalations-100.md", original)
    assert Proof.valid?(before)
    assert_equal "qa", before.fetch("kind")
    assert Proof.fills_only?(before, Proof.capture("escalations-100.md", original.sub("### A1.\n", "### A1.\nApply the approved fix.\n")))
    refute Proof.fills_only?(before, Proof.capture("escalations-100.md", original.sub("Decide?", "Different question?")))
    refute Proof.fills_only?(before, Proof.capture("escalations-100.md", original.sub("Keep it.", "Remove it.")))
    refute Proof.fills_only?(before, Proof.capture("escalations-100.md", original + "### Q3. Extra?\n### A3.\n"))
  end

  def test_legacy_checkbox_proof_allows_accepting_but_preserves_old_decisions_and_text
    original = "- [ ] Pending question\n- [x] Previously accepted\n"
    before = Proof.capture("escalations-04.md", original)
    assert Proof.valid?(before)
    assert_equal "checkbox", before.fetch("kind")
    assert Proof.fills_only?(before, Proof.capture("escalations-04.md", original.sub("[ ]", "[x]")))
    refute Proof.fills_only?(before, Proof.capture("escalations-04.md", original.sub("Previously accepted", "Changed work")))
    refute Proof.fills_only?(before, Proof.capture("escalations-04.md", original.sub("[x]", "[ ]")))
  end

  def test_literal_proof_and_strict_shape_validation
    proof = Proof.capture("escalations-04.md", "# No questions\n")
    assert_equal "literal", proof.fetch("kind")
    assert Proof.valid?(proof)
    refute Proof.valid?(nil)
    refute Proof.valid?(proof.merge("unknown" => "field"))
    refute Proof.valid?(proof.merge("name" => "codex-04.md"))
    refute Proof.valid?(proof.merge("kind" => "unknown"))
    refute Proof.valid?(proof.merge("framing_digest" => "bad"))
    refute Proof.valid?(proof.merge("answers" => nil))
    refute Proof.valid?(proof.merge("answers" => [ nil ]))
    refute Proof.valid?(proof.merge("answers" => [ { "digest" => "bad", "empty" => true } ]))
    refute Proof.valid?(proof.merge("answers" => [ { "digest" => "a" * 64, "empty" => nil } ]))
  end
end
