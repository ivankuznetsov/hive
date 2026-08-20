require "test_helper"
require "hive/patrol_fix/migration/reconciler"

class PatrolFixMigrationReconcilerTest < Minitest::Test
  def test_exact_existing_all_state_pr_and_synthetic_review_reconcile_done_without_mutation
    candidate = source_candidate
    group = semantic_group(candidate)
    observations = [
      observation("coding_task", "legacy-review", "review", "link_read_only"),
      observation(
        "pull_request", "github:acme/demo#42", "closed", "exact",
        "publication" => publication_payload
      )
    ]
    port = ->(_group) { observations }

    result = Hive::PatrolFix::Migration::Reconciler.new(
      observation_port: port
    ).reconcile(groups: [ group ], candidates: [ candidate ])

    decision = result.fetch("groups").first.fetch("canonical_decision")
    assert_equal "done_existing_pr", decision.fetch("route")
    assert_equal [], decision.fetch("planned_mutations")
    assert_equal "github:acme/demo#42", decision.fetch("canonical_identity")
    assert_equal 1, result.fetch("dispositions").length
    assert_equal 2, result.fetch("observation_dispositions").length
  end

  def test_live_claim_wins_over_create_and_wrong_head_pr_blocks_adoption
    candidate = source_candidate
    group = semantic_group(candidate)
    observations = [
      observation("claim", "claim-1", "running", "wait"),
      observation("pull_request", "github:acme/demo#42", "open", "wrong_head")
    ]

    result = Hive::PatrolFix::Migration::Reconciler.new(
      observation_port: ->(_group) { observations }
    ).reconcile(groups: [ group ], candidates: [ candidate ])

    assert_equal "wait_live_claim",
                 result.dig("groups", 0, "canonical_decision", "route")
    assert_equal [], result.dig("groups", 0, "canonical_decision", "planned_mutations")
  end

  def test_multiple_exact_owned_artifacts_block_instead_of_choosing_one
    candidate = source_candidate
    group = semantic_group(candidate)
    observations = [
      observation(
        "pull_request", "github:acme/demo#41", "open", "exact",
        "publication" => publication_payload(
          id: "github:acme/demo#41", number: 41, state: "open"
        )
      ),
      observation(
        "pull_request", "github:acme/demo#42", "closed", "exact",
        "publication" => publication_payload
      )
    ]

    result = Hive::PatrolFix::Migration::Reconciler.new(
      observation_port: ->(_group) { observations }
    ).reconcile(groups: [ group ], candidates: [ candidate ])

    decision = result.dig("groups", 0, "canonical_decision")
    assert_equal "blocked_remote_conflict", decision.fetch("route")
    assert_nil decision.fetch("canonical_identity")
    assert_equal [ "block_adoption" ],
                 result.fetch("observation_dispositions")
                       .map { |entry| entry.fetch("route") }.uniq
  end

  private

  def source_candidate
    {
      "source_kind" => "ordinary_finding", "source_id" => "finding-1",
      "source_schema" => "hive-patrol-finding/v1", "canonical_digest" => "a" * 64,
      "authority_state" => "accepted", "semantic_root" => "root-a",
      "observations" => [], "blocking_reason" => nil
    }
  end

  def semantic_group(candidate)
    {
      "group_id" => "group-#{'b' * 32}",
      "candidate_set_digest" => "c" * 64,
      "members" => [ "#{candidate.fetch('source_kind')}:#{candidate.fetch('source_id')}" ],
      "canonical_source" => "#{candidate.fetch('source_kind')}:#{candidate.fetch('source_id')}",
      "semantic_decision" => {
        "route" => "exact_root", "inventory_candidate_set_digest" => "d" * 64,
        "current_head" => nil, "receipt_digests" => []
      }
    }
  end

  def observation(kind, id, state, match, details = {})
    {
      "kind" => kind, "identity" => id, "state" => state,
      "match" => match, "canonical_digest" => Digest::SHA256.hexdigest(id),
      "details" => details
    }
  end

  def publication_payload(id: "github:acme/demo#42", number: 42,
                          state: "closed")
    {
      "id" => id,
      "publication_id" => "pub-#{Digest::SHA256.hexdigest(id)[0, 32]}",
      "number" => number,
      "url" => "https://github.com/acme/demo/pull/#{number}",
      "host" => "github.com", "repository" => "acme/demo",
      "base_branch" => "main", "creation_base_revision" => "a" * 40,
      "branch" => "hive/patrol-fix", "head_revision" => "b" * 40,
      "diff_digest" => "c" * 64, "title_digest" => "d" * 64,
      "body_digest" => "e" * 64, "marker_digest" => "f" * 64,
      "state" => state, "observed_at" => "2026-08-21T00:00:00Z"
    }
  end
end
