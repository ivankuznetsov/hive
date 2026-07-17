require "test_helper"
require "hive/refactor_patrol/semantic_descriptor"
require "hive/refactor_patrol/thesis"

class RefactorPatrolSemanticDescriptorTest < Minitest::Test
  SemanticDescriptor = Hive::RefactorPatrol::SemanticDescriptor

  def test_derives_a_canonical_language_neutral_descriptor
    descriptor = SemanticDescriptor.call(
      thesis: thesis,
      source: source
    )

    assert_equal "acme/polyglot", descriptor.fetch("repository")
    assert_equal "architecture-services-checkout", descriptor.fetch("component")
    assert_equal "duplicated_policy", descriptor.fetch("problem_kind")
    assert_equal "consolidate_policy", descriptor.fetch("refactor_kind")
    assert_equal %w[services/checkout/authorize.ts services/checkout/route.ts], descriptor.fetch("anchors")
    assert_includes descriptor.fetch("concepts"), "checkout"
    assert_includes descriptor.fetch("concepts"), "payment"
    assert_includes descriptor.fetch("concepts"), "routing"
    assert_includes descriptor.fetch("concepts"), "validation"
    refute_includes descriptor.fetch("concepts"), "typescript"
    refute_includes descriptor.fetch("concepts"), "refactor"
    refute_includes descriptor.fetch("concepts"), "consolidate"
    refute_includes descriptor.fetch("concepts"), "policy"
  end

  def test_semantically_equivalent_theses_are_stable_across_languages_and_order
    descriptors = {
      ruby: %w[lib/orders/authorize.rb lib/orders/route.rb],
      typescript: %w[src/orders/authorize.ts src/orders/route.ts],
      python: %w[orders/authorize.py orders/route.py],
      go: %w[internal/orders/authorize.go internal/orders/route.go]
    }.map do |language, paths|
      item = thesis(
        feature_id: "architecture-order-processing-part-3",
        feature: "Order processing",
        problem: "Authorization policy is duplicated across payment routing handlers",
        proposed_refactor: "Centralize the authorization policy for payment routing",
        evidence: paths.reverse.map do |path|
          {
            "file" => path,
            "line" => 8,
            "claim" => "Payment routing repeats the same authorization decision"
          }
        end
      )
      [ language, SemanticDescriptor.call(thesis: item, source: source) ]
    end.to_h

    semantic_shapes = descriptors.transform_values { |value| value.reject { |key, _| key == "anchors" } }
    assert_equal 1, semantic_shapes.values.uniq.size
    descriptors.each do |language, descriptor|
      assert_equal "architecture-order-processing", descriptor.fetch("component")
      assert_equal "duplicated_policy", descriptor.fetch("problem_kind"), language
      assert_equal "consolidate_policy", descriptor.fetch("refactor_kind"), language
      refute descriptor.fetch("concepts").any? { |token| token.match?(/\A(?:rb|ts|py|go)\z/) }
    end
  end

  def test_evidence_and_driver_order_do_not_change_descriptor
    original = thesis
    reordered = thesis(
      evidence: original.evidence.reverse,
      expected_leverage: original.expected_leverage.merge(
        "drivers" => original.expected_leverage.fetch("drivers").reverse
      )
    )

    assert_equal SemanticDescriptor.call(thesis: original, source: source),
                 SemanticDescriptor.call(thesis: reordered, source: source)
  end

  def test_uses_mapper_boundary_as_anchor_fallback_without_inspecting_extensions
    item = thesis(
      evidence: [ { "claim" => "Responsibilities remain coupled" } ],
      feature_boundary: {
        "owned_files" => %w[src/billing/core.rs src/billing/ledger.rs],
        "entrypoints" => [ "src/billing/lib.rs" ]
      }
    )

    descriptor = SemanticDescriptor.call(thesis: item, source: source)

    assert_equal %w[src/billing/core.rs src/billing/ledger.rs src/billing/lib.rs], descriptor.fetch("anchors")
  end

  def test_maps_controlled_problem_and_refactor_taxonomy_without_ecosystem_terms
    cases = [
      [ "A dependency cycle connects the storage and domain layers", "Invert the dependency direction", "cyclic_dependency", "invert_dependency" ],
      [ "Callers bypass the service boundary and leak persistence details", "Introduce an adapter at the service edge", "boundary_leak", "introduce_adapter" ],
      [ "The protocol contract is scattered and inconsistent across clients", "Unify the protocol contract", "scattered_contract", "consolidate_contract" ],
      [ "One component is oversized and has too many unrelated duties", "Split the component by capability", "oversized_component", "split_component" ],
      [ "The coordinator mixes unrelated responsibilities", "Move persistence responsibility to the repository boundary", "mixed_responsibilities", "move_responsibility" ],
      [ "Two parallel implementations provide the same behavior", "Extract a shared boundary for the behavior", "parallel_implementations", "extract_boundary" ],
      [ "Volatile infrastructure dependencies force cascading changes", "Invert dependency ownership", "unstable_dependency", "invert_dependency" ],
      [ "There is no shared abstraction for dispatch decisions", "Introduce an adapter for dispatch", "missing_abstraction", "introduce_adapter" ]
    ]

    cases.each do |problem, proposal, expected_problem, expected_refactor|
      descriptor = SemanticDescriptor.call(
        thesis: thesis(
          problem: problem,
          cost: problem,
          proposed_refactor: proposal,
          evidence: [ { "file" => "src/domain/core.kt", "line" => 5, "claim" => problem } ],
          expected_leverage: {
            "drivers" => [ { "signal" => "coupling", "relief" => 0.5, "mechanism" => proposal } ]
          }
        ),
        source: source
      )
      assert_equal expected_problem, descriptor.fetch("problem_kind"), problem
      assert_equal expected_refactor, descriptor.fetch("refactor_kind"), proposal
    end
  end

  def test_rejects_missing_repository_or_anchor_instead_of_inventing_identity
    missing_anchor = thesis(evidence: [], feature_boundary: { "owned_files" => [], "entrypoints" => [] })

    assert_raises(ArgumentError) { SemanticDescriptor.call(thesis: thesis, source: {}) }
    assert_raises(ArgumentError) { SemanticDescriptor.call(thesis: missing_anchor, source: source) }
  end

  def test_rejects_a_malformed_source_url
    error = assert_raises(ArgumentError) do
      SemanticDescriptor.call(
        thesis: thesis,
        source: { "repository" => "acme/polyglot", "url" => "https://[" }
      )
    end

    assert_equal "source URL must include an exact host", error.message
  end

  def test_unknown_shapes_fall_back_without_language_or_model_invention
    item = {
      "feature_id" => "x",
      "feature" => "",
      "problem" => "",
      "cost" => "",
      "proposed_refactor" => "",
      "evidence" => [ Object.new ],
      "feature_boundary" => {
        "owned_files" => [ "src/core.unknown" ],
        "entrypoints" => []
      },
      "expected_leverage" => { "drivers" => [ Object.new ] }
    }

    descriptor = SemanticDescriptor.call(thesis: item, source: source)

    assert_equal "other", descriptor.fetch("problem_kind")
    assert_equal "other", descriptor.fetch("refactor_kind")
    assert_equal [ "src/core.unknown" ], descriptor.fetch("anchors")
    assert_equal [ "unspecified" ], descriptor.fetch("concepts")
  end

  def test_object_thesis_with_an_absent_optional_field_uses_nil
    item = Object.new
    {
      feature_id: "architecture-core",
      feature: "Core",
      problem: "Repeated policy decisions",
      proposed_refactor: "Consolidate policy decisions",
      evidence: [ { "file" => "src/core.rb", "claim" => "policy repeats" } ],
      feature_boundary: { "owned_files" => [ "src/core.rb" ], "entrypoints" => [] },
      expected_leverage: { "drivers" => [] }
    }.each do |name, value|
      item.define_singleton_method(name) { value }
    end

    descriptor = SemanticDescriptor.call(thesis: item, source: source)

    assert_equal "duplicated_policy", descriptor.fetch("problem_kind")
  end

  private

  def source
    { "repository" => "Acme/Polyglot", "number" => 42, "url" => "https://example.test/acme/polyglot/pull/42" }
  end

  def thesis(feature_id: "architecture-services-checkout-part-2", feature: "Checkout routing",
             problem: "Validation policy is duplicated across payment routing handlers",
             cost: "Payment changes repeatedly touch authorization and routing",
             proposed_refactor: "Consolidate checkout validation policy behind one payment routing decision",
             evidence: nil, feature_boundary: nil, expected_leverage: nil)
    evidence ||= [
      {
        "file" => "services/checkout/route.ts",
        "line" => 12,
        "claim" => "Payment routing repeats checkout validation policy"
      },
      {
        "file" => "services/checkout/authorize.ts",
        "line" => 24,
        "claim" => "Checkout authorization repeats the validation decision"
      }
    ]
    expected_leverage ||= {
      "score" => 0.7,
      "breakdown" => { "churn" => 0.4 },
      "drivers" => [
        { "signal" => "churn", "relief" => 0.5, "mechanism" => "Isolate payment routing edits" },
        { "signal" => "coupling", "relief" => 0.4, "mechanism" => "Give checkout one validation policy" }
      ]
    }

    Hive::RefactorPatrol::Thesis.new(
      id: "checkout-refactor-1",
      feature_id: feature_id,
      feature: feature,
      problem: problem,
      cost: cost,
      evidence: evidence,
      proposed_refactor: proposed_refactor,
      feature_boundary: feature_boundary || {
        "owned_files" => %w[services/checkout/authorize.ts services/checkout/route.ts],
        "entrypoints" => [ "services/checkout/route.ts" ]
      },
      feature_hotspot: {},
      expected_leverage: expected_leverage,
      confidence: "high",
      risk: {},
      required_validation: {},
      admissible: true,
      admissibility_reason: "anchored",
      follow_up_approval_state: "pending",
      fingerprint: "fp-checkout"
    )
  end
end
