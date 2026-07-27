require "test_helper"
require "json_schemer"
require_relative "../../../packaging/release_candidate/aggregate"
require_relative "../../../packaging/release_candidate/hosted_aggregate"

class ReleaseCandidateAggregateTest < Minitest::Test
  SHA = "a" * 40
  WORKFLOW_SHA = "b" * 40
  ACTION_LOCK = "c" * 64
  ARTIFACT_DIGEST = "sha256:#{'d' * 64}"

  def test_exact_required_gate_set_is_qa_ready_while_advisory_unavailable_is_visible
    result = aggregate.call(
      jobs: required_jobs,
      ordinary_ci: ordinary_ci,
      advisory: [
        { "name" => "openclaw_live", "class" => "advisory", "status" => "unavailable" }
      ]
    )

    assert_equal "trusted_remote", result.fetch("trust_scope")
    assert_equal "passed", result.fetch("scope_status")
    assert_equal "qa_ready", result.fetch("qa_status")
    assert_empty result.fetch("blockers")
    assert_equal 1, result.fetch("advisory").size
    assert_equal "explicit_release_decision_required", result.dig("next_action", "kind")
  end

  def test_missing_duplicate_skipped_cancelled_or_mixed_attempt_required_job_blocks
    cases = {
      "missing" => ->(rows) { rows.pop },
      "duplicate" => ->(rows) { rows << rows.first.dup },
      "skipped" => ->(rows) { rows.first["conclusion"] = "skipped" },
      "cancelled" => ->(rows) { rows.first["conclusion"] = "cancelled" },
      "mixed attempt" => ->(rows) { rows.first["run_attempt"] = 3 }
    }

    cases.each do |label, mutate|
      rows = required_jobs
      mutate.call(rows)
      result = aggregate.call(jobs: rows, ordinary_ci: ordinary_ci)

      assert_equal "qa_blocked", result.fetch("qa_status"), label
      refute_empty result.fetch("blockers"), label
    end
  end

  def test_wrong_ordinary_ci_or_artifact_identity_blocks
    wrong_ci = ordinary_ci.merge("head_sha" => "e" * 40)
    result = aggregate.call(jobs: required_jobs, ordinary_ci: wrong_ci)
    assert_includes result.fetch("blockers"), "ordinary_ci_identity_invalid"

    rows = required_jobs
    rows.first["artifact_digest"] = "sha256:#{'e' * 64}"
    result = aggregate.call(jobs: rows, ordinary_ci: ordinary_ci)
    assert_includes result.fetch("blockers"), "required_job_identity_invalid"

    rows = required_jobs
    rows.first.delete("candidate_sha")
    result = aggregate.call(jobs: rows, ordinary_ci: ordinary_ci)
    assert_includes result.fetch("blockers"), "required_job_identity_invalid"
  end

  def test_retry_requires_source_identity_and_forms_one_effective_gate_set
    source = {
      "trust_scope" => "trusted_remote", "repository" => "ivankuznetsov/hive",
      "request_id" => "req-source1", "evidence_sha256" => "e" * 64,
      "run_id" => 41, "run_attempt" => 1,
      "candidate_sha" => SHA, "workflow_sha" => WORKFLOW_SHA,
      "action_lock_sha256" => ACTION_LOCK,
      "artifact" => {
        "id" => 77, "digest" => ARTIFACT_DIGEST,
        "name" => "hive-release-candidate-42-2",
        "producer_run_id" => 42, "producer_run_attempt" => 2
      },
      "effective_gate_set" => required_jobs.map do |row|
        row.merge("run_id" => 41, "run_attempt" => 1)
      end
    }
    retried = required_jobs.select do |row|
      row["name"] == HiveReleaseCandidate::Aggregate::REQUIRED_JOBS.first
    end

    result = aggregate.call(
      jobs: retried, ordinary_ci: ordinary_ci, source_attempt: source,
      selector: { "mode" => "named", "gates" => [ retried.first.fetch("name") ] }
    )

    assert_equal "qa_ready", result.fetch("qa_status")
    assert_equal HiveReleaseCandidate::Aggregate::REQUIRED_JOBS.sort,
                 result.fetch("effective_gate_set").map { |row| row.fetch("name") }.sort
    assert_equal 41, result.dig("provenance", "source_run_id")
  end

  def test_retry_selection_resolves_failed_missing_and_preserves_chained_origins
    rows = required_jobs
    failed_name = rows.fetch(0).fetch("name")
    missing_name = rows.fetch(1).fetch("name")
    rows.fetch(0)["conclusion"] = "failure"
    rows.delete_at(1)
    rows.each_with_index do |row, index|
      row["run_id"] = 30 + index
      row["run_attempt"] = 1
    end
    source = {
      "trust_scope" => "trusted_remote",
      "repository" => "ivankuznetsov/hive",
      "request_id" => "req-source2",
      "evidence_sha256" => "e" * 64,
      "run_id" => 41,
      "run_attempt" => 2,
      "candidate_sha" => SHA,
      "workflow_sha" => WORKFLOW_SHA,
      "action_lock_sha256" => ACTION_LOCK,
      "artifact" => {
        "id" => 77,
        "digest" => ARTIFACT_DIGEST,
        "name" => "hive-release-candidate-42-2",
        "producer_run_id" => 42,
        "producer_run_attempt" => 2
      },
      "effective_gate_set" => rows
    }
    selection = HiveReleaseCandidate::RetrySelection.new(
      required_names: HiveReleaseCandidate::Aggregate::REQUIRED_JOBS
    )

    assert_equal [ failed_name ], selection.call(
      source: source, selector: { "mode" => "failed", "gates" => [] }
    )
    assert_equal [ missing_name ], selection.call(
      source: source, selector: { "mode" => "missing", "gates" => [] }
    )

    replacement = required_jobs.find { |row| row["name"] == failed_name }
    result = aggregate.call(
      jobs: [ replacement ],
      ordinary_ci: ordinary_ci,
      source_attempt: source,
      selector: { "mode" => "failed", "gates" => [] }
    )
    assert_equal "qa_blocked", result.fetch("qa_status")
    preserved = result.fetch("effective_gate_set").find do |row|
      row["name"] == HiveReleaseCandidate::Aggregate::REQUIRED_JOBS.fetch(2)
    end
    assert_equal rows.find { |row| row["name"] == preserved["name"] }["run_id"],
                 preserved.fetch("run_id")
  end

  def test_hosted_aggregate_binds_each_api_job_to_the_exact_run_and_attempt
    api_jobs = {
      "jobs" => required_jobs.map do |row|
        {
          "name" => row.fetch("name"), "status" => "completed",
          "conclusion" => "success", "run_id" => 42, "run_attempt" => 2
        }
      end
    }
    checks = {
      "check_runs" => [ ordinary_ci.merge(
        "name" => "rake test (Ruby 3.4)", "app" => { "slug" => "github-actions" },
        "workflow_path" => ".github/workflows/ci.yml"
      ) ]
    }
    checks["check_runs"].first.delete("repository")
    checks["check_runs"].first.delete("workflow")
    checks["check_runs"].first.delete("check_name")

    receipts = required_jobs.map { |row| gate_receipt(row.fetch("name")) }
    result = HiveReleaseCandidate::HostedAggregate.new.call(
      jobs: api_jobs, checks: checks, repository: "ivankuznetsov/hive",
      candidate_sha: SHA, workflow_sha: WORKFLOW_SHA, run_id: 42,
      run_attempt: 2, action_lock_sha256: ACTION_LOCK, artifact_id: 77,
      artifact_digest: ARTIFACT_DIGEST, request_id: "req-abc123",
      artifact_producer_run_id: 42, artifact_producer_run_attempt: 2,
      artifact_name: "hive-release-candidate-42-2",
      receipts: { "receipts" => receipts }
    )
    assert_equal "qa_ready", result.fetch("qa_status")
    assert_equal "req-abc123", result.fetch("request_id")
    schema = JSONSchemer.schema(JSON.parse(File.read(
      File.expand_path(
        "../../../schemas/hive-release-candidate-evidence.v1.json", __dir__
      )
    )))
    assert_empty schema.validate(result).to_a

    api_jobs["jobs"].first["run_attempt"] = 3
    blocked = HiveReleaseCandidate::HostedAggregate.new.call(
      jobs: api_jobs, checks: checks, repository: "ivankuznetsov/hive",
      candidate_sha: SHA, workflow_sha: WORKFLOW_SHA, run_id: 42,
      run_attempt: 2, action_lock_sha256: ACTION_LOCK, artifact_id: 77,
      artifact_digest: ARTIFACT_DIGEST, request_id: "req-abc123",
      artifact_producer_run_id: 42, artifact_producer_run_attempt: 2,
      artifact_name: "hive-release-candidate-42-2",
      receipts: { "receipts" => receipts }
    )
    assert_equal "qa_blocked", blocked.fetch("qa_status")
  end

  def test_hosted_aggregate_blocks_missing_duplicate_or_substituted_receipts
    api_jobs = {
      "jobs" => required_jobs.map do |row|
        {
          "name" => row.fetch("name"), "status" => "completed",
          "conclusion" => "success", "run_id" => 42, "run_attempt" => 2
        }
      end
    }
    checks = {
      "check_runs" => [ ordinary_ci.merge(
        "name" => "rake test (Ruby 3.4)", "app" => { "slug" => "github-actions" },
        "workflow_path" => ".github/workflows/ci.yml"
      ).tap do |row|
        row.delete("repository")
        row.delete("workflow")
        row.delete("check_name")
      end ]
    }
    base = required_jobs.map { |row| gate_receipt(row.fetch("name")) }
    cases = {
      "missing" => base.drop(1),
      "duplicate" => base + [ base.first.dup ],
      "substituted" => base.map(&:dup).tap { |rows| rows.first["artifact_id"] = 88 },
      "foreign" => base + [ gate_receipt("Unregistered gate") ]
    }

    cases.each do |label, rows|
      result = HiveReleaseCandidate::HostedAggregate.new.call(
        jobs: api_jobs, checks: checks, repository: "ivankuznetsov/hive",
        candidate_sha: SHA, workflow_sha: WORKFLOW_SHA, run_id: 42,
        run_attempt: 2, action_lock_sha256: ACTION_LOCK, artifact_id: 77,
        artifact_digest: ARTIFACT_DIGEST, request_id: "req-abc123",
        artifact_producer_run_id: 42, artifact_producer_run_attempt: 2,
        artifact_name: "hive-release-candidate-42-2",
        receipts: { "receipts" => rows }
      )
      assert_equal "qa_blocked", result.fetch("qa_status"), label
      refute_empty result.fetch("blockers"), label
    end
  end

  def test_hosted_retry_ignores_noop_unselected_jobs_and_composes_source_rows
    selected = HiveReleaseCandidate::Aggregate::REQUIRED_JOBS.first
    source_rows = required_jobs.map do |row|
      row.merge("run_id" => 31, "run_attempt" => 1)
    end
    source_rows.first["conclusion"] = "failure"
    source = {
      "trust_scope" => "trusted_remote",
      "repository" => "ivankuznetsov/hive",
      "request_id" => "req-source3",
      "candidate_sha" => SHA,
      "workflow_sha" => WORKFLOW_SHA,
      "run_id" => 41,
      "run_attempt" => 2,
      "action_lock_sha256" => ACTION_LOCK,
      "artifact" => {
        "id" => 77, "digest" => ARTIFACT_DIGEST,
        "name" => "hive-release-candidate-42-2",
        "producer_run_id" => 42, "producer_run_attempt" => 2
      },
      "effective_gate_set" => source_rows
    }
    api_jobs = {
      "jobs" => required_jobs.map do |row|
        {
          "name" => row["name"], "status" => "completed",
          "conclusion" => "success", "run_id" => 52, "run_attempt" => 3
        }
      end
    }
    checks = {
      "check_runs" => [ {
        "name" => "rake test (Ruby 3.4)", "head_sha" => SHA,
        "app" => { "slug" => "github-actions" }, "status" => "completed",
        "conclusion" => "success", "workflow_path" => ".github/workflows/ci.yml",
        "run_id" => 99, "run_attempt" => 1
      } ]
    }
    receipt = gate_receipt(selected).merge("run_id" => 52, "run_attempt" => 3)

    result = HiveReleaseCandidate::HostedAggregate.new.call(
      jobs: api_jobs, checks: checks, receipts: { "receipts" => [ receipt ] },
      repository: "ivankuznetsov/hive", candidate_sha: SHA,
      workflow_sha: WORKFLOW_SHA, run_id: 52, run_attempt: 3,
      action_lock_sha256: ACTION_LOCK, artifact_id: 77,
      artifact_digest: ARTIFACT_DIGEST,
      artifact_producer_run_id: 42, artifact_producer_run_attempt: 2,
      artifact_name: "hive-release-candidate-42-2",
      request_id: "req-abc123", source_attempt: source,
      source_evidence_sha256: "e" * 64,
      selector: { "mode" => "failed", "gates" => [] }
    )

    assert_equal "qa_ready", result.fetch("qa_status")
    assert_equal [ selected ], result.dig("provenance", "replacement_gates")
    origins = result.fetch("effective_gate_set").map { |row| row["run_id"] }.uniq
    assert_includes origins, 31
    assert_includes origins, 52
  end

  private

  def aggregate
    HiveReleaseCandidate::Aggregate.new(
      repository: "ivankuznetsov/hive",
      candidate_sha: SHA,
      workflow_sha: WORKFLOW_SHA,
      run_id: 42,
      run_attempt: 2,
      action_lock_sha256: ACTION_LOCK,
      artifact_id: 77,
      artifact_digest: ARTIFACT_DIGEST
    )
  end

  def required_jobs
    HiveReleaseCandidate::Aggregate::REQUIRED_JOBS.map do |name|
      {
        "name" => name, "status" => "completed", "conclusion" => "success",
        "run_id" => 42, "run_attempt" => 2, "candidate_sha" => SHA,
        "workflow_sha" => WORKFLOW_SHA, "action_lock_sha256" => ACTION_LOCK,
        "artifact_id" => 77, "artifact_digest" => ARTIFACT_DIGEST,
        "artifact_producer_run_id" => 42,
        "artifact_producer_run_attempt" => 2
      }
    end
  end

  def ordinary_ci
    {
      "repository" => "ivankuznetsov/hive", "head_sha" => SHA,
      "workflow" => ".github/workflows/ci.yml", "app" => "github-actions",
      "check_name" => "rake test (Ruby 3.4)", "run_id" => 99,
      "run_attempt" => 1, "status" => "completed", "conclusion" => "success"
    }
  end

  def gate_receipt(name)
    {
      "schema" => "hive-release-candidate-gate-receipt",
      "schema_version" => 1,
      "name" => name,
      "repository" => "ivankuznetsov/hive",
      "request_id" => "req-abc123",
      "candidate_sha" => SHA,
      "workflow_sha" => WORKFLOW_SHA,
      "workflow_path" => ".github/workflows/release-candidate.yml",
      "run_id" => 42,
      "run_attempt" => 2,
      "producer_request_id" => "req-producer",
      "producer_run_id" => 42,
      "producer_run_attempt" => 2,
      "action_lock_sha256" => ACTION_LOCK,
      "artifact_id" => 77,
      "artifact_digest" => ARTIFACT_DIGEST,
      "artifact_name" => "hive-release-candidate-42-2",
      "manifest_sha256" => "f" * 64,
      "manifest_filenames" => [
        "hive-cli-0.7.0.gem",
        "hive-source-#{SHA}.tar.gz",
        "hive-agent-skills-#{SHA}.tar.gz",
        "hive-web-0.7.0.tar.gz"
      ]
    }
  end
end
