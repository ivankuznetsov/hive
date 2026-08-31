require "test_helper"
require "hive/proposals"

class ProposalsTest < Minitest::Test
  def test_canonical_helpers_share_one_stable_representation
    value = { "z" => 1, "a" => [ true, nil ] }

    assert_equal "{\"a\":[true,null],\"z\":1}", Hive::Proposals.canonical(value)
    assert_equal Digest::SHA256.hexdigest(Hive::Proposals.canonical(value)),
                 Hive::Proposals.digest(value)
  end

  def test_domain_failures_use_typed_cli_exit_codes
    usage_errors = [
      Hive::Proposals::InvalidRecord,
      Hive::Proposals::InvalidEvent,
      Hive::Proposals::Conflict,
      Hive::Proposals::InconsistentHistory,
      Hive::Proposals::Unauthorized,
      Hive::Proposals::QuarantinedSource
    ]
    temporary_errors = [
      Hive::Proposals::QuotaExceeded,
      Hive::Proposals::StaleObservation,
      Hive::Proposals::SourceUnavailable
    ]

    usage_errors.each do |error_class|
      assert_equal Hive::ExitCodes::USAGE, error_class.new("failure").exit_code
    end
    temporary_errors.each do |error_class|
      assert_equal Hive::ExitCodes::TEMPFAIL, error_class.new("failure").exit_code
    end
  end

  def test_json_timestamp_policy_and_reference_failures_are_typed
    bad_key = Object.new
    bad_key.define_singleton_method(:to_s) { raise TypeError, "cannot stringify" }

    assert_raises(Hive::Proposals::InvalidRecord) do
      Hive::Proposals.deep_copy_freeze("number" => Float::NAN)
    end
    assert_raises(Hive::Proposals::InvalidRecord) { Hive::Proposals.stringify(bad_key => true) }
    assert_raises(Hive::Proposals::InvalidEvent) do
      Hive::Proposals.timestamp!("yesterday", label: "occurred_at", error: Hive::Proposals::InvalidEvent)
    end
    assert_raises(Hive::Proposals::InvalidRecord) do
      Hive::Proposals.policy!("visibility" => "public")
    end
    assert_raises(Hive::Proposals::InvalidRecord) do
      Hive::Proposals.policy!("allowed_link_schemes" => [ "not a scheme" ])
    end
    assert_raises(Hive::Proposals::InvalidEvent) do
      Hive::Proposals.safe_reference!(
        "https://[", label: "link", error: Hive::Proposals::InvalidEvent
      )
    end
  end

  def test_hive_state_transaction_paths_are_contained_and_reset_failures_are_fail_soft
    git_ops = Struct.new(:hive_state_path, :reset_calls) do
      def run_git!(*arguments)
        reset_calls << arguments
        raise Hive::GitError, "reset failed" if arguments.include?("fail.json")
      end
    end.new("/tmp/project/.hive-state", [])

    assert_equal "proposals/v1/record.json",
                 Hive::Proposals.hive_state_relative_path(
                   git_ops, "/tmp/project/.hive-state/proposals/v1/record.json"
                 )
    assert_raises(Hive::Proposals::Error) do
      Hive::Proposals.hive_state_relative_path(git_ops, "/tmp/project/outside.json")
    end
    assert_nil Hive::Proposals.unstage_hive_state_paths(git_ops, [])
    assert_nil Hive::Proposals.unstage_hive_state_paths(git_ops, [ "record.json" ])
    assert_nil Hive::Proposals.unstage_hive_state_paths(git_ops, [ "fail.json" ])
    assert_equal 2, git_ops.reset_calls.length
  end

  def test_provenance_and_evaluation_facts_reject_untyped_values
    invalid_provenance = provenance.merge("task_generation" => [])
    assert_raises(Hive::Proposals::InvalidEvent) do
      Hive::Proposals.provenance!(invalid_provenance, error: Hive::Proposals::InvalidEvent)
    end

    invalid_method = evaluation_facts.merge("method" => { "kind" => "oracle", "label" => "review" })
    assert_raises(Hive::Proposals::InvalidEvent) { Hive::Proposals.evaluation_facts!(invalid_method) }

    invalid_metrics = evaluation_facts.merge(
      "result" => { "outcome" => "pass", "metrics" => { "score" => "high" } }
    )
    assert_raises(Hive::Proposals::InvalidEvent) { Hive::Proposals.evaluation_facts!(invalid_metrics) }

    normalized = Hive::Proposals.evaluation_result!(
      { "outcome" => "pass", "metrics" => {}, "details_digest" => "d" * 64 },
      label: "evaluation"
    )
    assert_equal "d" * 64, normalized.fetch("details_digest")
  end

  def test_persisted_and_new_evidence_enforce_classification_and_size
    persisted = {
      "label" => "result", "digest" => "a" * 64, "bytes" => 4,
      "media_type" => "text/plain", "visibility" => "project",
      "retention" => { "policy" => "task", "enforcement" => "none" }
    }

    assert_raises(Hive::Proposals::InvalidRecord) do
      Hive::Proposals.evidence!([ persisted.merge("visibility" => "public") ])
    end
    assert_raises(Hive::Proposals::InvalidRecord) do
      Hive::Proposals.evidence!([ persisted.merge("bytes" => -1) ])
    end
    assert_raises(Hive::Proposals::InvalidRecord) do
      Hive::Proposals.evidence!([ persisted.merge("visibility" => "private", "summary" => "secret") ])
    end
    assert_raises(Hive::Proposals::InvalidRecord) do
      Hive::Proposals.evidence!([
        { "label" => "result", "digest" => "a" * 64, "bytes" => -1,
          "media_type" => "text/plain" }
      ])
    end
  end

  private

  def provenance
    {
      "task_id" => "43059", "task_generation" => 1,
      "ownership_generation" => "owner-1", "attempt_id" => "attempt-1",
      "workflow_id" => "coding", "stage" => "4-execute",
      "actor" => { "id" => "alice", "kind" => "configured_identity" },
      "source_commit" => "a" * 40
    }
  end

  def evaluation_facts
    {
      "method" => { "kind" => "benchmark", "label" => "review" },
      "result" => { "outcome" => "pass", "metrics" => {} },
      "rationale" => "Measured", "evidence" => [], "links" => []
    }
  end
end
