# frozen_string_literal: true

require_relative "remote_identity"
require_relative "retry_selection"

module HiveReleaseCandidate
  class Aggregate
    REQUIRED_JOBS = [
      "Catalog integrity",
      "Release E2E profile",
      "Candidate package verification",
      "Managed web setup",
      "Native candidate install (linux-x86_64)",
      "Native candidate install (linux-arm64)",
      "Native candidate install (macos-arm64)",
      "Latest stable upgrade (linux-x86_64)",
      "Latest stable upgrade (linux-arm64)",
      "Latest stable upgrade (macos-arm64)",
      "Legacy bench v0.4.1 upgrade (linux-x86_64)",
      "Baseline catalog freshness",
      "Candidate version newer"
    ].freeze
    ORDINARY_CI_WORKFLOW = ".github/workflows/ci.yml"
    ORDINARY_CI_CHECK = "rake test (Ruby 3.4)"

    attr_reader :repository, :candidate_sha, :workflow_sha, :run_id, :run_attempt,
                :action_lock_sha256, :artifact_id, :artifact_digest,
                :artifact_producer_run_id, :artifact_producer_run_attempt,
                :artifact_name

    def initialize(repository:, candidate_sha:, workflow_sha:, run_id:, run_attempt:,
                   action_lock_sha256:, artifact_id:, artifact_digest:,
                   artifact_producer_run_id: run_id,
                   artifact_producer_run_attempt: run_attempt,
                   artifact_name: nil)
      identity = RemoteIdentity.new(
        repository: repository, candidate_sha: candidate_sha,
        workflow_sha: workflow_sha, action_lock_sha256: action_lock_sha256
      )
      @repository = identity.repository
      @candidate_sha = identity.candidate_sha
      @workflow_sha = identity.workflow_sha
      @action_lock_sha256 = identity.action_lock_sha256
      @run_id = positive_integer(run_id, "run ID")
      @run_attempt = positive_integer(run_attempt, "run attempt")
      @artifact_id = positive_integer(artifact_id, "artifact ID")
      @artifact_digest = artifact_digest.to_s.downcase
      unless RemoteIdentity::ARTIFACT_DIGEST.match?(@artifact_digest)
        raise Error, "artifact digest is invalid"
      end
      @artifact_producer_run_id = positive_integer(
        artifact_producer_run_id, "artifact producer run ID"
      )
      @artifact_producer_run_attempt = positive_integer(
        artifact_producer_run_attempt, "artifact producer run attempt"
      )
      @artifact_name = artifact_name ||
        "hive-release-candidate-#{@artifact_producer_run_id}-#{@artifact_producer_run_attempt}"
    end

    def call(jobs:, ordinary_ci:, advisory: [], source_attempt: nil, selector: nil)
      blockers = []
      effective, provenance = effective_jobs(
        jobs: jobs, source_attempt: source_attempt, selector: selector, blockers: blockers
      )
      blockers << "required_job_set_invalid" unless exact_required_names?(effective)
      valid_job_names = effective.filter_map do |job|
        next unless valid_job?(
          job,
          current_names: provenance.fetch("replacement_gates", []),
          source_attempt: source_attempt
        )

        job["name"]
      end.uniq
      valid_jobs = valid_job_names.size
      blockers << "required_job_identity_invalid" unless
        valid_jobs == REQUIRED_JOBS.size && effective.size == REQUIRED_JOBS.size
      ordinary_valid = valid_ordinary_ci?(ordinary_ci)
      blockers << "ordinary_ci_identity_invalid" unless ordinary_valid
      blockers.uniq!

      passed = blockers.empty?
      {
        "schema" => "hive-release-candidate-evidence",
        "schema_version" => SCHEMA_VERSION,
        "trust_scope" => "trusted_remote",
        "repository" => repository,
        "candidate_sha" => candidate_sha,
        "workflow_sha" => workflow_sha,
        "run_id" => run_id,
        "run_attempt" => run_attempt,
        "action_lock_sha256" => action_lock_sha256,
        "artifact" => {
          "id" => artifact_id,
          "digest" => artifact_digest,
          "name" => artifact_name,
          "producer_run_id" => artifact_producer_run_id,
          "producer_run_attempt" => artifact_producer_run_attempt
        },
        "scope_status" => passed ? "passed" : "failed",
        "qa_status" => passed ? "qa_ready" : "qa_blocked",
        "blockers" => blockers,
        "effective_gate_set" => effective.sort_by { |job| job.fetch("name", "") },
        "ordinary_ci" => ordinary_ci,
        "advisory" => normalize_advisory(advisory),
        "provenance" => provenance,
        "summary" => {
          "required" => REQUIRED_JOBS.size + 1,
          "passed" => valid_jobs + (ordinary_valid ? 1 : 0),
          "failed" => REQUIRED_JOBS.size + 1 - valid_jobs -
            (ordinary_valid ? 1 : 0),
          "advisory" => advisory.size
        },
        "next_action" => {
          "kind" => passed ? "explicit_release_decision_required" : "candidate_qa_blocked",
          "argv" => []
        }
      }
    end

    private

    def effective_jobs(jobs:, source_attempt:, selector:, blockers:)
      current = Array(jobs).map(&:dup)
      unless source_attempt
        return [
          current,
          {
            "run_id" => run_id,
            "run_attempt" => run_attempt,
            "replacement_gates" => REQUIRED_JOBS
          }
        ]
      end

      unless valid_source_identity?(source_attempt)
        blockers << "retry_source_identity_invalid"
        return [ current, {} ]
      end
      selected_names = selected_retry_names(selector, source_attempt, blockers)
      unless current.map { |job| job["name"] }.sort == selected_names.sort
        blockers << "retry_gate_selection_invalid"
      end
      source_jobs = Array(source_attempt["effective_gate_set"]).map(&:dup)
      selected_names.each { |name| source_jobs.reject! { |job| job["name"] == name } }
      effective = source_jobs + current
      provenance = {
        "run_id" => run_id,
        "run_attempt" => run_attempt,
        "source_run_id" => source_attempt["run_id"],
        "source_run_attempt" => source_attempt["run_attempt"],
        "source_request_id" => source_attempt["request_id"],
        "source_evidence_sha256" => source_attempt["evidence_sha256"],
        "selector" => selector,
        "replacement_gates" => selected_names
      }
      [ effective, provenance ]
    end

    def selected_retry_names(selector, source, blockers)
      RetrySelection.new(required_names: REQUIRED_JOBS).call(
        source: source, selector: selector
      )
    rescue Error
      blockers << "retry_selector_invalid"
      []
    end

    def exact_required_names?(jobs)
      names = jobs.map { |job| job["name"] }
      names.size == REQUIRED_JOBS.size && names.uniq.size == names.size &&
        names.sort == REQUIRED_JOBS.sort
    end

    def valid_job?(job, current_names:, source_attempt:)
      return false unless job.is_a?(Hash)
      return false unless REQUIRED_JOBS.include?(job["name"])

      run_valid = if source_attempt && !current_names.include?(job["name"])
                    positive_integer?(job["run_id"]) &&
                      positive_integer?(job["run_attempt"])
                  else
                    job["run_id"] == run_id && job["run_attempt"] == run_attempt
                  end
      run_valid &&
        job.fetch("status", "completed") == "completed" &&
        job.fetch("conclusion", status_to_conclusion(job["status"])) == "success" &&
        job["candidate_sha"] == candidate_sha &&
        job["workflow_sha"] == workflow_sha &&
        job["action_lock_sha256"] == action_lock_sha256 &&
        job["artifact_id"] == artifact_id &&
        job["artifact_digest"] == artifact_digest &&
        job["artifact_producer_run_id"] == artifact_producer_run_id &&
        job["artifact_producer_run_attempt"] == artifact_producer_run_attempt
    end

    def status_to_conclusion(status)
      status == "passed" ? "success" : status
    end

    def valid_source_identity?(source)
      source.is_a?(Hash) &&
        source["trust_scope"] == "trusted_remote" &&
        source["repository"] == repository &&
        RemoteIdentity::REQUEST_ID.match?(source["request_id"].to_s) &&
        source["candidate_sha"] == candidate_sha &&
        source["workflow_sha"] == workflow_sha &&
        source["action_lock_sha256"] == action_lock_sha256 &&
        source.dig("artifact", "id") == artifact_id &&
        source.dig("artifact", "digest") == artifact_digest &&
        source.dig("artifact", "name") == artifact_name &&
        source.dig("artifact", "producer_run_id") == artifact_producer_run_id &&
        source.dig("artifact", "producer_run_attempt") == artifact_producer_run_attempt &&
        source["evidence_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
        positive_integer?(source["run_id"]) &&
        positive_integer?(source["run_attempt"])
    end

    def valid_ordinary_ci?(ci)
      ci.is_a?(Hash) &&
        ci["repository"] == repository &&
        ci["head_sha"] == candidate_sha &&
        ci["workflow"] == ORDINARY_CI_WORKFLOW &&
        ci["app"] == "github-actions" &&
        ci["check_name"] == ORDINARY_CI_CHECK &&
        positive_integer?(ci["run_id"]) &&
        positive_integer?(ci["run_attempt"]) &&
        ci["status"] == "completed" &&
        ci["conclusion"] == "success"
    end

    def normalize_advisory(rows)
      Array(rows).map do |row|
        unless row.is_a?(Hash) && row["class"] == "advisory"
          raise Error, "live proof may be linked only as advisory evidence"
        end
        row
      end
    end

    def positive_integer?(value)
      value.is_a?(Integer) && value.positive?
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
