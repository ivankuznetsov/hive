# frozen_string_literal: true

require "digest"
require "json"

require_relative "proof"

module HiveLiveAgentProof
  # Pure selector for the release workflow's trusted Check Run, proof run,
  # required jobs, and private proof artifact. Network access remains owned by
  # the workflow; this class validates captured GitHub API responses so the
  # complete trust contract is executable against deterministic fixtures.
  class ReleaseSelector
    CHECK_NAME = "live-agent-skills"
    REQUIRED_JOBS = [
      "OpenClaw live Hive operating skill",
      "Claude live Hive operating skill",
      "Codex live Hive operating skill",
      "Pi live Hive operating skill",
      "Attest exact-SHA live agent proof"
    ].freeze
    EXTERNAL_ID = /\Alive-agent-skills:v1:([1-9][0-9]*):([1-9][0-9]*):([0-9a-f]{64})\z/
    ARTIFACT_DIGEST = /\Asha256:[0-9a-f]{64}\z/

    def initialize(candidate_sha:, repository:, checks:, run: nil, jobs: nil, artifacts: nil)
      @candidate_sha = HiveLiveAgentProof.validate_sha!(candidate_sha, "candidate_sha")
      @repository = HiveLiveAgentProof.validate_repository!(repository)
      @checks = checks
      @run = run
      @jobs = jobs
      @artifacts = artifacts
    end

    def check_identity
      check = trusted_check
      match = EXTERNAL_ID.match(check["external_id"].to_s)
      raise Error, "trusted Check Run has malformed external_id" unless match

      run_id = Integer(match[1], 10)
      run_attempt = Integer(match[2], 10)
      expected_details = "https://github.com/#{@repository}/actions/runs/#{run_id}"
      unless check["details_url"] == expected_details
        raise Error, "trusted Check Run details URL does not identify its proof run"
      end

      {
        "candidate_sha" => @candidate_sha,
        "proof_run_id" => run_id,
        "proof_run_attempt" => run_attempt,
        "attestation_sha256" => match[3]
      }
    end

    def select
      identity = check_identity
      validate_run!(identity)
      validate_jobs!(identity)
      artifact = select_artifact(identity)

      identity.merge(
        "workflow_revision" => @run.fetch("head_sha"),
        "proof_artifact_id" => positive_integer!(artifact["id"], "proof artifact id"),
        "proof_artifact_digest" => trusted_artifact_digest!(artifact["digest"])
      )
    end

    private

    def trusted_check
      rows = @checks.is_a?(Hash) ? @checks["check_runs"] : nil
      raise Error, "Check Run response is invalid" unless rows.is_a?(Array)

      matches = rows.select do |check|
        check.is_a?(Hash) && check["name"] == CHECK_NAME &&
          check["head_sha"].to_s.downcase == @candidate_sha &&
          check["status"] == "completed" && check["conclusion"] == "success" &&
          check.dig("app", "slug") == "github-actions"
      end
      check = matches.max_by { |entry| [ entry["completed_at"].to_s, entry["id"].to_i ] }
      raise Error, "no trusted live-agent-skills Check Run" unless check

      check
    end

    def validate_run!(identity)
      raise Error, "proof run response is invalid" unless @run.is_a?(Hash)

      expected = {
        "id" => identity.fetch("proof_run_id"),
        "run_attempt" => identity.fetch("proof_run_attempt"),
        "path" => HiveLiveAgentProof::WORKFLOW_PATH,
        "event" => "workflow_dispatch",
        "head_branch" => "main",
        "status" => "completed",
        "conclusion" => "success"
      }
      valid = expected.all? { |key, value| @run[key] == value } &&
        @run.dig("head_repository", "full_name") == @repository
      raise Error, "proof run identity, attempt, event, branch, repository, or conclusion is invalid" unless valid

      HiveLiveAgentProof.validate_sha!(@run["head_sha"], "workflow revision")
    end

    def validate_jobs!(identity)
      rows = @jobs.is_a?(Hash) ? @jobs["jobs"] : nil
      raise Error, "proof jobs response is invalid" unless rows.is_a?(Array)

      REQUIRED_JOBS.each do |required|
        matches = rows.select do |job|
          job.is_a?(Hash) && job["name"] == required &&
            job["status"] == "completed" && job["conclusion"] == "success" &&
            job["run_id"] == identity.fetch("proof_run_id") &&
            job["run_attempt"] == identity.fetch("proof_run_attempt")
        end
        unless matches.one?
          raise Error, "required non-skipped proof job did not succeed exactly once: #{required}"
        end
      end
    end

    def select_artifact(identity)
      rows = @artifacts.is_a?(Hash) ? @artifacts["artifacts"] : nil
      raise Error, "proof artifacts response is invalid" unless rows.is_a?(Array)

      name = "live-agent-skills-proof-#{identity.fetch('proof_run_attempt')}"
      matches = rows.select do |artifact|
        artifact.is_a?(Hash) && artifact["name"] == name && artifact["expired"] == false
      end
      unless matches.one?
        raise Error, "private proof artifact is absent, ambiguous, or expired"
      end

      matches.first
    end

    def trusted_artifact_digest!(value)
      digest = value.to_s.downcase
      raise Error, "private proof artifact has no trusted SHA-256 digest" unless ARTIFACT_DIGEST.match?(digest)

      digest
    end

    def positive_integer!(value, label)
      integer = value.is_a?(Integer) ? value : Integer(value, 10)
      raise Error, "#{label} must be positive" unless integer.positive?

      integer
    rescue ArgumentError, TypeError
      raise Error, "#{label} must be positive"
    end
  end

  module ReleaseArchiveDigest
    module_function

    def verify!(expected, path)
      expected = expected.to_s.downcase
      unless ReleaseSelector::ARTIFACT_DIGEST.match?(expected)
        raise Error, "expected proof archive digest is invalid"
      end
      unless File.file?(path) && !File.symlink?(path)
        raise Error, "downloaded proof archive is not a regular file"
      end

      actual = "sha256:#{Digest::SHA256.file(path).hexdigest}"
      raise Error, "downloaded proof archive digest does not match the Actions API" unless actual == expected

      actual
    end
  end
end
