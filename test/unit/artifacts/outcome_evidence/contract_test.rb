require "test_helper"
require "hive/artifacts/outcome_evidence/contract"

class OutcomeEvidenceContractTest < Minitest::Test
  Contract = Hive::Artifacts::OutcomeEvidence::Contract

  def test_accepts_bounded_outcome_claims_and_exclusions_with_full_path_traceability
    paths = (1..12).map { |number| "app/feature_#{number}.rb" }
    requirement = Contract.requirement!(
      implementation: { "changed_paths" => paths },
      claims: [
        claim("claim-flow", "A buyer can finish checkout and see the confirmation state.", "video", paths.first(5)),
        claim("claim-history", "The order history shows the completed purchase after checkout.", "screenshot", paths.slice(5, 4))
      ],
      exclusions: [
        exclusion("exclude-support", "Supporting test and refactor paths do not add another user outcome.", paths.last(3))
      ],
      inference: { "context_id" => "inference-1", "agent" => "claude" }
    )

    assert_equal %w[claim-flow claim-history], requirement.fetch("claims").map { |item| item.fetch("id") }
    assert_equal paths.sort, requirement.fetch("traceability").keys.sort
  end

  def test_rejects_missing_coverage_unsupported_exclusions_vague_claims_and_wrong_proof_kinds
    paths = %w[app/checkout.rb test/checkout_test.rb]
    base = {
      implementation: { "changed_paths" => paths },
      claims: [ claim("claim-flow", "A buyer can finish checkout and see confirmation.", "video", [ paths.first ]) ],
      exclusions: [ exclusion("exclude-tests", "The regression test supports the checkout outcome without adding one.", [ paths.last ]) ],
      inference: { "context_id" => "inference-1", "agent" => "claude" }
    }

    assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
      Contract.requirement!(**base.merge(exclusions: []))
    end
    assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
      Contract.requirement!(**base.merge(claims: [ claim("claim-flow", "Works as expected.", "video", [ paths.first ]) ]))
    end
    assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
      Contract.requirement!(**base.merge(claims: [ claim("claim-flow", "A buyer can finish checkout and see confirmation.", "archive", [ paths.first ]) ]))
    end
    assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
      bad = exclusion("exclude-tests", "The regression test supports the checkout outcome without adding one.", [ paths.last ])
      bad["reason"] = "Not relevant."
      Contract.requirement!(**base.merge(exclusions: [ bad ]))
    end
  end

  def test_acceptance_requires_distinct_contexts_complete_claim_proof_and_inspected_hashes
    requirement = Contract.requirement!(
      implementation: { "changed_paths" => %w[app/checkout.rb] },
      claims: [ claim("claim-flow", "A buyer can finish checkout and see confirmation.", "video", %w[app/checkout.rb]) ],
      exclusions: [],
      inference: { "context_id" => "inference-1", "agent" => "claude" }
    )
    evidence = [
      {
        "kind" => "video", "claims" => [ "claim-flow" ],
        "representations" => [
          { "sha256" => "a" * 64 }, { "sha256" => "b" * 64 }
        ]
      }
    ]
    producer = { "context_id" => "producer-1", "agent" => "claude" }
    reviewer = { "context_id" => "reviewer-1", "agent" => "claude" }
    output = {
      "inspected_hashes" => [ "a" * 64, "b" * 64 ],
      "verdicts" => [
        { "target_id" => "claim-flow", "verdict" => "accepted", "reason" => "The temporal recording shows the checkout transition and confirmation." }
      ]
    }

    canonical = Contract.review!(
      requirement: requirement, evidence: evidence,
      producer: producer, reviewer: reviewer, output: output
    )
    assert canonical.fetch("accepted")
    assert_equal "accepted", canonical.fetch("status")

    revising = Contract.review!(
      requirement: requirement, evidence: evidence,
      producer: producer, reviewer: reviewer,
      output: output.merge(
        "verdicts" => [
          {
            "target_id" => "claim-flow", "verdict" => "revise",
            "reason" => "The recording does not show the final confirmation state clearly enough."
          }
        ]
      )
    )
    refute revising.fetch("accepted")
    assert_equal "revise", revising.fetch("status")

    blocked = Contract.review!(
      requirement: requirement, evidence: evidence,
      producer: producer, reviewer: reviewer,
      output: output.merge(
        "verdicts" => [
          {
            "target_id" => "claim-flow", "verdict" => "blocked",
            "reason" => "The required environment cannot render the checkout state without operator access."
          }
        ]
      )
    )
    assert_equal "blocked", blocked.fetch("status")

    assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
      Contract.review!(
        requirement: requirement, evidence: evidence,
        producer: producer, reviewer: reviewer,
        output: output.merge(
          "verdicts" => [
            {
              "target_id" => "claim-flow", "verdict" => "rejected",
              "reason" => "This legacy verdict must not silently become a revision."
            }
          ]
        )
      )
    end

    assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
      Contract.review!(requirement: requirement, evidence: evidence, producer: producer,
                       reviewer: producer, output: output)
    end
    assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
      Contract.review!(requirement: requirement, evidence: evidence, producer: producer,
                       reviewer: reviewer, output: output.merge("inspected_hashes" => [ "a" * 64 ]))
    end
  end

  private

  def claim(id, statement, proof_kind, paths)
    { "id" => id, "statement" => statement, "proof_kind" => proof_kind, "changed_paths" => paths }
  end

  def exclusion(id, statement, paths)
    {
      "id" => id, "statement" => statement, "changed_paths" => paths,
      "reason" => "These paths only support the named outcomes and require no separate proof."
    }
  end
end
