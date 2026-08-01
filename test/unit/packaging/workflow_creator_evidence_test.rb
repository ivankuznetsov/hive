require "test_helper"
require "json"
require_relative "../../../packaging/live_agent_skills/proof"
require_relative "../../../packaging/release_candidate/artifacts"

class WorkflowCreatorEvidenceTest < Minitest::Test
  include HiveTestHelper

  SHA = "a" * 40

  def test_initializer_persists_one_private_schema_valid_nonpassing_receipt
    with_tmp_dir do |dir|
      path = File.join(dir, "bundle", "openclaw-workflow-creator.json")
      store = HiveLiveAgentProof::WorkflowCreatorEvidence.new(path: path)

      stored = store.initialize!(candidate_sha: SHA)

      assert_equal stored, JSON.parse(File.read(path))
      assert_equal(
        [ "failed", "preflight", "not_started", "unavailable", "not_started" ],
        stored.values_at(
          "result", "phase", "reason", "execution_kind", "model_loop"
        )
      )
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_empty Dir.glob(File.join(File.dirname(path), ".*.tmp"))
      HiveLiveAgentProof::WorkflowCreatorContract.validate_nonpassing!(stored)
    end
  end

  def test_interruption_before_rename_preserves_previous_receipt
    with_tmp_dir do |dir|
      path = File.join(dir, "openclaw-workflow-creator.json")
      store = HiveLiveAgentProof::WorkflowCreatorEvidence.new(path: path)
      store.initialize!(candidate_sha: SHA)
      previous = File.binread(path)
      replacement = failed_document("proof_failed")
      interrupted = HiveLiveAgentProof::WorkflowCreatorEvidence.new(
        path: path,
        before_rename: ->(*) { raise IOError, "interrupted" }
      )

      assert_raises(IOError) do
        interrupted.replace_nonpassing!(replacement)
      end

      assert_equal previous, File.binread(path)
      assert_empty Dir.glob(File.join(dir, ".*.tmp"))
    end
  end

  def test_interruption_during_temporary_write_preserves_previous_receipt
    with_tmp_dir do |dir|
      path = File.join(dir, "openclaw-workflow-creator.json")
      HiveLiveAgentProof::WorkflowCreatorEvidence.new(path: path)
                                                   .initialize!(candidate_sha: SHA)
      previous = File.binread(path)
      interrupted = HiveLiveAgentProof::WorkflowCreatorEvidence.new(
        path: path,
        writer: lambda do |file, bytes|
          file.write(bytes.byteslice(0, bytes.bytesize / 2))
          raise IOError, "interrupted during write"
        end
      )

      assert_raises(IOError) do
        interrupted.replace_nonpassing!(failed_document("proof_failed"))
      end

      assert_equal previous, File.binread(path)
      assert_empty Dir.glob(File.join(dir, ".*.tmp"))
    end
  end

  def test_rename_failure_preserves_previous_receipt_and_cleans_temporary
    with_tmp_dir do |dir|
      path = File.join(dir, "openclaw-workflow-creator.json")
      store = HiveLiveAgentProof::WorkflowCreatorEvidence.new(path: path)
      store.initialize!(candidate_sha: SHA)
      previous = File.binread(path)
      failed = HiveLiveAgentProof::WorkflowCreatorEvidence.new(
        path: path,
        renamer: ->(*) { raise Errno::EACCES, "locked" }
      )

      assert_raises(Errno::EACCES) do
        failed.replace_nonpassing!(failed_document("proof_failed"))
      end

      assert_equal previous, File.binread(path)
      assert_empty Dir.glob(File.join(dir, ".*.tmp"))
    end
  end

  def test_successful_replace_fsyncs_parent_after_atomic_rename
    with_tmp_dir do |dir|
      path = File.join(dir, "openclaw-workflow-creator.json")
      HiveLiveAgentProof::WorkflowCreatorEvidence.new(path: path)
                                                   .initialize!(candidate_sha: SHA)
      events = []
      store = HiveLiveAgentProof::WorkflowCreatorEvidence.new(
        path: path,
        renamer: lambda do |source, destination|
          events << :rename
          File.rename(source, destination)
        end,
        directory_sync: lambda do |parent|
          events << [ :directory_fsync, parent ]
          0
        end
      )

      store.replace_nonpassing!(failed_document("proof_failed"))

      assert_equal(
        [ :rename, [ :directory_fsync, dir ] ],
        events
      )
    end
  end

  def test_directory_fsync_failure_leaves_a_complete_retryable_receipt
    with_tmp_dir do |dir|
      path = File.join(dir, "openclaw-workflow-creator.json")
      HiveLiveAgentProof::WorkflowCreatorEvidence.new(path: path)
                                                   .initialize!(candidate_sha: SHA)
      replacement = failed_document("proof_failed")
      store = HiveLiveAgentProof::WorkflowCreatorEvidence.new(
        path: path,
        directory_sync: ->(*) { raise IOError, "directory fsync failed" }
      )

      assert_raises(IOError) do
        store.replace_nonpassing!(replacement)
      end

      assert_equal replacement, JSON.parse(File.read(path))
      assert_empty Dir.glob(File.join(dir, ".*.tmp"))
      recovered = failed_document("retry_completed")
      HiveLiveAgentProof::WorkflowCreatorEvidence.new(path: path)
                                                   .replace_nonpassing!(recovered)
      assert_equal recovered, JSON.parse(File.read(path))
    end
  end

  def test_initializer_cannot_clobber_a_receipt_won_by_a_concurrent_writer
    with_tmp_dir do |dir|
      path = File.join(dir, "openclaw-workflow-creator.json")
      winner = "concurrent receipt\n"
      store = HiveLiveAgentProof::WorkflowCreatorEvidence.new(
        path: path,
        linker: lambda do |source, destination|
          File.open(
            destination,
            File::WRONLY | File::CREAT | File::EXCL,
            0o600
          ) { |file| file.write(winner) }
          File.link(source, destination)
        end
      )

      error = assert_raises(HiveLiveAgentProof::Error) do
        store.initialize!(candidate_sha: SHA)
      end

      assert_equal "workflow-creator evidence already exists", error.message
      assert_equal winner, File.binread(path)
      assert_empty Dir.glob(File.join(dir, ".*.tmp"))
    end
  end

  def test_failure_document_recursively_sanitizes_secrets_and_bounds_detail
    secret = "sk-proj-abcdefghijklmnopqrstuvwxyz"
    document = HiveLiveAgentProof::WorkflowCreatorContract.failure(
      candidate_sha: SHA,
      phase: "proof",
      reason: "proof_failed",
      detail: { "nested" => [ secret, "x" * 2_000 ] }.to_json,
      exact_secrets: [ secret ]
    )
    serialized = JSON.generate(document)

    refute_includes serialized, secret
    assert_includes serialized, "[REDACTED]"
    assert_operator document.fetch("detail").bytesize, :<=, 1_000
  end

  def test_failure_document_redacts_exact_secret_before_detail_is_bounded
    secret = "opaque-provider-credential"
    document = HiveLiveAgentProof::WorkflowCreatorContract.failure(
      candidate_sha: SHA,
      phase: "proof",
      reason: "proof_failed",
      detail: ("x" * 995) + secret,
      exact_secrets: [ secret ]
    )

    refute_includes document.fetch("detail"), secret
    refute_includes document.fetch("detail"), secret.byteslice(0, 5)
    assert_operator document.fetch("detail").bytesize, :<=, 1_000
  end

  def test_terminal_failure_preserves_model_loop_progress_without_passing
    preflight = HiveLiveAgentProof::WorkflowCreatorContract.terminal_failure(
      candidate_sha: SHA,
      proof_succeeded: false,
      model_loop_executed: false
    )
    post_start = HiveLiveAgentProof::WorkflowCreatorContract.terminal_failure(
      candidate_sha: SHA,
      proof_succeeded: false,
      model_loop_executed: true
    )
    custody_gap = HiveLiveAgentProof::WorkflowCreatorContract.terminal_failure(
      candidate_sha: SHA,
      proof_succeeded: true,
      model_loop_executed: true
    )

    assert_equal(
      [ "failed", "preflight", "proof_failed", "unavailable", "not_started" ],
      preflight.values_at(
        "result", "phase", "reason", "execution_kind", "model_loop"
      )
    )
    assert_equal(
      [ "failed", "proof", "proof_failed", "authenticated_openclaw", "executed" ],
      post_start.values_at(
        "result", "phase", "reason", "execution_kind", "model_loop"
      )
    )
    assert_equal(
      [
        "failed", "evidence", "u14_execution_custody_unavailable",
        "authenticated_openclaw", "executed"
      ],
      custody_gap.values_at(
        "result", "phase", "reason", "execution_kind", "model_loop"
      )
    )
  end

  def test_terminal_failure_rejects_non_boolean_or_impossible_progress
    invalid = [
      [ "yes", false ],
      [ false, nil ],
      [ true, false ]
    ]

    invalid.each do |proof_succeeded, model_loop_executed|
      error = assert_raises(HiveLiveAgentProof::Error) do
        HiveLiveAgentProof::WorkflowCreatorContract.terminal_failure(
          candidate_sha: SHA,
          proof_succeeded: proof_succeeded,
          model_loop_executed: model_loop_executed
        )
      end
      assert_equal "workflow-creator terminal state is invalid", error.message
    end
  end

  def test_failure_normalizes_an_unresolved_candidate_identity
    document = HiveLiveAgentProof::WorkflowCreatorContract.failure(
      candidate_sha: "not-a-sha",
      phase: "preflight",
      reason: "not_started"
    )

    assert_equal "unresolved", document.fetch("candidate_sha")
    HiveLiveAgentProof::WorkflowCreatorContract.validate_nonpassing!(document)
  end

  def test_nonpassing_contract_rejects_contradictory_classification
    document = failed_document("proof_failed")
    document["execution_kind"] = "deterministic_fixture"
    document["model_loop"] = "executed"

    error = assert_raises(HiveLiveAgentProof::Error) do
      HiveLiveAgentProof::WorkflowCreatorContract.validate_nonpassing!(document)
    end
    assert_includes error.message, "non-passing evidence is invalid"
  end

  def test_generic_proof_facade_contains_no_creator_constants_or_validators
    proof = File.read(
      File.expand_path(
        "../../../packaging/live_agent_skills/proof.rb",
        __dir__
      )
    )

    refute_match(/^\s*WORKFLOW_CREATOR_[A-Z_]+\s*=/, proof)
    refute_match(/def validate_creator_/, proof)
    refute_match(/def validate_workflow_creator!.*\n(?:.*\n){1,40}.*row\[/, proof)
    assert_equal(
      %w[
        packaging/live_agent_skills/proof.rb
        packaging/live_agent_skills/build.rb
        packaging/live_agent_skills/workflow_creator_contract.rb
        packaging/live_agent_skills/workflow_creator_evidence.rb
      ],
      HiveReleaseCandidate::Artifacts::LIVE_AGENT_BUILDER_INPUTS
    )
  end

  def test_completion_log_keeps_the_gaps_backlink
    fragment = File.read(
      File.expand_path(
        "../../../wiki/log.d/20260730T164500Z-workflow-creator-contract-core.md",
        __dir__
      )
    )

    assert_includes fragment, "[[gaps]]"
  end

  private

  def failed_document(reason)
    HiveLiveAgentProof::WorkflowCreatorContract.failure(
      candidate_sha: SHA,
      phase: "proof",
      reason: reason,
      detail: "failed safely"
    )
  end
end
