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

  def test_rejects_fragmented_requirements_with_more_than_five_outcome_claims
    paths = (1..6).map { |number| "app/outcome_#{number}.rb" }
    claims = paths.each_with_index.map do |path, index|
      claim(
        "claim-outcome-#{index + 1}",
        "The user can observe outcome number #{index + 1} clearly.",
        "document", [ path ]
      )
    end

    error = assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
      Contract.requirement!(
        implementation: { "changed_paths" => paths }, claims: claims,
        exclusions: [], inference: { "context_id" => "inference-1", "agent" => "claude" }
      )
    end

    assert_match(/at most 5 claims/, error.message)
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

  def test_acceptance_requires_distinct_contexts_complete_claim_proof_and_review_scope_hashes
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
      "review_scope_hashes" => [ "a" * 64, "b" * 64 ],
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

    rework = Contract.review!(
      requirement: requirement, evidence: evidence,
      producer: producer, reviewer: reviewer,
      output: output.merge(
        "verdicts" => [
          {
            "target_id" => "claim-flow", "verdict" => "rework",
            "reason" => "The implementation obscures the confirmation state and needs a source change."
          }
        ]
      )
    )
    refute rework.fetch("accepted")
    assert_equal "rework", rework.fetch("status")

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
                       reviewer: reviewer, output: output.merge("review_scope_hashes" => [ "a" * 64 ]))
    end
  end

  def test_missing_claim_proof_can_be_durably_revised_but_never_accepted
    paths = %w[app/checkout.rb app/receipt.rb]
    requirement = Contract.requirement!(
      implementation: { "changed_paths" => paths },
      claims: [
        claim("claim-flow", "A buyer can finish checkout and see confirmation.", "document", [ paths.first ]),
        claim("claim-receipt", "The completed purchase retains its visible receipt details.", "document", [ paths.last ])
      ],
      exclusions: [],
      inference: { "context_id" => "inference-1", "agent" => "claude" }
    )
    evidence = [
      {
        "kind" => "document", "claims" => [ "claim-flow" ],
        "representations" => [ { "sha256" => "a" * 64 }, { "sha256" => "b" * 64 } ]
      }
    ]
    actors = {
      producer: { "context_id" => "producer-1", "agent" => "claude" },
      reviewer: { "context_id" => "reviewer-1", "agent" => "claude" }
    }
    output = {
      "review_scope_hashes" => [ "a" * 64, "b" * 64 ],
      "verdicts" => [
        {
          "target_id" => "claim-flow", "verdict" => "accepted",
          "reason" => "The retained document directly demonstrates the completed checkout state."
        },
        {
          "target_id" => "claim-receipt", "verdict" => "revise",
          "reason" => "No admitted representation demonstrates the completed receipt details yet."
        }
      ]
    }

    review = Contract.review!(
      requirement: requirement, evidence: evidence, **actors, output: output
    )
    assert_equal "revise", review.fetch("status")

    output.fetch("verdicts").last["verdict"] = "accepted"
    error = assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
      Contract.review!(
        requirement: requirement, evidence: evidence, **actors, output: output
      )
    end
    assert_match(/cannot accept a claim without admitted proof/, error.message)
  end

  def test_rejects_secret_shaped_semantic_claims_exclusions_and_verdicts
    secret = "api_key=abcdefghijklmnopqrstuvwxyz0123456789"
    input = {
      implementation: { "changed_paths" => %w[app/checkout.rb] },
      claims: [
        claim(
          "claim-flow", "A buyer sees #{secret} after completing checkout.",
          "document", %w[app/checkout.rb]
        )
      ],
      exclusions: [],
      inference: { "context_id" => "inference-1", "agent" => "claude" }
    }
    error = assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
      Contract.requirement!(**input)
    end
    assert_match(/secret-shaped/, error.message)
    refute_includes error.message, "abcdefghijklmnopqrstuvwxyz"

    requirement = Contract.requirement!(
      **input.merge(
        claims: [
          claim(
            "claim-flow", "A buyer sees confirmation after completing checkout.",
            "document", %w[app/checkout.rb]
          )
        ]
      )
    )
    evidence = [
      {
        "kind" => "document", "claims" => [ "claim-flow" ],
        "representations" => [ { "sha256" => "a" * 64 }, { "sha256" => "b" * 64 } ]
      }
    ]
    error = assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
      Contract.review!(
        requirement: requirement, evidence: evidence,
        producer: { "context_id" => "producer-1", "agent" => "claude" },
        reviewer: { "context_id" => "reviewer-1", "agent" => "claude" },
        output: {
          "review_scope_hashes" => [ "a" * 64, "b" * 64 ],
          "verdicts" => [
            {
              "target_id" => "claim-flow", "verdict" => "accepted",
              "reason" => "The proof exposes #{secret} in its completed state."
            }
          ]
        }
      )
    end
    assert_match(/secret-shaped/, error.message)
    refute_includes error.message, "abcdefghijklmnopqrstuvwxyz"
  end

  def test_rejects_malformed_requirements_actor_identities_and_review_outputs
    paths = %w[app/checkout.rb]
    valid_claim = claim(
      "claim-flow", "A buyer can finish checkout and see confirmation.",
      "video", paths
    )
    inference = { "context_id" => "inference-1", "agent" => "claude" }

    assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
      Contract.requirement!(
        implementation: {}, claims: [ valid_claim ], exclusions: [], inference: inference
      )
    end
    assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
      Contract.requirement!(
        implementation: { "changed_paths" => paths },
        claims: [ valid_claim.except("statement") ], exclusions: [], inference: inference
      )
    end
    assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
      Contract.requirement!(
        implementation: { "changed_paths" => paths },
        claims: [ valid_claim.merge("changed_paths" => paths * 2) ],
        exclusions: [], inference: inference
      )
    end
    assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
      Contract.requirement!(
        implementation: { "changed_paths" => paths }, claims: [ valid_claim ],
        exclusions: [], inference: { "context_id" => "inference-1" }
      )
    end
    assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
      Contract.requirement!(
        implementation: { "changed_paths" => paths }, claims: [ valid_claim ],
        exclusions: [], inference: inference.merge("model" => "\n")
      )
    end

    requirement = Contract.requirement!(
      implementation: { "changed_paths" => paths }, claims: [ valid_claim ],
      exclusions: [], inference: inference
    )
    producer = { "context_id" => "producer-1", "agent" => "claude" }
    reviewer = { "context_id" => "reviewer-1", "agent" => "claude" }
    evidence = [
      {
        "kind" => "video", "claims" => [ "claim-flow" ],
        "representations" => [ { "sha256" => "a" * 64 }, { "sha256" => "b" * 64 } ]
      }
    ]
    output = {
      "review_scope_hashes" => [ "a" * 64, "b" * 64 ],
      "verdicts" => [
        {
          "target_id" => "claim-flow", "verdict" => "accepted",
          "reason" => "The temporal proof shows checkout reaching confirmation successfully."
        }
      ]
    }

    assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
      Contract.review!(
        requirement: requirement,
        evidence: [ evidence.first.merge("kind" => "screenshot") ],
        producer: producer, reviewer: reviewer, output: output
      )
    end
    assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
      Contract.review!(
        requirement: requirement, evidence: evidence,
        producer: producer, reviewer: reviewer, output: output.merge("verdicts" => [])
      )
    end
    assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
      Contract.review!(
        requirement: requirement, evidence: evidence,
        producer: producer, reviewer: reviewer, output: output.except("review_scope_hashes")
      )
    end
    assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
      Contract.review!(
        requirement: requirement, evidence: evidence,
        producer: producer, reviewer: reviewer,
        output: output.merge("verdicts" => [ output.fetch("verdicts").first.except("reason") ])
      )
    end
  end

  def test_verdicts_validate_without_persisting_so_a_reviewer_can_be_repaired
    contract = Hive::Artifacts::OutcomeEvidence::Contract
    bounded = {
      "verdicts" => [
        {
          "target_id" => "claim-flow", "verdict" => "accepted",
          "reason" => "The retained document proves the requested flow."
        }
      ]
    }

    verdicts = contract.verdicts!(bounded)
    assert_equal 1, verdicts.length
    assert_equal "claim-flow", verdicts.first.fetch("target_id")

    # 1500 bytes, past the 1024-byte statement cap.
    overlong = {
      "verdicts" => [
        {
          "target_id" => "claim-flow", "verdict" => "accepted",
          "reason" => "word " * 300
        }
      ]
    }

    error = assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
      contract.verdicts!(overlong)
    end
    assert_match(/review verdict reason must be a meaningful bounded explanation/, error.message)

    missing = assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
      contract.verdicts!({})
    end
    assert_equal "review output is missing verdicts", missing.message
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
