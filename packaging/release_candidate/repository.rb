# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require_relative "baseline_catalog"
require_relative "paths"
require_relative "remote_identity"

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
            "packaging/release_candidate/upgrade_survivor/channel_prefix_oracle.rb",
            "packaging/release_candidate/upgrade_survivor/reviewed_channel_updater.rb",
            "packaging/release_candidate/upgrade_survivor/fixed_channel_executor.rb",
            "packaging/release_candidate/upgrade_survivor/state_snapshotter.rb",
            "packaging/release_candidate/upgrade_survivor/fixed_phase_executor.rb",
            "packaging/release_candidate/hosted_upgrade_lane.rb",
            "packaging/release_candidate/aggregate.rb",
            "packaging/release_candidate/retry_selection.rb",
            "packaging/release_candidate/remote_identity.rb",
            "packaging/release_candidate/remote_workflow.rb",
            "packaging/release_candidate/hosted_gate.rb",
            "packaging/release_candidate/verify_hosted_gate.sh",
            "packaging/release_candidate/workflows/validate_dispatch.sh",
            "packaging/release_candidate/workflows/query_evidence.sh",
            "packaging/release_candidate/workflows/collect_evidence.sh",
            "packaging/release_candidate/hosted_stage.rb",
            "packaging/release_candidate/hosted_aggregate.rb",
            "packaging/release_candidate/repository.rb",
            "packaging/release_candidate/local_attempt.rb",
            "packaging/release_candidate/remote_run.rb",
            "packaging/release_candidate/gate_execution.rb",
            "packaging/release_candidate/baseline_cache.rb"
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
end
