require "test_helper"
require "hive/patrol_fix/migration/semantic_group"
require "json_schemer"

class PatrolFixMigrationSemanticGroupTest < Minitest::Test
  def test_one_exact_root_group_retains_every_member_and_one_canonical_source
    candidates = [
      candidate("ordinary_finding", "finding-1", "shared-root", "a"),
      candidate("architecture_finding", "job-2:thesis-1", "shared-root", "b")
    ]

    groups = Hive::PatrolFix::Migration::SemanticGroup.build(candidates)

    assert_equal 1, groups.length
    group = groups.first
    assert_equal %w[architecture_finding:job-2:thesis-1 ordinary_finding:finding-1],
                 group.fetch("members")
    assert_equal "architecture_finding:job-2:thesis-1",
                 group.fetch("canonical_source")
    assert_equal "exact_root", group.dig("semantic_decision", "route")
    assert_match(/\A[0-9a-f]{64}\z/, group.fetch("candidate_set_digest"))
  end

  def test_only_an_injected_same_root_decision_can_join_different_exact_roots
    candidates = [
      candidate("ordinary_finding", "finding-1", "root-a", "a"),
      candidate("architecture_finding", "job-2:thesis-1", "root-b", "b")
    ]
    links = [
      {
        "left" => "ordinary_finding:finding-1",
        "right" => "architecture_finding:job-2:thesis-1",
        "decision" => "same_root",
        "receipt_digest" => "c" * 64,
        "candidate_set_digest" => candidate_set_digest(candidates),
        "current_head" => "d" * 40
      }
    ]
    decision_schema = JSONSchemer.schema(JSON.parse(File.read(
      Hive::Schemas.schema_path("hive-patrol-fix-migration-semantic-decision")
    )))
    assert decision_schema.valid?(links.first)

    group = Hive::PatrolFix::Migration::SemanticGroup.build(
      candidates, semantic_decisions: links
    ).fetch(0)

    assert_equal 2, group.fetch("members").length
    assert_equal "injected_same_root", group.dig("semantic_decision", "route")
    assert_equal [ "c" * 64 ], group.dig("semantic_decision", "receipt_digests")
  end

  def test_different_roots_without_an_injected_decision_remain_explicitly_blocked
    candidates = [
      candidate("ordinary_finding", "finding-1", "root-a", "a"),
      candidate("architecture_finding", "job-2:thesis-1", "root-b", "b")
    ]

    groups = Hive::PatrolFix::Migration::SemanticGroup.build(candidates)

    assert_equal 2, groups.length
    assert_equal [ "semantic_decision_required" ],
                 groups.map { |group| group.dig("semantic_decision", "route") }.uniq
  end

  private

  def candidate(kind, id, root, digest_char)
    {
      "source_kind" => kind, "source_id" => id,
      "source_schema" => "example/v1", "canonical_digest" => digest_char * 64,
      "authority_state" => "accepted", "semantic_root" => root,
      "observations" => [], "blocking_reason" => nil
    }
  end

  def candidate_set_digest(candidates)
    pairs = candidates.map do |entry|
      [ "#{entry.fetch('source_kind')}:#{entry.fetch('source_id')}",
        entry.fetch("canonical_digest") ]
    end.sort
    Digest::SHA256.hexdigest(Hive::PatrolFix.canonical_json(pairs))
  end
end
