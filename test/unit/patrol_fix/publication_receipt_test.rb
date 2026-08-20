require "test_helper"
require "hive/patrol_fix/publication_receipt"

class PatrolFixPublicationReceiptTest < Minitest::Test
  def test_builds_a_strict_exact_publication_receipt
    receipt = Hive::PatrolFix::PublicationReceipt.build(
      task: { "slug" => "repair-one", "generation" => 1 },
      evidence_revision: { "generation" => 1, "digest" => "a" * 64 },
      publication: publication
    )

    assert_equal "publication", receipt.fetch("kind")
    assert_equal "publish", receipt.fetch("stage")
    assert_equal "github:acme/demo#42", receipt.dig("payload", "id")
    assert_equal "base", receipt.dig("payload", "base_branch")
    assert_equal "merged", receipt.dig("payload", "state")
  end

  def test_rejects_wrong_repository_url_or_missing_exact_identity
    wrong_url = publication.merge("url" => "https://github.com/other/demo/pull/42")
    error = assert_raises(Hive::PatrolFix::PublicationReceipt::InvalidPublication) do
      Hive::PatrolFix::PublicationReceipt.build(
        task: { "slug" => "repair-one", "generation" => 1 },
        evidence_revision: { "generation" => 1, "digest" => "a" * 64 },
        publication: wrong_url
      )
    end
    assert_includes error.message, "URL"

    assert_raises(Hive::PatrolFix::PublicationReceipt::InvalidPublication) do
      Hive::PatrolFix::PublicationReceipt.validate_payload!(publication.reject { |key, _| key == "body_digest" })
    end
  end

  def test_adopts_an_already_canonical_payload_without_a_transport
    task = { "slug" => "repair-one", "generation" => 1 }
    evidence = { "generation" => 1, "digest" => "a" * 64 }
    built = Hive::PatrolFix::PublicationReceipt.build(
      task: task, evidence_revision: evidence, publication: publication
    )

    adopted = Hive::PatrolFix::PublicationReceipt.adopt(
      task: task, evidence_revision: evidence, payload: built.fetch("payload")
    )

    assert_equal built, adopted
  end

  private

  def publication
    {
      "publication_id" => "pub-#{'1' * 32}",
      "number" => 42,
      "url" => "https://github.com/acme/demo/pull/42",
      "host" => "github.com", "repository" => "acme/demo",
      "base_branch" => "base", "creation_base_oid" => "1" * 40,
      "branch" => "hive/patrol-fix/repair-one/g1", "head_oid" => "2" * 40,
      "diff_digest" => "3" * 64, "title_digest" => "4" * 64,
      "body_digest" => "5" * 64, "marker_digest" => "6" * 64,
      "hosted_state" => "merged", "observed_at" => "2026-08-20T12:00:00Z"
    }
  end
end
