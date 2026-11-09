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

  def test_links_are_bounded_to_the_published_schema_limit
    links = Array.new(65) do |index|
      { "kind" => "reference", "reference" => "https://example.test/#{index}" }
    end

    assert_raises(Hive::Proposals::InvalidEvent) do
      Hive::Proposals.links!(links)
    end
  end

  def test_subject_references_reject_secret_shaped_identifiers
    assert_raises(Hive::Proposals::InvalidRecord) do
      Hive::Proposals.subject_ref!("skills/ghp_#{'a' * 36}")
    end
  end

  def test_unknown_field_diagnostics_are_redacted_bounded_and_control_safe
    secret = "ghp_#{'a' * 36}"
    fields = 40.times.to_h { |index| [ "#{secret}\nfield-#{index}", true ] }

    error = assert_raises(Hive::Proposals::InvalidRecord) do
      Hive::Proposals.closed_hash!(fields, required: [], label: "artifact")
    end

    assert error.message.valid_encoding?
    assert_operator error.message.bytesize, :<=, 2_100
    refute_includes error.message, secret
    refute_includes error.message, "\n"
  end

  def test_lineage_cycle_detection_preserves_multiple_edge_kinds
    cycles = Hive::Proposals.lineage_cycle_nodes(
      "proposal-a" => %w[proposal-b proposal-c],
      "proposal-b" => "proposal-a"
    )

    assert_equal %w[proposal-a proposal-b], cycles
  end

  def test_hive_state_transaction_paths_are_contained
    git_ops = Struct.new(:hive_state_path).new("/tmp/project/.hive-state")

    assert_equal "proposals/v1/record.json",
                 Hive::Proposals.hive_state_relative_path(
                   git_ops, "/tmp/project/.hive-state/proposals/v1/record.json"
                 )
    assert_raises(Hive::Proposals::Error) do
      Hive::Proposals.hive_state_relative_path(git_ops, "/tmp/project/outside.json")
    end
  end

  def test_committed_state_restore_removes_untracked_directories_and_skips_vanished_paths
    Dir.mktmpdir("hive-proposals-restore") do |root|
      nested = File.join(root, "proposals", "v1", "nested-repo")
      FileUtils.mkdir_p(nested)
      File.write(File.join(nested, "payload"), "untracked")
      git_ops = Struct.new(:hive_state_path) do
        def run_git!(*)
          "?? proposals/v1/nested-repo/\0?? proposals/v1/inbox/vanished.json\0?? ../outside.json\0"
        end
      end.new(root)

      assert_equal 1, Hive::Proposals.restore_committed_proposal_state!(git_ops)
      refute File.exist?(nested)
    end
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

    secret = "sk-#{'a' * 32}"
    redacted = Hive::Proposals.evaluation_result!(
      { "outcome" => "pass", "metrics" => { secret => 0.91 } }, label: "evaluation"
    )
    assert_equal({ "[REDACTED:openai_api_key]" => 0.91 }, redacted.fetch("metrics"))
    refute_includes Hive::Proposals.canonical(redacted), secret
    assert_raises(Hive::Proposals::InvalidEvent) do
      Hive::Proposals.evaluation_result!(
        {
          "outcome" => "pass",
          "metrics" => { secret => 0.91, "sk-#{'b' * 32}" => 0.92 }
        },
        label: "evaluation"
      )
    end

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

    admitted = Hive::Proposals.evidence!(
      [ persisted.merge("summary" => "must not escape") ],
      policy: {
        "visibility" => "restricted", "retention" => "task",
        "allowed_link_schemes" => [ "https" ]
      },
      admission: true
    ).first
    assert_equal "restricted", admitted.fetch("visibility")
    assert_equal "task", admitted.dig("retention", "policy")
    refute admitted.key?("summary")

    historical = Hive::Proposals.evidence!([ persisted.merge("summary" => "historical") ]).first
    assert_equal "project", historical.fetch("visibility")
    assert_equal "historical", historical.fetch("summary")
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
