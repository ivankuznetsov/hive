# frozen_string_literal: true

require_relative "remote_workflow"

module HiveReleaseCandidate
  class RemoteRun
    def initialize(repo_root:, repository:, remote_client: nil)
      @repo_root = repo_root
      @repository = repository
      @remote_client = remote_client
    end

    def dispatch(ref: nil, retry_run_id: nil, retry_attempt: nil, selector: nil)
      client = remote_client
      if retry_run_id
        source_run = client.run(positive_integer(retry_run_id, "retry workflow run"))
        raise UnavailableError, "retry source workflow run was not found" unless source_run

        candidate_sha = candidate_sha_from_run(source_run)
        remote = remote_workflow(candidate_sha, run: source_run)
        request_id = request_id_from_run(source_run)
        run_identity = remote.identity.verify_run!(
          run: source_run, request_id: request_id, expected_attempt: retry_attempt
        )
        terminal = remote.collect(
          run_id: run_identity.fetch("run_id"),
          attempt: run_identity.fetch("run_attempt")
        )
        unless terminal["status"] == "terminal"
          raise Error, "retry source workflow run is not terminal"
        end
        artifact = terminal.fetch("artifact")
        source = remote.identity.to_h.merge(run_identity).merge(artifact)
        remote.dispatch(source: source, selector: selector)
      else
        sha = @repository.resolve_sha(ref)
        remote_workflow(sha).dispatch
      end
    end

    def collect(workflow_run: nil, request: nil, attempt: nil, wait: false, timeout: nil)
      run = resolve_remote_run(workflow_run: workflow_run, request: request)
      return remote_observation("not_found", request: request) unless run
      return run if run.is_a?(Hash) && run["status"] == "ambiguous"

      candidate_sha = candidate_sha_from_run(run)
      remote_workflow(candidate_sha, run: run).collect(
        run_id: workflow_run, request_id: request, attempt: attempt,
        wait: wait, timeout: timeout || RemoteWorkflow::DEFAULT_WAIT_TIMEOUT
      )
    end

    private

    def remote_client
      @remote_client ||= GitHubClient.new(repo_root: @repo_root)
    end

    def remote_workflow(candidate_sha, run: nil)
      repo = remote_client.repository
      workflow = remote_client.workflow(RemoteIdentity::WORKFLOW_PATH)
      workflow_sha = run ? run.fetch("head_sha") : workflow.fetch("revision")
      inputs = @repository.inputs(workflow_sha)
      action_lock = inputs.fetch("action_lock")
      unless action_lock["status"] == "available"
        raise Error, action_lock.fetch("blocker", "action_lock_unavailable")
      end
      identity = RemoteIdentity.new(
        repository: repo.fetch("full_name"),
        candidate_sha: candidate_sha,
        workflow_sha: workflow_sha,
        action_lock_sha256: action_lock.fetch("sha256")
      )
      RemoteWorkflow.new(identity: identity, client: remote_client)
    end

    def resolve_remote_run(workflow_run:, request:)
      return remote_client.run(positive_integer(workflow_run, "workflow run")) if workflow_run

      matches = Array(remote_client.workflow_runs(RemoteIdentity::WORKFLOW_PATH)).select do |run|
        run["name"].to_s.start_with?(
          "#{RemoteIdentity::RUN_NAME_PREFIX}#{request}:"
        )
      end
      return nil if matches.empty?
      return remote_observation("ambiguous", request: request) unless matches.one?

      matches.first
    end

    def remote_observation(status, request:)
      {
        "schema" => "hive-release-candidate-collect",
        "schema_version" => SCHEMA_VERSION,
        "status" => status,
        "request_id" => request,
        "remote_write_performed" => false,
        "release_action_performed" => false
      }
    end

    def candidate_sha_from_run(run)
      match = /\A#{Regexp.escape(RemoteIdentity::RUN_NAME_PREFIX)}req-[a-z0-9]{6,48}:(?<sha>[0-9a-f]{40})\z/.match(
        run.fetch("name").to_s
      )
      raise Error, "candidate workflow run-name does not bind a full candidate SHA" unless match

      match[:sha]
    end

    def request_id_from_run(run)
      match = /\A#{Regexp.escape(RemoteIdentity::RUN_NAME_PREFIX)}(?<request>req-[a-z0-9]{6,48}):[0-9a-f]{40}\z/.match(
        run.fetch("name").to_s
      )
      raise Error, "candidate workflow run-name does not bind a request ID" unless match

      match[:request]
    end

    def positive_integer(value, label)
      integer = value.is_a?(Integer) ? value : Integer(value, 10)
      raise UsageError, "#{label} must be positive" unless integer.positive?

      integer
    rescue ArgumentError, TypeError
      raise UsageError, "#{label} must be positive"
    end
  end
end
