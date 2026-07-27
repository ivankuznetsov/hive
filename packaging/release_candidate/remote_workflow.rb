# frozen_string_literal: true

require "json"
require "open3"
require "securerandom"
require "tmpdir"
require_relative "remote_identity"

module HiveReleaseCandidate
  class RemoteWorkflow
    RESOLUTION_ATTEMPTS = 4
    RESOLUTION_INTERVAL = 2
    COLLECT_INTERVAL = 5
    DEFAULT_WAIT_TIMEOUT = 120

    attr_reader :identity, :client

    def initialize(identity:, client:, sleeper: ->(seconds) { sleep(seconds) },
                   monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @identity = identity
      @client = client
      @sleeper = sleeper
      @monotonic_clock = monotonic_clock
    end

    def dispatch(request_id: generate_request_id, selector: nil, source: nil,
                 resolution_attempts: RESOLUTION_ATTEMPTS)
      raise UsageError, "request ID is invalid" unless RemoteIdentity::REQUEST_ID.match?(request_id.to_s)
      attempts = positive_integer(resolution_attempts, "resolution attempts")
      validate_source!(source) if source
      preflight!
      inputs = {
        "candidate_sha" => identity.candidate_sha,
        "request_id" => request_id,
        "action_lock_sha256" => identity.action_lock_sha256
      }
      if source
        inputs.merge!(
          "source_run_id" => source.fetch("run_id").to_s,
          "source_run_attempt" => source.fetch("run_attempt").to_s,
          "source_artifact_id" => source.fetch("artifact_id").to_s,
          "source_artifact_digest" => source.fetch("artifact_digest"),
          "source_artifact_run_id" => source.fetch("artifact_producer_run_id").to_s,
          "source_artifact_run_attempt" => source.fetch("artifact_producer_run_attempt").to_s,
          "source_artifact_name" => source.fetch("artifact_name"),
          "selector" => encode_selector(selector)
        )
      end
      client.dispatch_workflow(
        path: RemoteIdentity::WORKFLOW_PATH, ref: "main", inputs: inputs
      )

      attempts.times do |index|
        result = collect(request_id: request_id)
        return dispatch_result(result) unless result["status"] == "not_found"
        @sleeper.call(RESOLUTION_INTERVAL) if index + 1 < attempts
      end
      {
        "schema" => "hive-release-candidate-dispatch",
        "schema_version" => SCHEMA_VERSION,
        "status" => "dispatched_unresolved",
        "request_id" => request_id,
        "candidate_sha" => identity.candidate_sha,
        "workflow_sha" => identity.workflow_sha,
        "action_lock_sha256" => identity.action_lock_sha256,
        "remote_write_performed" => true,
        "release_action_performed" => false,
        "collect_argv" => [
          "bin/hive-release-candidate", "collect", "--request", request_id
        ]
      }
    end

    def collect(request_id: nil, run_id: nil, attempt: nil, wait: false,
                timeout: DEFAULT_WAIT_TIMEOUT)
      if request_id.to_s.empty? == run_id.to_s.empty?
        raise UsageError, "collect requires exactly one request ID or workflow run ID"
      end
      raise UsageError, "request ID is invalid" if request_id && !RemoteIdentity::REQUEST_ID.match?(request_id.to_s)
      wait_timeout = positive_integer(timeout, "collect timeout") if wait
      started = @monotonic_clock.call
      loop do
        matches = matching_runs(request_id: request_id, run_id: run_id)
        return collection("not_found", request_id: request_id) if matches.empty? && !wait
        return collection("ambiguous", request_id: request_id) if matches.size > 1

        unless matches.empty?
          run = matches.first
          resolved_request = request_id || request_id_from(run)
          run_identity = identity.verify_run!(
            run: run, request_id: resolved_request, expected_attempt: attempt
          )
          status = normalized_status(run)
          return terminal_collection(run_identity, run) if status == "terminal"
          unless wait && %w[queued running].include?(status)
            return collection(status, request_id: resolved_request, run: run_identity)
          end
        end
        if wait && @monotonic_clock.call - started >= wait_timeout
          return collection("timeout", request_id: request_id)
        end

        @sleeper.call(COLLECT_INTERVAL)
      end
    end

    def preflight!
      identity.preflight!(
        repository: client.repository,
        branch: client.branch("main"),
        comparison: client.comparison(
          base: identity.workflow_sha, head: identity.candidate_sha
        ),
        workflow: client.workflow(RemoteIdentity::WORKFLOW_PATH)
      )
    end

    private

    def matching_runs(request_id:, run_id:)
      rows = if run_id
               id = positive_integer(run_id, "workflow run ID")
               row = client.run(id)
               row ? [ row ] : []
      else
               Array(client.workflow_runs(RemoteIdentity::WORKFLOW_PATH)).select do |run|
                 run["name"].to_s.start_with?(
                   "#{RemoteIdentity::RUN_NAME_PREFIX}#{request_id}:"
                 )
               end
      end
      rows.select { |row| row.is_a?(Hash) }
    end

    def normalized_status(run)
      case run["status"]
      when "queued", "waiting", "requested", "pending"
        "queued"
      when "in_progress"
        "running"
      when "completed"
        "terminal"
      else
        raise Error, "workflow run has an unknown status"
      end
    end

    def terminal_collection(run_identity, run)
      rows = client.artifacts(run_identity.fetch("run_id"))
      artifacts = rows.is_a?(Hash) ? Array(rows["artifacts"]) : []
      expected_name = "hive-release-candidate-#{run_identity.fetch('run_id')}-" \
        "#{run_identity.fetch('run_attempt')}"
      matching = artifacts.select { |artifact| artifact["name"] == expected_name }
      artifact = if matching.one?
                   identity.verify_artifact!(
                     artifact: matching.first,
                     run_id: run_identity.fetch("run_id"),
                     run_attempt: run_identity.fetch("run_attempt")
                   )
      elsif matching.empty?
                   artifact_from_terminal_evidence(run_identity, artifacts)
      else
                   raise Error, "candidate artifact is ambiguous"
      end
      collection(
        "terminal", request_id: run_identity.fetch("request_id"),
        run: run_identity, artifact: artifact,
        conclusion: run["conclusion"]
      )
    end

    def artifact_from_terminal_evidence(run_identity, artifacts)
      evidence_name = "hive-release-candidate-evidence-" \
        "#{run_identity.fetch('run_id')}-#{run_identity.fetch('run_attempt')}"
      evidence_artifacts = artifacts.select { |row| row["name"] == evidence_name }
      raise Error, "candidate and terminal evidence artifacts are absent or ambiguous" unless evidence_artifacts.one?

      evidence = client.evidence(
        run_identity.fetch("run_id"), run_identity.fetch("run_attempt")
      )
      unless evidence.is_a?(Hash) &&
             evidence["trust_scope"] == "trusted_remote" &&
             evidence["request_id"] == run_identity.fetch("request_id") &&
             evidence["candidate_sha"] == identity.candidate_sha &&
             evidence["workflow_sha"] == identity.workflow_sha &&
             evidence["run_id"] == run_identity.fetch("run_id") &&
             evidence["run_attempt"] == run_identity.fetch("run_attempt") &&
             evidence["action_lock_sha256"] == identity.action_lock_sha256
        raise Error, "terminal evidence identity does not match the workflow run"
      end
      record = evidence["artifact"]
      raise Error, "terminal evidence candidate artifact identity is invalid" unless record.is_a?(Hash)

      producer_id = positive_integer(record["producer_run_id"], "artifact producer run ID")
      producer_attempt = positive_integer(
        record["producer_run_attempt"], "artifact producer run attempt"
      )
      remote = client.artifact(positive_integer(record["id"], "candidate artifact ID"))
      verified = identity.verify_artifact!(
        artifact: remote, run_id: producer_id, run_attempt: producer_attempt
      )
      unless verified["artifact_digest"] == record["digest"] &&
             verified["artifact_name"] == record["name"]
        raise Error, "terminal evidence candidate artifact does not match GitHub"
      end

      verified
    end

    def collection(status, request_id:, run: nil, artifact: nil, conclusion: nil)
      {
        "schema" => "hive-release-candidate-collect",
        "schema_version" => SCHEMA_VERSION,
        "status" => status,
        "request_id" => request_id,
        "candidate_sha" => identity.candidate_sha,
        "run" => run,
        "artifact" => artifact,
        "conclusion" => conclusion,
        "remote_write_performed" => false,
        "release_action_performed" => false
      }
    end

    def dispatch_result(collection)
      run = collection["run"] || {}
      collection.merge(
        "schema" => "hive-release-candidate-dispatch",
        "run_id" => run["run_id"],
        "run_attempt" => run["run_attempt"],
        "remote_write_performed" => true
      )
    end

    def request_id_from(run)
      name = run["name"].to_s
      match = /\A#{Regexp.escape(RemoteIdentity::RUN_NAME_PREFIX)}(?<request>req-[a-z0-9]{6,48}):[0-9a-f]{40}\z/.match(name)
      raise Error, "workflow run does not expose its candidate request ID" unless match

      match[:request]
    end

    def generate_request_id
      "req-#{SecureRandom.hex(12)}"
    end

    def encode_selector(selector)
      raise UsageError, "hosted retry requires one selector" unless selector.is_a?(Hash)

      mode = selector.fetch("mode")
      gates = Array(selector["gates"])
      unless %w[failed missing named].include?(mode) &&
             (mode != "named" || !gates.empty?)
        raise UsageError, "hosted retry selector is invalid"
      end
      JSON.generate("mode" => mode, "gates" => gates)
    end

    def validate_source!(source)
      unless source.is_a?(Hash) &&
             source["candidate_sha"] == identity.candidate_sha &&
             source["workflow_sha"] == identity.workflow_sha &&
             source["action_lock_sha256"] == identity.action_lock_sha256 &&
             source["artifact_digest"].to_s.match?(RemoteIdentity::ARTIFACT_DIGEST) &&
             source["artifact_name"] ==
               "hive-release-candidate-#{source['artifact_producer_run_id']}-" \
               "#{source['artifact_producer_run_attempt']}"
        raise Error, "hosted retry source identity is invalid"
      end
      positive_integer(source["run_id"], "source run ID")
      positive_integer(source["run_attempt"], "source run attempt")
      positive_integer(source["artifact_id"], "source artifact ID")
      positive_integer(source["artifact_producer_run_id"], "source artifact producer run ID")
      positive_integer(
        source["artifact_producer_run_attempt"], "source artifact producer run attempt"
      )
      true
    end

    def positive_integer(value, label)
      integer = value.is_a?(Integer) ? value : Integer(value, 10)
      raise UsageError, "#{label} must be positive" unless integer.positive?

      integer
    rescue ArgumentError, TypeError
      raise UsageError, "#{label} must be positive"
    end
  end

  class GitHubClient
    def initialize(repo_root:, repository: nil, command_runner: Open3.method(:capture3))
      @repo_root = File.expand_path(repo_root)
      @repository = repository
      @command_runner = command_runner
    end

    def repository
      payload = gh_json("repo", "view", "--json", "nameWithOwner,defaultBranchRef")
      @repository ||= payload.fetch("nameWithOwner")
      {
        "full_name" => @repository,
        "default_branch" => payload.dig("defaultBranchRef", "name")
      }
    end

    def branch(name)
      payload = api("repos/#{repo_slug}/branches/#{name}")
      { "name" => payload["name"], "protected" => payload["protected"] }
    end

    def comparison(base:, head:)
      payload = api("repos/#{repo_slug}/compare/#{base}...#{head}")
      {
        "status" => payload["status"],
        "base_sha" => payload.dig("base_commit", "sha"),
        "head_sha" => payload.dig("head_commit", "sha")
      }
    end

    def workflow(path)
      payload = api("repos/#{repo_slug}/actions/workflows/#{File.basename(path)}")
      revision = api("repos/#{repo_slug}/git/ref/heads/main").dig("object", "sha")
      {
        "path" => payload["path"], "state" => payload["state"], "revision" => revision
      }
    end

    def dispatch_workflow(path:, ref:, inputs:)
      argv = [ "workflow", "run", path, "--repo", repo_slug, "--ref", ref ]
      inputs.sort.each { |key, value| argv.concat([ "--field", "#{key}=#{value}" ]) }
      gh(*argv)
      true
    end

    def workflow_runs(path)
      rows = gh_json(
        "run", "list", "--repo", repo_slug, "--workflow", path,
        "--event", "workflow_dispatch", "--limit", "100", "--json",
        "databaseId,attempt,displayTitle,event,status,conclusion,headSha,headBranch"
      )
      Array(rows).map { |row| normalize_run(row, path: path) }
    end

    def run(run_id)
      payload = gh_json(
        "run", "view", run_id.to_s, "--repo", repo_slug, "--json",
        "databaseId,attempt,displayTitle,event,status,conclusion,headSha,headBranch"
      )
      normalize_run(payload, path: RemoteIdentity::WORKFLOW_PATH)
    rescue UnavailableError => e
      return nil if e.message.include?("not found")

      raise
    end

    def artifacts(run_id)
      api("repos/#{repo_slug}/actions/runs/#{run_id}/artifacts")
    end

    def artifact(artifact_id)
      api("repos/#{repo_slug}/actions/artifacts/#{artifact_id}")
    end

    def evidence(run_id, run_attempt)
      name = "hive-release-candidate-evidence-#{run_id}-#{run_attempt}"
      Dir.mktmpdir("hive-release-candidate-evidence-") do |dir|
        gh(
          "run", "download", run_id.to_s, "--repo", repo_slug,
          "--name", name, "--dir", dir
        )
        JSON.parse(File.binread(File.join(dir, "evidence.json")))
      end
    rescue JSON::ParserError, Errno::ENOENT => e
      raise Error, "terminal evidence artifact is invalid: #{e.message}"
    end

    private

    def normalize_run(row, path:)
      {
        "id" => row["databaseId"],
        "run_attempt" => row["attempt"],
        "name" => row["displayTitle"],
        "event" => row["event"],
        "status" => row["status"],
        "conclusion" => row["conclusion"],
        "head_sha" => row["headSha"],
        "head_branch" => row["headBranch"],
        "path" => path,
        "head_repository" => { "full_name" => repo_slug }
      }
    end

    def api(endpoint)
      gh_json("api", endpoint)
    end

    def gh_json(*argv)
      JSON.parse(gh(*argv))
    rescue JSON::ParserError => e
      raise UnavailableError, "GitHub response is not JSON: #{e.message}"
    end

    def gh(*argv)
      stdout, stderr, status = @command_runner.call(
        "gh", *argv, chdir: @repo_root
      )
      unless status.success?
        message = stderr.to_s.strip
        message = stdout.to_s.strip if message.empty?
        raise UnavailableError, "GitHub command failed: #{message}"
      end
      stdout
    end

    def repo_slug
      @repository ||= repository.fetch("full_name")
    end
  end
end
