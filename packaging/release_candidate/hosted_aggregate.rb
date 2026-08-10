# frozen_string_literal: true

require "digest"
require "json"
require_relative "aggregate"
require_relative "hosted_gate"

module HiveReleaseCandidate
  class HostedAggregate
    def call(jobs:, checks:, receipts:, repository:, candidate_sha:, workflow_sha:,
             run_id:, run_attempt:, action_lock_sha256:, artifact_id:,
             artifact_digest:, artifact_producer_run_id:,
             artifact_producer_run_attempt:, artifact_name:, request_id:,
             source_attempt: nil, selector: nil, source_evidence_sha256: nil)
      validate_request_id!(request_id)
      current_run_id = positive_integer(run_id, "run ID")
      current_attempt = positive_integer(run_attempt, "run attempt")
      producer_id = positive_integer(artifact_producer_run_id, "artifact producer run ID")
      producer_attempt = positive_integer(
        artifact_producer_run_attempt, "artifact producer run attempt"
      )
      source = normalize_source(source_attempt, source_evidence_sha256)
      selected_names = selected_names(source, selector)
      job_rows = fetch_array(jobs, "jobs")
      receipt_rows = fetch_receipts(receipts)

      closed_receipts = receipt_rows.select do |row|
        selected_names.include?(row["name"])
      end
      receipt_set_valid = closed_receipts.size == selected_names.size &&
        closed_receipts.map { |row| row["name"] }.uniq.size == selected_names.size &&
        receipt_rows.all? { |row| selected_names.include?(row["name"]) }

      replacements = selected_names.filter_map do |name|
        api_matches = job_rows.select { |row| row["name"] == name }
        gate_matches = closed_receipts.select { |row| row["name"] == name }
        next unless api_matches.one? && gate_matches.one?

        api = api_matches.first
        receipt = gate_matches.first
        next unless valid_receipt?(
          receipt,
          name: name,
          repository: repository,
          request_id: request_id,
          candidate_sha: candidate_sha,
          workflow_sha: workflow_sha,
          run_id: current_run_id,
          run_attempt: current_attempt,
          action_lock_sha256: action_lock_sha256,
          artifact_id: artifact_id,
          artifact_digest: artifact_digest,
          artifact_producer_run_id: producer_id,
          artifact_producer_run_attempt: producer_attempt,
          artifact_name: artifact_name
        )
        next unless api["run_id"] == current_run_id &&
                    api["run_attempt"] == current_attempt

        {
          "name" => name,
          "status" => api["status"],
          "conclusion" => api["conclusion"],
          "run_id" => current_run_id,
          "run_attempt" => current_attempt,
          "candidate_sha" => candidate_sha,
          "workflow_sha" => workflow_sha,
          "workflow_path" => RemoteIdentity::WORKFLOW_PATH,
          "action_lock_sha256" => action_lock_sha256,
          "artifact_id" => positive_integer(artifact_id, "artifact ID"),
          "artifact_digest" => artifact_digest,
          "artifact_producer_run_id" => producer_id,
          "artifact_producer_run_attempt" => producer_attempt,
          "receipt_manifest_sha256" => receipt["manifest_sha256"],
          "receipt_manifest_filenames" => receipt["manifest_filenames"]
        }
      end

      result = Aggregate.new(
        repository: repository, candidate_sha: candidate_sha,
        workflow_sha: workflow_sha, run_id: current_run_id,
        run_attempt: current_attempt, action_lock_sha256: action_lock_sha256,
        artifact_id: artifact_id, artifact_digest: artifact_digest,
        artifact_producer_run_id: producer_id,
        artifact_producer_run_attempt: producer_attempt,
        artifact_name: artifact_name
      ).call(
        jobs: replacements,
        ordinary_ci: exact_ordinary_ci(
          checks, repository: repository, candidate_sha: candidate_sha
        ),
        advisory: [], source_attempt: source, selector: selector
      ).merge("request_id" => request_id)
      block!(result, "gate_receipt_set_invalid") unless receipt_set_valid
      result
    rescue ArgumentError, TypeError => e
      raise Error, "hosted aggregate identity is invalid: #{e.message}"
    end

    private

    def validate_request_id!(request_id)
      return if RemoteIdentity::REQUEST_ID.match?(request_id.to_s)

      raise Error, "hosted aggregate request ID is invalid"
    end

    def normalize_source(source, evidence_sha256)
      return nil unless source

      digest = evidence_sha256.to_s
      unless /\A[0-9a-f]{64}\z/.match?(digest)
        raise Error, "source evidence digest is invalid"
      end
      source.merge("evidence_sha256" => digest)
    end

    def selected_names(source, selector)
      return Aggregate::REQUIRED_JOBS unless source

      RetrySelection.new(required_names: Aggregate::REQUIRED_JOBS).call(
        source: source, selector: selector
      )
    rescue Error
      []
    end

    def valid_receipt?(receipt, name:, repository:, request_id:, candidate_sha:,
                       workflow_sha:, run_id:, run_attempt:, action_lock_sha256:,
                       artifact_id:, artifact_digest:, artifact_producer_run_id:,
                       artifact_producer_run_attempt:, artifact_name:)
      receipt.is_a?(Hash) &&
        receipt["schema"] == HostedGate::RECEIPT_SCHEMA &&
        receipt["schema_version"] == SCHEMA_VERSION &&
        receipt["name"] == name &&
        receipt["repository"] == repository &&
        receipt["request_id"] == request_id &&
        receipt["candidate_sha"] == candidate_sha &&
        receipt["workflow_sha"] == workflow_sha &&
        receipt["workflow_path"] == RemoteIdentity::WORKFLOW_PATH &&
        receipt["run_id"] == run_id &&
        receipt["run_attempt"] == run_attempt &&
        receipt["action_lock_sha256"] == action_lock_sha256 &&
        receipt["artifact_id"] == positive_integer(artifact_id, "artifact ID") &&
        receipt["artifact_digest"] == artifact_digest &&
        receipt["producer_run_id"] == artifact_producer_run_id &&
        receipt["producer_run_attempt"] == artifact_producer_run_attempt &&
        receipt["artifact_name"] == artifact_name &&
        receipt["manifest_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
        exact_manifest_filenames?(receipt["manifest_filenames"], candidate_sha)
    end

    def exact_manifest_filenames?(filenames, candidate_sha)
      return false unless filenames.is_a?(Array) && filenames.size == 4
      return false unless filenames.uniq.size == 4

      filenames.all? do |name|
        name.is_a?(String) && File.basename(name) == name
      end &&
        filenames.one? { |name| name == "hive-source-#{candidate_sha}.tar.gz" } &&
        filenames.one? { |name| name == "hive-agent-skills-#{candidate_sha}.tar.gz" } &&
        filenames.one? { |name| /\Ahive-cli-[0-9A-Za-z.-]+\.gem\z/.match?(name) } &&
        filenames.one? { |name| /\Ahive-web-[0-9A-Za-z.-]+\.tar\.gz\z/.match?(name) }
    end

    def exact_ordinary_ci(checks, repository:, candidate_sha:)
      rows = fetch_array(checks, "check_runs")
      matches = rows.select do |row|
        row["name"] == Aggregate::ORDINARY_CI_CHECK &&
          row["head_sha"] == candidate_sha &&
          row.dig("app", "slug") == "github-actions" &&
          row["status"] == "completed" &&
          row["conclusion"] == "success" &&
          row["workflow_path"] == Aggregate::ORDINARY_CI_WORKFLOW
      end
      return nil unless matches.one?

      row = matches.first
      {
        "repository" => repository,
        "head_sha" => candidate_sha,
        "workflow" => row["workflow_path"],
        "app" => row.dig("app", "slug"),
        "check_name" => row["name"],
        "run_id" => positive_integer(row["run_id"], "ordinary CI run ID"),
        "run_attempt" => positive_integer(
          row["run_attempt"], "ordinary CI run attempt"
        ),
        "status" => row["status"],
        "conclusion" => row["conclusion"]
      }
    rescue Error
      nil
    end

    def fetch_receipts(payload)
      rows = payload.is_a?(Hash) ? payload["receipts"] : payload
      rows.is_a?(Array) ? rows : []
    end

    def fetch_array(payload, key)
      value = payload.is_a?(Hash) ? payload[key] : nil
      value.is_a?(Array) ? value : []
    end

    def block!(result, blocker)
      result["blockers"] = (Array(result["blockers"]) + [ blocker ]).uniq
      result["scope_status"] = "failed"
      result["qa_status"] = "qa_blocked"
      result["summary"]["failed"] = result["blockers"].size
      result["next_action"] = { "kind" => "candidate_qa_blocked", "argv" => [] }
    end

    def positive_integer(value, label)
      integer = value.is_a?(Integer) ? value : Integer(value, 10)
      raise Error, "#{label} must be positive" unless integer.positive?

      integer
    rescue ArgumentError, TypeError
      raise Error, "#{label} must be positive"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  unless ARGV.length == 4
    warn "usage: ruby packaging/release_candidate/hosted_aggregate.rb JOBS CHECKS RECEIPTS OUTPUT"
    exit 64
  end
  begin
    jobs_path, checks_path, receipts_path, output_path = ARGV
    source_path = ENV["SOURCE_EVIDENCE_PATH"].to_s
    selector = ENV["SELECTOR"].to_s
    result = HiveReleaseCandidate::HostedAggregate.new.call(
      jobs: JSON.parse(File.binread(jobs_path)),
      checks: JSON.parse(File.binread(checks_path)),
      receipts: JSON.parse(File.binread(receipts_path)),
      repository: ENV.fetch("GITHUB_REPOSITORY"),
      candidate_sha: ENV.fetch("CANDIDATE_SHA"),
      workflow_sha: ENV.fetch("WORKFLOW_SHA"),
      run_id: ENV.fetch("GITHUB_RUN_ID"),
      run_attempt: ENV.fetch("GITHUB_RUN_ATTEMPT"),
      action_lock_sha256: ENV.fetch("ACTION_LOCK_SHA256"),
      artifact_id: ENV.fetch("ARTIFACT_ID"),
      artifact_digest: ENV.fetch("ARTIFACT_DIGEST"),
      artifact_producer_run_id: ENV.fetch("ARTIFACT_PRODUCER_RUN_ID"),
      artifact_producer_run_attempt: ENV.fetch("ARTIFACT_PRODUCER_RUN_ATTEMPT"),
      artifact_name: ENV.fetch("ARTIFACT_NAME"),
      request_id: ENV.fetch("REQUEST_ID"),
      source_attempt: source_path.empty? ? nil : JSON.parse(File.binread(source_path)),
      selector: selector.empty? ? nil : JSON.parse(selector),
      source_evidence_sha256: ENV["SOURCE_EVIDENCE_SHA256"]
    )
    File.write(output_path, "#{JSON.pretty_generate(result)}\n")
    exit(result["qa_status"] == "qa_ready" ? 0 : 1)
  rescue HiveReleaseCandidate::Error, JSON::ParserError, KeyError => e
    warn "hosted-aggregate: #{e.message}"
    exit 78
  end
end
