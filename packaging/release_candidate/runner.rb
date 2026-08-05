# frozen_string_literal: true

require "pathname"
require_relative "baseline_cache"
require_relative "gate_execution"
require_relative "gate_registry"
require_relative "local_attempt"
require_relative "paths"
require_relative "remote_run"
require_relative "repository"

module HiveReleaseCandidate
  class Runner
    attr_reader :repo_root, :runs_root, :repository, :registry

    def initialize(repo_root:, runs_root: nil, gate_executor: nil, upgrade_executor: nil,
                   sandbox: nil, remote_client: nil)
      @repo_root = File.expand_path(repo_root)
      @runs_root = runs_root
      @repository = Repository.new(@repo_root)
      @registry = GateRegistry.new
      @baseline_cache = BaselineCache.new(repo_root: @repo_root, repository: @repository)
      @gate_execution = GateExecution.new(
        gate_executor: gate_executor, upgrade_executor: upgrade_executor, sandbox: sandbox
      )
      @local_attempt = LocalAttempt.new(
        repo_root: @repo_root, runs_root: @runs_root,
        repository: @repository, registry: @registry,
        baseline_cache: @baseline_cache, gate_execution: @gate_execution
      )
      @remote_run = RemoteRun.new(
        repo_root: @repo_root, repository: @repository, remote_client: remote_client
      )
    end

    def plan(ref: nil)
      sha = repository.resolve_sha(ref)
      paths = paths_for(sha)
      candidate_exists = File.directory?(paths.candidate_dir) && !File.symlink?(paths.candidate_dir)
      inputs = repository.inputs(sha)
      baseline_cache = @baseline_cache.plan(sha, paths, inputs)
      candidate_version = repository.version(sha)
      baseline_version = inputs.dig("baselines", "latest_stable_version")
      {
        "schema" => "hive-release-candidate-plan",
        "schema_version" => SCHEMA_VERSION,
        "candidate_sha" => sha,
        "candidate_version" => candidate_version,
        "baseline_version" => baseline_version,
        "dirty_checkout" => repository.dirty?,
        "candidate_path" => relative_repo_path(paths.candidate_dir),
        "candidate_exists" => candidate_exists,
        "inputs" => inputs,
        "baseline_cache" => baseline_cache,
        "gate_registry" => registry.payload,
        "trust_scope" => "local",
        "scope_status" => "unavailable",
        "qa_status" => "qa_blocked",
        "blockers" => @baseline_cache.blockers(
          candidate_version: candidate_version,
          baseline_version: baseline_version,
          baseline_cache: baseline_cache
        ),
        "run_argv" => [ "bin/hive-release-candidate", "run", "--sha", sha ],
        "release_actions" => []
      }
    end

    def run(ref:, gates: [])
      @local_attempt.run(ref: ref, gates: gates)
    end

    def resume(ref:, attempt_id:)
      @local_attempt.resume(ref: ref, attempt_id: attempt_id)
    end

    def rerun(ref:, attempt_id:, mode:, gates: [])
      @local_attempt.rerun(ref: ref, attempt_id: attempt_id, mode: mode, gates: gates)
    end

    def inspect(ref:, attempt_id:)
      @local_attempt.inspect(ref: ref, attempt_id: attempt_id)
    end

    def list(ref:)
      @local_attempt.list(ref: ref)
    end

    def dispatch(ref: nil, retry_run_id: nil, retry_attempt: nil, selector: nil)
      @remote_run.dispatch(
        ref: ref, retry_run_id: retry_run_id, retry_attempt: retry_attempt, selector: selector
      )
    end

    def collect(workflow_run: nil, request: nil, attempt: nil, wait: false, timeout: nil)
      @remote_run.collect(
        workflow_run: workflow_run, request: request, attempt: attempt,
        wait: wait, timeout: timeout
      )
    end

    private

    def paths_for(sha)
      Paths.new(repo_root: repo_root, candidate_sha: sha, runs_root: runs_root)
    end

    def relative_repo_path(path)
      Pathname.new(path).relative_path_from(Pathname.new(repo_root)).to_s
    end
  end
end
