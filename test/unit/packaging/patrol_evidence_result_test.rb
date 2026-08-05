require "test_helper"
require "json"
require "json_schemer"
require_relative "../../../packaging/patrol_evidence/result"

class PatrolEvidenceResultTest < Minitest::Test
  Result = HivePatrolEvidence::Result

  def test_not_started_and_terminal_results_are_canonical_fenced_and_schema_valid
    started = Result.not_started(authority: authority, started_at: "2026-08-05T10:00:00.000000Z")
    terminal = Result.terminal(
      status: "installed_live_smoke_verified", reason: nil, authority: authority,
      candidate: verified_candidate,
      sandbox: sandbox,
      smoke: smoke,
      provider: {
        "status" => "passed", "provider" => "openrouter",
        "model" => "openai/gpt-5.6-terra", "response_sha256" => digest("response"),
        "usage" => { "prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2 }
      },
      process_evidence: [ process_evidence ],
      started_at: "2026-08-05T10:00:00.000000Z",
      finished_at: "2026-08-05T10:00:01.000000Z"
    )
    failed = Result.terminal(
      status: "failed", reason: "sandbox_contract", authority: authority,
      candidate: prepared_candidate, sandbox: nil, smoke: nil, provider: nil,
      process_evidence: [], started_at: "2026-08-05T10:00:00.000000Z",
      finished_at: "2026-08-05T10:00:01.000000Z"
    )

    assert_equal "not_started", started.to_h.fetch("status")
    assert_equal Result::CLAIM_FENCES, terminal.to_h.fetch("claim_fences")
    assert_equal Result.canonical(terminal.to_h), terminal.canonical_bytes
    assert terminal.frozen?
    assert terminal.to_h.frozen?
    assert terminal.to_h.fetch("claim_fences").frozen?
    assert_operator terminal.canonical_bytes.bytesize, :<=, Result::MAX_RESULT_BYTES

    schema = JSONSchemer.schema(JSON.parse(File.binread(
      File.expand_path("../../../schemas/hive-patrol-installed-live-smoke.v1.json", __dir__)
    )))
    assert_empty schema.validate(JSON.parse(started.canonical_bytes)).to_a
    assert_empty schema.validate(JSON.parse(terminal.canonical_bytes)).to_a
    assert_empty schema.validate(JSON.parse(failed.canonical_bytes)).to_a

    impossible = JSON.parse(terminal.canonical_bytes).merge(
      "candidate" => {}, "sandbox" => {}, "smoke" => {}, "provider" => {},
      "process_evidence" => []
    )
    refute_empty schema.validate(impossible).to_a
    blocked = JSON.parse(terminal.canonical_bytes).merge(
      "status" => "blocked", "reason" => nil, "finished_at" => nil
    )
    refute_empty schema.validate(blocked).to_a
  end

  def test_result_vocabulary_and_claim_fences_are_closed
    assert_raises(Result::Error) do
      Result.terminal(
        status: "installed_live", reason: nil, authority: authority,
        candidate: {}, sandbox: {}, smoke: {}, provider: {}, process_evidence: [],
        started_at: "2026-08-05T10:00:00Z", finished_at: "2026-08-05T10:00:01Z"
      )
    end


    assert_raises(Result::Error) do
      Result.terminal(
        status: "installed_live_smoke_verified", reason: nil, authority: authority,
        candidate: {}, sandbox: {}, smoke: {}, provider: {}, process_evidence: [],
        started_at: "2026-08-05T10:00:00Z", finished_at: "2026-08-05T10:00:01Z"
      )
    end

    assert_raises(Result::Error) do
      Result.terminal(
        status: "failed", reason: "invented_failure", authority: authority,
        candidate: nil, sandbox: nil, smoke: nil, provider: nil, process_evidence: [],
        started_at: "2026-08-05T10:00:00Z", finished_at: "2026-08-05T10:00:01Z"
      )
    end

    assert_equal %w[
      not_full_u3b prepared_records_not_fresh_scheduler_matrix
      controller_does_not_supply_full_independent_matrix
      not_report_installed_live_qualification provider_probe_not_patrol_decision
      not_evidence_ready_for_operator not_cutover_or_promotion_authority
    ], Result::CLAIM_FENCES
  end

  def test_result_rejects_exact_and_generic_secrets_without_retaining_them
    exact = "operator-secret-that-must-never-be-retained"
    error = assert_raises(Result::Error) do
      Result.terminal(
        status: "failed", reason: "provider_transport", authority: authority,
        candidate: nil, sandbox: sandbox.merge("engine_version" => exact), smoke: nil, provider: nil,
        process_evidence: [], exact_secrets: [ exact ],
        started_at: "2026-08-05T10:00:00Z", finished_at: "2026-08-05T10:00:01Z"
      )
    end
    refute_includes error.message, exact

    assert_raises(Result::Error) do
      Result.terminal(
        status: "failed", reason: "credential_custody", authority: authority,
        candidate: nil,
        sandbox: sandbox.merge("engine_version" => "api_key=abcdefghijklmnopqrstuvwxyz123456"),
        smoke: nil, provider: nil, process_evidence: [],
        started_at: "2026-08-05T10:00:00Z", finished_at: "2026-08-05T10:00:01Z"
      )
    end
  end

  private

  def authority
    {
      "run_id" => "u3c-20260805T100000Z-0123456789ab",
      "controller_sha" => "a" * 40,
      "candidate_sha" => "b" * 40,
      "runner_sha256" => digest("runner"),
      "controller_script_sha256" => digest("controller script"),
      "control_tree_sha256" => digest("control tree"),
      "authorization_sha256" => digest("authorization"),
      "authorization_nonce_sha256" => digest("nonce"),
      "authorization_expires_at" => "2026-08-05T10:15:00.000000Z",
      "invocation_id" => "manual-20260805-1",
      "image" => "ruby@sha256:#{digest('image')}",
      "observations_sha256" => digest("observations"),
      "project_binding_sha256" => digest("project binding")
    }
  end

  def verified_candidate
    {
      "status" => "verified", "candidate_sha" => "b" * 40,
      "archive_sha256" => digest("archive"), "archive_member_count" => 10,
      "archive_total_bytes" => 100, "module_manifest_sha256" => digest("manifests"),
      "source_tree_sha256" => digest("source"), "gem_sha256" => digest("gem"),
      "installed_hive_sha256" => digest("hive"),
      "dependency_closure_sha256" => digest("closure"), "toolchain_sha256" => digest("toolchain")
    }
  end

  def prepared_candidate
    verified_candidate.slice(
      "candidate_sha", "archive_sha256", "archive_member_count", "archive_total_bytes",
      "module_manifest_sha256", "source_tree_sha256"
    ).merge("status" => "prepared")
  end

  def sandbox
    {
      "status" => "passed", "engine" => "docker", "engine_version" => "Docker 28.0",
      "engine_sha256" => digest("engine"), "image" => "ruby@sha256:#{digest('image')}",
      "image_id" => "sha256:#{digest('rootfs')}", "network" => "none",
      "root_filesystem" => "read_only", "writable_bytes" => 536_870_912,
      "writable_inodes" => 16_384, "process_limit" => 64, "memory" => "2g", "cpus" => "2"
    }
  end

  def smoke
    {
      "status" => "passed", "modules" => %w[architecture-patrol patrol], "receipt_count" => 4,
      "catalog_digest" => digest("catalog"), "scenario_manifest_digest" => digest("scenario"),
      "report_sha256" => digest("report")
    }
  end

  def process_evidence
    {
      "owner" => "sandbox", "status" => "reaped", "outcome" => "success",
      "teardown" => "verified", "exit_code" => 0,
      "container_id_sha256" => digest("container"), "stdout_sha256" => digest("stdout"),
      "stderr_sha256" => digest("stderr")
    }
  end

  def digest(value) = Digest::SHA256.hexdigest(value)
end
