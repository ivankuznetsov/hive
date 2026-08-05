# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"
require_relative "artifacts"
require_relative "evidence"
require_relative "paths"

module HiveReleaseCandidate
  class LocalAttempt
    def initialize(repo_root:, runs_root:, repository:, registry:, baseline_cache:,
                   gate_execution:)
      @repo_root = repo_root
      @runs_root = runs_root
      @repository = repository
      @registry = registry
      @baseline_cache = baseline_cache
      @gate_execution = gate_execution
    end

    def run(ref:, gates: [])
      sha = @repository.resolve_sha(ref)
      paths = paths_for(sha)
      selected = gates.empty? ? @registry.local_defaults : @registry.select_named(gates)
      operate(paths, selected: selected, selection_mode: "run")
    end

    def resume(ref:, attempt_id:)
      sha = @repository.resolve_sha(ref)
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
      sha = @repository.resolve_sha(ref)
      paths = paths_for(sha)
      paths.with_lock do
        source = Evidence.new(paths: paths).load(attempt_id)
        selected = @registry.rerun(source: source, mode: mode, names: gates)
        operate_locked(
          paths, selected: selected, selection_mode: "rerun_#{mode}", predecessor: source
        )
      end
    end

    def inspect(ref:, attempt_id:)
      sha = @repository.resolve_sha(ref)
      Evidence.new(paths: paths_for(sha)).load(attempt_id)
    end

    def list(ref:)
      sha = @repository.resolve_sha(ref)
      paths = paths_for(sha)
      {
        "schema" => "hive-release-candidate-list",
        "schema_version" => SCHEMA_VERSION,
        "candidate_sha" => sha,
        "current_attempt_id" => current_attempt(paths),
        "attempts" => Evidence.new(paths: paths).list
      }
    end

    private

    def paths_for(sha)
      Paths.new(repo_root: @repo_root, candidate_sha: sha, runs_root: @runs_root)
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
      expected_inputs = @repository.inputs(paths.candidate_sha)
      baseline_cache = @baseline_cache.plan(paths.candidate_sha, paths, expected_inputs)
      paths.prepare!
      artifacts = Artifacts.new(
        repo_root: @repo_root, candidate_sha: paths.candidate_sha,
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
          results << @gate_execution.call(
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
        dirty_checkout: @repository.dirty?,
        started_at: started_at,
        finished_at: Time.now.utc
      )
      raise TemporaryError, "candidate attempt was interrupted: #{document.fetch('attempt_id')}" if interrupted

      document
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
      @registry.local_defaults.select do |gate|
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
  end
end
