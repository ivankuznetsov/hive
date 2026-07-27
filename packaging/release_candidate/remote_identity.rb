# frozen_string_literal: true

require "digest"
require "json"
require_relative "paths"

module HiveReleaseCandidate
  class RemoteIdentity
    WORKFLOW_PATH = ".github/workflows/release-candidate.yml"
    WORKFLOW_NAME = "release-candidate"
    RUN_NAME_PREFIX = "hive-release-candidate:"
    REQUEST_ID = /\Areq-[a-z0-9]{6,48}\z/.freeze
    ARTIFACT_DIGEST = /\Asha256:[0-9a-f]{64}\z/.freeze
    REPOSITORY = /\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/.freeze

    attr_reader :repository, :candidate_sha, :workflow_sha, :action_lock_sha256

    def initialize(repository:, candidate_sha:, workflow_sha:, action_lock_sha256:)
      @repository = validate_repository(repository)
      @candidate_sha = validate_sha(candidate_sha, "candidate SHA")
      @workflow_sha = validate_sha(workflow_sha, "workflow SHA")
      @action_lock_sha256 = validate_sha256(action_lock_sha256, "action-lock digest")
    end

    def preflight!(repository:, branch:, comparison:, workflow:)
      unless repository.is_a?(Hash) &&
             repository["full_name"] == self.repository &&
             repository["default_branch"] == "main"
        raise Error, "repository or protected default branch identity is invalid"
      end
      unless branch.is_a?(Hash) && branch["name"] == "main" && branch["protected"] == true
        raise Error, "repository main branch is not protected"
      end
      unless comparison.is_a?(Hash) &&
             %w[behind identical].include?(comparison["status"]) &&
             comparison["base_sha"].to_s.downcase == workflow_sha &&
             comparison["head_sha"].to_s.downcase == candidate_sha
        raise Error, "candidate SHA is not reachable from protected main"
      end
      unless workflow.is_a?(Hash) &&
             workflow["path"] == WORKFLOW_PATH &&
             workflow["state"] == "active" &&
             workflow["revision"].to_s.downcase == workflow_sha
        raise Error, "candidate workflow path, state, or trusted revision is invalid"
      end

      to_h
    end

    def verify_run!(run:, request_id:, expected_attempt: nil)
      validate_request_id(request_id)
      raise Error, "workflow run response is invalid" unless run.is_a?(Hash)

      expected = {
        "event" => "workflow_dispatch",
        "head_sha" => workflow_sha,
        "head_branch" => "main",
        "path" => WORKFLOW_PATH
      }
      valid = expected.all? { |key, value| run[key].to_s.downcase == value.downcase } &&
        run.dig("head_repository", "full_name") == repository &&
        run["name"] == "#{RUN_NAME_PREFIX}#{request_id}:#{candidate_sha}"
      raise Error, "workflow run identity does not match the dispatch request" unless valid

      run_id = positive_integer(run["id"], "workflow run ID")
      run_attempt = positive_integer(run["run_attempt"], "workflow run attempt")
      if expected_attempt && run_attempt != positive_integer(expected_attempt, "expected run attempt")
        raise Error, "workflow run attempt does not match the requested attempt"
      end

      to_h.merge(
        "request_id" => request_id,
        "run_id" => run_id,
        "run_attempt" => run_attempt,
        "status" => run["status"],
        "conclusion" => run["conclusion"]
      )
    end

    def verify_artifact!(artifact:, run_id:, run_attempt:)
      raise Error, "candidate artifact response is invalid" unless artifact.is_a?(Hash)

      expected_name = "hive-release-candidate-#{positive_integer(run_id, 'workflow run ID')}-" \
        "#{positive_integer(run_attempt, 'workflow run attempt')}"
      unless artifact["name"] == expected_name &&
             artifact["expired"] == false &&
             artifact.dig("workflow_run", "id") == run_id &&
             artifact.dig("workflow_run", "head_sha").to_s.downcase == workflow_sha
        raise Error, "candidate artifact run, attempt, name, expiry, or revision is invalid"
      end

      {
        "artifact_id" => positive_integer(artifact["id"], "candidate artifact ID"),
        "artifact_digest" => validate_artifact_digest(artifact["digest"]),
        "artifact_name" => expected_name,
        "artifact_producer_run_id" => positive_integer(run_id, "workflow run ID"),
        "artifact_producer_run_attempt" => positive_integer(
          run_attempt, "workflow run attempt"
        )
      }
    end

    def to_h
      {
        "repository" => repository,
        "candidate_sha" => candidate_sha,
        "workflow_sha" => workflow_sha,
        "workflow_path" => WORKFLOW_PATH,
        "action_lock_sha256" => action_lock_sha256
      }
    end

    class << self
      def action_lock(sources)
        entries = sources.sort.flat_map do |path, source|
          source.scan(/^\s*(?:-\s*)?uses:\s+([^@\s]+)(?:@([^#\s]+))?(?:\s+#.*)?$/).filter_map do |action, revision|
            next if action.start_with?("./")
            unless /\A[0-9a-f]{40}\z/.match?(revision)
              raise Error, "third-party Action is not full-SHA pinned: #{action}@#{revision}"
            end
            { "workflow" => path, "action" => action, "revision" => revision }
          end
        end
        payload = JSON.generate(entries)
        { "entries" => entries, "sha256" => Digest::SHA256.hexdigest(payload) }
      end
    end

    private

    def validate_repository(value)
      repository = value.to_s
      raise Error, "repository identity is invalid" unless REPOSITORY.match?(repository)

      repository
    end

    def validate_request_id(value)
      request_id = value.to_s
      raise Error, "request ID is invalid" unless REQUEST_ID.match?(request_id)

      request_id
    end

    def validate_sha(value, label)
      sha = value.to_s.downcase
      raise Error, "#{label} must be a full 40-character SHA" unless SAFE_SHA.match?(sha)

      sha
    end

    def validate_sha256(value, label)
      digest = value.to_s.downcase
      raise Error, "#{label} must be a SHA-256 digest" unless /\A[0-9a-f]{64}\z/.match?(digest)

      digest
    end

    def validate_artifact_digest(value)
      digest = value.to_s.downcase
      raise Error, "candidate artifact has no trusted SHA-256 digest" unless ARTIFACT_DIGEST.match?(digest)

      digest
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
