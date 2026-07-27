# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "rubygems"
require_relative "artifacts"
require_relative "asset_verifier"
require_relative "baseline_catalog"
require_relative "evidence"
require_relative "gate_registry"
require_relative "aggregate"
require_relative "remote_workflow"
require_relative "sandbox"
require_relative "upgrade_survivor"

module HiveReleaseCandidate
  class Repository
    attr_reader :root

    def initialize(root)
      @root = File.expand_path(root)
      @show_cache = {}
      @version_cache = {}
      @baseline_catalog_cache = {}
    end

    def resolve_sha(ref = nil)
      requested = ref.to_s.empty? ? "HEAD" : ref.to_s
      stdout, stderr, status = git("rev-parse", "--verify", "#{requested}^{commit}")
      sha = stdout.strip.downcase
      unless status.success? && SAFE_SHA.match?(sha)
        raise UsageError, "cannot resolve committed candidate #{requested.inspect}: #{stderr.strip}"
      end
      sha
    end

    def version(sha)
      @version_cache.fetch(sha) do
        source = show(sha, "lib/hive/version.rb")
        match = source.match(/\bVERSION\s*=\s*["']([^"']+)["']/)
        raise Error, "cannot read committed Hive version for #{sha}" unless match

        @version_cache[sha] = match[1]
      end
    end

    def dirty?
      stdout, _stderr, status = git("status", "--porcelain=v1", "--untracked-files=normal")
      raise UnavailableError, "cannot inspect repository dirty state" unless status.success?

      !stdout.empty?
    end

    def inputs(sha)
      {
        "coverage" => committed_or_placeholder(
          sha, "test/e2e/coverage.yml",
          schema: "hive-release-candidate-coverage-input",
          blocker: "coverage_catalog_missing_from_candidate"
        ),
        "baselines" => baseline_input(sha),
        "action_lock" => action_lock_input(sha),
        "workflow" => committed_or_placeholder(
          sha, ".github/workflows/release-candidate.yml",
          schema: "hive-release-candidate-workflow-input",
          blocker: "hosted_workflow_unavailable_until_u5"
        ),
        "tool" => paths_input(
          sha,
          [
            "bin/hive-release-candidate",
            "packaging/release_candidate/artifacts.rb",
            "packaging/release_candidate/asset_verifier.rb",
            "packaging/release_candidate/baseline_catalog.rb",
            "packaging/release_candidate/baselines.yml",
            "packaging/release_candidate/baseline_cache_materializer.rb",
            "packaging/release_candidate/materialize_baseline_cache.rb",
            "packaging/release_candidate/evidence.rb",
            "packaging/release_candidate/gate_registry.rb",
            "packaging/release_candidate/installed_target.rb",
            "packaging/release_candidate/runner.rb",
            "packaging/release_candidate/paths.rb",
            "packaging/release_candidate/cli.rb",
            "packaging/release_candidate/sandbox.rb",
            "packaging/release_candidate/invariant_snapshot.rb",
            "packaging/release_candidate/process_teardown.rb",
            "packaging/release_candidate/upgrade_survivor.rb",
            "packaging/release_candidate/hosted_upgrade_lane.rb",
            "packaging/release_candidate/aggregate.rb",
            "packaging/release_candidate/retry_selection.rb",
            "packaging/release_candidate/remote_identity.rb",
            "packaging/release_candidate/remote_workflow.rb",
            "packaging/release_candidate/hosted_gate.rb",
            "packaging/release_candidate/verify_hosted_gate.sh",
            "packaging/release_candidate/hosted_stage.rb",
            "packaging/release_candidate/hosted_aggregate.rb"
          ],
          schema: "hive-release-candidate-tool-input",
          blocker: "candidate_tool_not_in_committed_tree"
        ),
        "schema" => committed_or_placeholder(
          sha, "schemas/hive-release-candidate-evidence.v1.json",
          schema: "hive-release-candidate-schema-input",
          blocker: "candidate_schema_not_in_committed_tree"
        )
      }
    end

    def baseline_catalog(sha)
      @baseline_catalog_cache.fetch(sha) do
        catalog = BaselineCatalog.parse(
          show(sha, "packaging/release_candidate/baselines.yml"),
          source: "#{sha}:packaging/release_candidate/baselines.yml"
        )
        catalog.entries.each do |entry|
          offline = entry.dependency_closure.fetch("offline_cache")
          content = show(sha, offline.fetch("manifest_path"))
          unless Digest::SHA256.hexdigest(content) == offline.fetch("manifest_sha256")
            raise Error, "#{entry.id} reviewed offline cache manifest digest mismatch"
          end
        end
        @baseline_catalog_cache[sha] = catalog
      end
    end

    def show(sha, path)
      key = [ sha, path ]
      @show_cache.fetch(key) do
        stdout, stderr, status = git("show", "#{sha}:#{path}")
        raise Error, "cannot read committed #{path}: #{stderr.strip}" unless status.success?

        @show_cache[key] = stdout
      end
    end

    private

    def git(*argv)
      Open3.capture3("git", *argv, chdir: root)
    end

    def committed_input(sha, path, schema:)
      content = show(sha, path)
      {
        "schema" => schema,
        "schema_version" => SCHEMA_VERSION,
        "status" => "available",
        "path" => path,
        "sha256" => Digest::SHA256.hexdigest(content)
      }
    end

    def committed_or_placeholder(sha, path, schema:, blocker:)
      committed_input(sha, path, schema: schema)
    rescue Error
      placeholder_input(schema: schema, status: "unavailable", blocker: blocker, path: path)
    end

    def baseline_input(sha)
      baseline_catalog(sha).input_payload
    rescue Error => e
      placeholder_input(
        schema: "hive-release-candidate-baseline-input",
        status: "unavailable",
        blocker: "baseline_catalog_missing_or_invalid",
        catalog_dependency_closure_sha256: Digest::SHA256.hexdigest(
          "baseline dependency closure unavailable"
        ),
        diagnostic: e.message
      )
    end

    def action_lock_input(sha)
      paths = %w[
        .github/workflows/release-candidate.yml
        .github/workflows/release.yml
      ]
      sources = paths.to_h do |path|
        [ path, show(sha, path) ]
      end
      if sources.empty?
        return placeholder_input(
          schema: "hive-release-candidate-action-lock-input",
          status: "unavailable", blocker: "action_lock_missing"
        )
      end
      lock = RemoteIdentity.action_lock(sources)
      {
        "schema" => "hive-release-candidate-action-lock-input",
        "schema_version" => SCHEMA_VERSION,
        "status" => "available",
        "paths" => paths,
        "entries" => lock.fetch("entries"),
        "sha256" => lock.fetch("sha256")
      }
    rescue Error => e
      placeholder_input(
        schema: "hive-release-candidate-action-lock-input",
        status: "unavailable", blocker: "action_lock_invalid",
        diagnostic: e.message
      )
    end

    def paths_input(sha, paths, schema:, blocker:)
      contents = paths.filter_map do |path|
        [ path, show(sha, path) ]
      rescue Error
        nil
      end
      if contents.size != paths.size
        return placeholder_input(schema: schema, status: "unavailable", blocker: blocker, paths: paths)
      end

      digest = Digest::SHA256.new
      contents.each { |path, content| digest << path << "\0" << content << "\0" }
      {
        "schema" => schema,
        "schema_version" => SCHEMA_VERSION,
        "status" => "available",
        "paths" => paths,
        "sha256" => digest.hexdigest
      }
    end

    def placeholder_input(schema:, status:, blocker:, **fields)
      seed = {
        "schema" => schema,
        "schema_version" => SCHEMA_VERSION,
        "status" => status,
        "blocker" => blocker
      }.merge(fields.to_h { |key, value| [ key.to_s, value ] })
      seed.merge("sha256" => Digest::SHA256.hexdigest(JSON.generate(seed.sort.to_h)))
    end
  end

  class Runner
    attr_reader :repo_root, :runs_root, :repository, :registry

    def initialize(repo_root:, runs_root: nil, gate_executor: nil, upgrade_executor: nil,
                   sandbox: nil, remote_client: nil)
      @repo_root = File.expand_path(repo_root)
      @runs_root = runs_root
      @repository = Repository.new(@repo_root)
      @registry = GateRegistry.new
      @gate_executor = gate_executor
      @upgrade_executor = upgrade_executor
      @sandbox = sandbox || Sandbox.new
      @remote_client = remote_client
    end

    def plan(ref: nil)
      sha = repository.resolve_sha(ref)
      paths = paths_for(sha)
      candidate_exists = File.directory?(paths.candidate_dir) && !File.symlink?(paths.candidate_dir)
      inputs = repository.inputs(sha)
      baseline_cache = baseline_cache_plan(sha, paths, inputs)
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
        "blockers" => plan_blockers(
          candidate_version: candidate_version,
          baseline_version: baseline_version,
          baseline_cache: baseline_cache
        ),
        "run_argv" => [ "bin/hive-release-candidate", "run", "--sha", sha ],
        "release_actions" => []
      }
    end

    def run(ref:, gates: [])
      sha = repository.resolve_sha(ref)
      paths = paths_for(sha)
      selected = gates.empty? ? registry.local_defaults : registry.select_named(gates)
      operate(paths, selected: selected, selection_mode: "run")
    end

    def resume(ref:, attempt_id:)
      sha = repository.resolve_sha(ref)
      paths = paths_for(sha)
      paths.with_lock do
        source = Evidence.new(paths: paths).load(attempt_id)
        selected = missing_for_resume(source)
        raise UsageError, "attempt has no incomplete local gates to resume" if selected.empty?

        operate_locked(
          paths, selected: selected, selection_mode: "resume", predecessor: source
        )
      end
    end

    def rerun(ref:, attempt_id:, mode:, gates: [])
      sha = repository.resolve_sha(ref)
      paths = paths_for(sha)
      paths.with_lock do
        source = Evidence.new(paths: paths).load(attempt_id)
        selected = registry.rerun(source: source, mode: mode, names: gates)
        operate_locked(
          paths, selected: selected, selection_mode: "rerun_#{mode}", predecessor: source
        )
      end
    end

    def inspect(ref:, attempt_id:)
      sha = repository.resolve_sha(ref)
      Evidence.new(paths: paths_for(sha)).load(attempt_id)
    end

    def list(ref:)
      sha = repository.resolve_sha(ref)
      paths = paths_for(sha)
      {
        "schema" => "hive-release-candidate-list",
        "schema_version" => SCHEMA_VERSION,
        "candidate_sha" => sha,
        "current_attempt_id" => current_attempt(paths),
        "attempts" => Evidence.new(paths: paths).list
      }
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
        sha = repository.resolve_sha(ref)
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
      @remote_client ||= GitHubClient.new(repo_root: repo_root)
    end

    def remote_workflow(candidate_sha, run: nil)
      repo = remote_client.repository
      workflow = remote_client.workflow(RemoteIdentity::WORKFLOW_PATH)
      workflow_sha = run ? run.fetch("head_sha") : workflow.fetch("revision")
      inputs = repository.inputs(workflow_sha)
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

    def paths_for(sha)
      Paths.new(repo_root: repo_root, candidate_sha: sha, runs_root: runs_root)
    end

    def operate(paths, selected:, selection_mode:, predecessor: nil)
      paths.with_lock do
        operate_locked(
          paths, selected: selected, selection_mode: selection_mode,
          predecessor: predecessor
        )
      end
    end

    def operate_locked(paths, selected:, selection_mode:, predecessor:)
      expected_inputs = repository.inputs(paths.candidate_sha)
      baseline_cache = baseline_cache_plan(paths.candidate_sha, paths, expected_inputs)
      paths.prepare!
      artifacts = Artifacts.new(
        repo_root: repo_root, candidate_sha: paths.candidate_sha,
        candidate_dir: paths.candidate_dir
      )
      manifest = artifacts.call
      inputs = prepare_inputs(paths, expected_inputs)
      evidence = Evidence.new(paths: paths)
      identity = evidence.identity(
        candidate_manifest: paths.manifest_path, inputs: inputs,
        baseline_cache: baseline_cache
      )
      evidence.verify_resume_identity!(predecessor, identity) if predecessor

      started_at = Time.now.utc
      results = []
      interrupted = false
      with_interrupt_capture do
        selected.each_with_index do |gate, index|
          results << execute_gate(
            gate, artifacts: artifacts, inputs: inputs, manifest: manifest,
            baseline_cache: baseline_cache
          )
        rescue Interrupt, SignalException
          interrupted = true
          results << {
            "name" => gate.name,
            "status" => "running",
            "reason" => "interrupted"
          }
          selected.drop(index + 1).each do |pending_gate|
            results << {
              "name" => pending_gate.name,
              "status" => "pending",
              "reason" => "interrupted_before_start"
            }
          end
          break
        end
      end
      document = evidence.write_attempt(
        identity: identity,
        selected_gates: selected.map(&:name),
        gate_results: results,
        predecessor: predecessor,
        selection_mode: selection_mode,
        interrupted: interrupted,
        candidate_version: manifest.fetch("hive_version"),
        baseline_version: inputs.dig("baselines", "latest_stable_version"),
        dirty_checkout: repository.dirty?,
        started_at: started_at,
        finished_at: Time.now.utc
      )
      raise TemporaryError, "candidate attempt was interrupted: #{document.fetch('attempt_id')}" if interrupted

      document
    end

    def execute_gate(gate, artifacts:, inputs:, manifest:, baseline_cache:)
      return @gate_executor.call(gate) if @gate_executor

      case gate.name
      when "artifact_integrity"
        artifacts.verify!
        { "name" => gate.name, "status" => "passed", "reason" => nil }
      when "coverage_catalog"
        coverage = inputs.fetch("coverage")
        if coverage["status"] == "available"
          { "name" => gate.name, "status" => "passed", "reason" => nil }
        else
          {
            "name" => gate.name, "status" => "unavailable",
            "reason" => coverage.fetch("blocker", "coverage_catalog_unavailable")
          }
        end
      when "baseline_catalog"
        baseline = inputs.fetch("baselines")
        details = baseline_cache.slice(
          "status", "release_assets_sha256", "verified_dependency_closure_sha256"
        )
        if baseline["status"] == "available" && baseline_cache["status"] == "available"
          { "name" => gate.name, "status" => "passed", "reason" => nil, "details" => details }
        else
          {
            "name" => gate.name, "status" => "unavailable",
            "reason" => baseline_cache["reason"] ||
              baseline.fetch("blocker", "baseline_catalog_unavailable"),
            "details" => details
          }
        end
      when "latest_stable_upgrade"
        execute_upgrade_gate(
          gate, row_id: "latest-stable", manifest: manifest,
          baseline_cache: baseline_cache, artifacts: artifacts
        )
      when "legacy_bench_v041_upgrade"
        execute_upgrade_gate(
          gate, row_id: "legacy-bench-v041", manifest: manifest,
          baseline_cache: baseline_cache, artifacts: artifacts
        )
      when "candidate_version"
        begin
          baseline_version = inputs.dig("baselines", "latest_stable_version")
          unless baseline_version
            return {
              "name" => gate.name, "status" => "unavailable",
              "reason" => "baseline_catalog_unavailable"
            }
          end
          if Gem::Version.new(manifest.fetch("hive_version")) >
             Gem::Version.new(baseline_version)
            { "name" => gate.name, "status" => "passed", "reason" => nil }
          else
            { "name" => gate.name, "status" => "failed", "reason" => "candidate_not_newer" }
          end
        rescue ArgumentError
          {
            "name" => gate.name, "status" => "unavailable",
            "reason" => "candidate_version_invalid"
          }
        end
      else
        { "name" => gate.name, "status" => "unavailable", "reason" => "remote_validation_required" }
      end
    end

    def execute_upgrade_gate(gate, row_id:, manifest:, baseline_cache:, artifacts:)
      unless baseline_cache["status"] == "available"
        return {
          "name" => gate.name, "status" => "unavailable",
          "reason" => baseline_cache["reason"] || "authenticated_baseline_cache_unavailable",
          "details" => {
            "row_id" => row_id, "producer_started" => false,
            "next_action_argv" => [
              "bin/hive-release-candidate", "dispatch", "--sha",
              manifest.fetch("candidate_sha")
            ]
          }
        }
      end
      unless @upgrade_executor
        return {
          "name" => gate.name, "status" => "unavailable",
          "reason" => "compliant_local_upgrade_executor_unavailable",
          "details" => {
            "row_id" => row_id, "producer_started" => false,
            "next_action_argv" => [
              "bin/hive-release-candidate", "dispatch", "--sha",
              manifest.fetch("candidate_sha")
            ]
          }
        }
      end
      capability = @sandbox.capability(candidate_sha: manifest.fetch("candidate_sha"))
      unless capability["status"] == "available"
        return {
          "name" => gate.name, "status" => "unavailable",
          "reason" => capability.fetch("reason", "disposable_sandbox_unavailable"),
          "details" => capability.merge("row_id" => row_id, "producer_started" => false)
        }
      end

      result = @upgrade_executor.call(
        row_id: row_id, platform: current_platform,
        candidate_manifest: manifest, candidate_dir: artifacts.candidate_dir,
        baseline_cache: baseline_cache, sandbox: capability
      )
      status = result.fetch("status")
      unless %w[passed failed unavailable].include?(status)
        raise Error, "upgrade executor returned invalid status #{status.inspect}"
      end
      {
        "name" => gate.name, "status" => status,
        "reason" => result["reason"],
        "details" => result.merge("producer_started" => true)
      }
    rescue KeyError => e
      {
        "name" => gate.name, "status" => "failed",
        "reason" => "upgrade_evidence_invalid",
        "details" => { "row_id" => row_id, "diagnostic" => e.message }
      }
    end

    def current_platform
      return "macos-arm64" if RUBY_PLATFORM.include?("darwin") && RUBY_PLATFORM.include?("arm64")
      return "linux-arm64" if RUBY_PLATFORM.include?("linux") && RUBY_PLATFORM.match?(/aarch64|arm64/)

      "linux-x86_64"
    end

    def with_interrupt_capture
      main = Thread.main
      previous = %w[INT TERM].to_h do |signal|
        [ signal, Signal.trap(signal) { main.raise(Interrupt) } ]
      end
      yield
    ensure
      previous&.each { |signal, handler| Signal.trap(signal, handler) }
    end

    def prepare_inputs(paths, expected)
      if File.directory?(paths.inputs_dir) && !File.symlink?(paths.inputs_dir)
        actual_names = Dir.children(paths.inputs_dir).sort
        expected_names = expected.keys.map { |name| "#{name}.json" }.sort
        raise Error, "candidate inputs contain unexpected files" unless actual_names == expected_names

        actual = expected.keys.to_h do |name|
          path = File.join(paths.inputs_dir, "#{name}.json")
          unless File.file?(path) && !File.symlink?(path)
            raise Error, "candidate input is missing or unsafe: #{name}"
          end
          [ name, JSON.parse(File.read(path)) ]
        end
        raise Error, "candidate input identity drift" unless actual == expected

        return actual
      end
      if File.exist?(paths.inputs_dir) || File.symlink?(paths.inputs_dir)
        raise Error, "candidate input path collision"
      end

      stage = Dir.mktmpdir(".inputs-", paths.candidate_root)
      begin
        expected.each do |name, payload|
          path = File.join(stage, "#{name}.json")
          File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
            file.write(JSON.pretty_generate(payload))
            file.write("\n")
            file.flush
            file.fsync
          end
          File.chmod(0o400, path)
        end
        File.chmod(0o500, stage)
        File.rename(stage, paths.inputs_dir)
      ensure
        FileUtils.rm_rf(stage) if File.exist?(stage)
      end
      expected
    rescue JSON::ParserError => e
      raise Error, "candidate input manifest is invalid: #{e.message}"
    end

    def missing_for_resume(source)
      effective = source.fetch("effective_gate_set", [])
      by_name = effective.to_h { |entry| [ entry["name"], entry["status"] ] }
      registry.local_defaults.select do |gate|
        status = by_name[gate.name]
        status.nil? || %w[pending running].include?(status)
      end
    end

    def current_attempt(paths)
      return nil unless File.file?(paths.current_path) && !File.symlink?(paths.current_path)

      JSON.parse(File.read(paths.current_path))["attempt_id"]
    rescue JSON::ParserError
      raise Error, "current attempt index is invalid"
    end

    def baseline_cache_plan(sha, paths, inputs)
      baseline = inputs.fetch("baselines")
      unless baseline["status"] == "available"
        return {
          "status" => "unavailable",
          "reason" => baseline.fetch("blocker", "baseline_catalog_unavailable"),
          "assets" => [],
          "fetch_argv" => []
        }
      end
      catalog = repository.baseline_catalog(sha)
      cache_root = File.join(paths.runs_root, "baseline-cache")
      inventory = catalog.package_requirements.flat_map do |requirement|
        tag_root = File.join(cache_root, requirement.fetch("tag"))
        AssetVerifier.new(cache_root: tag_root).inventory(requirement.fetch("descriptors")).map do |item|
          item.merge(
            "row_id" => requirement.fetch("row_id"),
            "role" => requirement.fetch("role"),
            "tag" => requirement.fetch("tag")
          )
        end
      end
      closures = catalog.entries.map { |entry| baseline_closure_plan(catalog, entry, cache_root) }
      missing = inventory.select { |item| item["status"] == "missing" }
      invalid = inventory.select { |item| item["status"] == "invalid" }
      closure_invalid = closures.select { |item| item["status"] == "invalid" }
      closure_missing = closures.select { |item| item["status"] == "missing" }
      attestation = baseline_cache_attestation(catalog, cache_root, inventory, closures)
      status = if invalid.any? || closure_invalid.any? || attestation["status"] == "invalid"
                 "invalid"
               elsif missing.any? || closure_missing.any? || attestation["status"] == "missing"
                 "missing"
               else
                 "available"
               end
      reason = if invalid.any? || closure_invalid.any? || attestation["status"] == "invalid"
                 "baseline_assets_invalid"
               elsif missing.any? || closure_missing.any?
                 "baseline_assets_missing"
               elsif attestation["status"] == "missing"
                 "baseline_cache_authentication_missing"
               end
      {
        "status" => status,
        "reason" => reason,
        "cache_root" => relative_repo_path(cache_root),
        "assets" => inventory,
        "closures" => closures,
        "authentication" => attestation,
        "verified_dependency_closure_sha256" =>
          attestation["status"] == "verified" ?
            attestation.fetch("verified_dependency_closure_sha256") : nil,
        "release_assets_sha256" =>
          attestation["status"] == "verified" ?
            attestation.fetch("release_assets_sha256") : nil,
        "fetch_argv" => [
          *(missing.empty? ? [] : catalog.fetch_argv(cache_root: cache_root, missing: missing)),
          *((closure_missing.empty? && attestation["status"] != "missing") ? [] : [[
            RbConfig.ruby,
            "packaging/release_candidate/materialize_baseline_cache.rb",
            sha,
            cache_root
          ]])
        ],
        "next_action_argv" => status == "available" ? nil : [
          "bin/hive-release-candidate", "dispatch", "--sha", sha
        ]
      }
    rescue Error => e
      {
        "status" => "unavailable",
        "reason" => "baseline_cache_invalid",
        "diagnostic" => e.message,
        "assets" => [],
        "fetch_argv" => []
      }
    end

    def baseline_cache_attestation(catalog, cache_root, inventory, closures)
      path = File.join(cache_root, "attestations", "#{catalog.digest}.json")
      return { "status" => "missing", "path" => relative_repo_path(path) } unless File.exist?(path) || File.symlink?(path)

      stat = File.lstat(path)
      unless stat.file? && !stat.symlink? && stat.nlink == 1 && stat.uid == Process.uid
        raise Error, "baseline cache attestation must be an owned regular file"
      end
      document = JSON.parse(File.binread(path))
      expected_keys = %w[
        baseline_catalog_sha256 release_assets_sha256 rows schema schema_version
        verified_dependency_closure_sha256
      ]
      release_assets_sha256 = Digest::SHA256.hexdigest(JSON.generate(
        inventory.map do |item|
          unless item["status"] == "verified"
            raise Error, "baseline cache attestation cannot cover unverified release assets"
          end
          [
            item.fetch("tag"), item.fetch("filename"),
            item.fetch("sha256"), item.fetch("size")
          ]
        end.sort
      ))
      closure_sha256 = Digest::SHA256.hexdigest(JSON.generate(
        closures.sort_by { |row| row.fetch("row_id") }.map do |row|
          unless row["status"] == "verified"
            raise Error, "baseline cache attestation cannot cover unverified dependency closures"
          end
          row.fetch("sha256")
        end
      ))
      unless document.is_a?(Hash) && document.keys.sort == expected_keys.sort &&
             document["schema"] == "hive-release-candidate-baseline-cache-attestation" &&
             document["schema_version"] == 1 &&
             document["baseline_catalog_sha256"] == catalog.digest &&
             document["rows"] == catalog.entries.map(&:id).sort &&
             document["release_assets_sha256"] == release_assets_sha256 &&
             document["verified_dependency_closure_sha256"] == closure_sha256
        raise Error, "baseline cache attestation identity mismatch"
      end
      {
        "status" => "verified",
        "path" => relative_repo_path(path),
        "sha256" => Digest::SHA256.file(path).hexdigest,
        "release_assets_sha256" => release_assets_sha256,
        "verified_dependency_closure_sha256" => closure_sha256
      }
    rescue Error, JSON::ParserError, Errno::ENOENT, Errno::EACCES => e
      {
        "status" => "invalid",
        "path" => relative_repo_path(path),
        "reason" => "baseline_cache_attestation_invalid",
        "diagnostic" => e.message
      }
    end

    def baseline_closure_plan(catalog, entry, cache_root)
      closure_root = File.join(cache_root, "closures", entry.id)
      lock_paths = {
        "producer" => File.join(closure_root, "producer.Gemfile.lock")
      }
      if entry.dependency_closure["observer_lock"]
        lock_paths["observer"] = File.join(closure_root, "observer.Gemfile.lock")
      end
      manifest_path = File.join(
        closure_root,
        entry.dependency_closure.fetch("offline_cache").fetch("manifest_filename")
      )
      gems_root = File.join(closure_root, "gems")
      required_paths = [ *lock_paths.values, manifest_path, gems_root ]
      missing = required_paths.reject do |path|
        File.exist?(path) || File.symlink?(path)
      end
      unless missing.empty?
        return {
          "row_id" => entry.id,
          "status" => "missing",
          "reason" => "offline_dependency_closure_missing",
          "required_paths" => required_paths.map do |path|
            relative_repo_path(path)
          end
        }
      end
      lock_contents = lock_paths.to_h { |role, path| [ role, File.binread(path) ] }
      manifest_content = File.binread(manifest_path)
      expected_manifest = entry.dependency_closure.fetch("offline_cache").fetch("manifest_sha256")
      unless Digest::SHA256.hexdigest(manifest_content) == expected_manifest
        raise Error, "#{entry.id} reviewed offline cache manifest digest mismatch"
      end
      catalog.verify_dependency_closure!(
        entry,
        lock_contents: lock_contents,
        cache_manifest_content: manifest_content,
        artifact_root: gems_root
      )
      {
        "row_id" => entry.id,
        "status" => "verified",
        "sha256" => Digest::SHA256.hexdigest(
          lock_contents.keys.sort.map do |role|
            Digest::SHA256.hexdigest(lock_contents.fetch(role))
          end.join +
          Digest::SHA256.hexdigest(manifest_content)
        )
      }
    rescue Error, Errno::ENOENT, Errno::EACCES => e
      {
        "row_id" => entry.id,
        "status" => "invalid",
        "reason" => "offline_dependency_closure_invalid",
        "diagnostic" => e.message
      }
    end

    def plan_blockers(candidate_version:, baseline_version:, baseline_cache:)
      blockers = [ "remote_validation_required" ]
      if baseline_version
        candidate = Gem::Version.new(candidate_version)
        baseline = Gem::Version.new(baseline_version)
        blockers << "candidate_not_newer" unless candidate > baseline
      end
      blockers << baseline_cache.fetch("reason") unless baseline_cache["status"] == "available"
      blockers
    rescue ArgumentError
      blockers << "candidate_version_invalid"
      blockers
    end

    def relative_repo_path(path)
      Pathname.new(path).relative_path_from(Pathname.new(repo_root)).to_s
    end
  end
end
