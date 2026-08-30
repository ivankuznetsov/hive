require "test_helper"
require "hive/proposals/query"
require_relative "../../support/proposal_query_fixture"

class ProposalQueryTest < Minitest::Test
  include HiveTestHelper
  include ProposalQueryFixture

  def setup
    setup_proposal_query_fixture
  end

  def test_list_defaults_to_terminal_and_filter_reuses_the_same_projection
    result = @query.list

    assert_equal [ @rejected ], result.proposals.map(&:proposal_id)
    assert_empty result.diagnostics
    assert_match(/\A[0-9a-f]{64}\z/, result.digest)

    filtered = @query.list(
      filters: { "status" => "rejected", "evaluator" => "benchmark-reviewer", "method" => "cost" },
      include_drafts: true
    )
    assert_equal [ @rejected ], filtered.proposals.map(&:proposal_id)
    assert_empty @query.list(filters: { "method" => "unknown" }, include_drafts: true).proposals
  end

  def test_filters_subject_revision_kind_and_lineage_and_can_include_drafts
    drafts = @query.list(
      filters: { "kind" => "workflow", "subject" => "coding", "revision" => "v1" },
      include_drafts: true
    )
    assert_equal [ @draft ], drafts.proposals.map(&:proposal_id)

    related = @query.list(filters: { "relation" => @draft }, include_drafts: true)
    assert_equal [ @rejected ], related.proposals.map(&:proposal_id)
    assert_raises(Hive::Proposals::InvalidRecord) do
      @query.list(filters: { "unknown" => "value" })
    end
  end

  def test_show_exposes_contradictory_history_and_fresh_head
    result = @query.show(@rejected)
    payload = result.to_h

    assert_equal %w[pass fail], payload.fetch("evaluations").map { |row| row.dig("result", "outcome") }
    assert_equal %w[evaluation evaluation decision], payload.fetch("history").map { |row| row.fetch("type") }
    assert_equal 3, payload.dig("lifecycle_head", "version")
    assert_equal "rejected", payload.fetch("status")
    assert_match(/\A[0-9a-f]{64}\z/, payload.fetch("result_digest"))
  end
end
