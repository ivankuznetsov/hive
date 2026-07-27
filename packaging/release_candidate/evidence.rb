# frozen_string_literal: true

require "digest"
require "json"
require "rubygems"
require "time"
require_relative "gate_registry"
require_relative "paths"

module HiveReleaseCandidate
  class Evidence
    EVIDENCE_SCHEMA = "hive-release-candidate-evidence"
    GATE_STATUSES = %w[pending running passed failed skipped unavailable].freeze
    SCOPE_STATUSES = %w[passed failed partial unavailable].freeze

    attr_reader :paths

    def initialize(paths:)
      @paths = paths
    end

    def identity(candidate_manifest:, inputs:, baseline_cache:)
      components = {
        "candidate_sha" => paths.candidate_sha,
        "artifact_manifest" => digest_file(candidate_manifest),
        "coverage_catalog" => input_digest(inputs, "coverage"),
        "baseline_catalog" => input_digest(inputs, "baselines"),
        "baseline_dependency_closure" => baseline_dependency_digest(inputs),
        "baseline_cache" => baseline_cache_digest(baseline_cache),
        "action_lock" => input_digest(inputs, "action_lock"),
        "workflow" => input_digest(inputs, "workflow"),
        "tool" => input_digest(inputs, "tool"),
        "schema" => input_digest(inputs, "schema")
      }
      components.merge("fingerprint" => digest_json(components))
    end

    def write_attempt(identity:, selected_gates:, gate_results:, predecessor: nil,
                      selection_mode: "run", rejected_gates: [], interrupted: false,
                      candidate_version:, baseline_version:, dirty_checkout: false,
                      started_at: Time.now.utc, finished_at: Time.now.utc)
      validate_identity!(identity)
      attempt_id = paths.new_attempt_id(now: finished_at)
      directory = paths.attempt_dir(attempt_id)
      begin
        Dir.mkdir(directory, 0o700)
      rescue Errno::EEXIST
        raise Error, "attempt ID collision: #{attempt_id}"
      end

      normalized_results = gate_results.map do |result|
        normalize_gate(result, attempt_id: attempt_id)
      end
      selected_names = selected_gates.map(&:to_s)
      result_names = normalized_results.map { |result| result.fetch("name") }
      unless selected_names.uniq.size == selected_names.size &&
             result_names.uniq.size == result_names.size &&
             selected_names.sort == result_names.sort
        raise Error, "selected gates must correspond exactly to gate results"
      end
      scope_status = scope_status(normalized_results, interrupted: interrupted)
      blockers = [ "remote_validation_required" ]
      if baseline_version && !newer_version?(candidate_version, baseline_version)
        blockers << "candidate_not_newer"
      end
      normalized_results.each do |result|
        next unless %w[failed unavailable skipped].include?(result["status"])
        next if result["reason"].to_s.empty?

        blockers << result["reason"]
      end
      blockers.uniq!
      qa_status = interrupted ? "partial" : "qa_blocked"
      effective = effective_gate_set(predecessor, normalized_results)
      summary = summary_for(normalized_results, effective)
      document = {
        "schema" => EVIDENCE_SCHEMA,
        "schema_version" => SCHEMA_VERSION,
        "candidate_sha" => paths.candidate_sha,
        "attempt_id" => attempt_id,
        "predecessor_attempt_id" => predecessor && predecessor.fetch("attempt_id"),
        "selection" => {
          "mode" => selection_mode,
          "selected_gates" => selected_names,
          "rejected_gates" => rejected_gates.map(&:to_s)
        },
        "identity" => identity,
        "trust_scope" => "local",
        "scope_status" => scope_status,
        "qa_status" => qa_status,
        "blockers" => blockers,
        "candidate_version" => candidate_version,
        "baseline_version" => baseline_version,
        "dirty_checkout" => dirty_checkout,
        "started_at" => started_at.utc.iso8601,
        "finished_at" => finished_at.utc.iso8601,
        "gates" => normalized_results,
        "effective_gate_set" => effective,
        "gate_registry" => GateRegistry.new.payload,
        "artifacts" => artifact_records,
        "coverage_selection" => coverage_input,
        "baseline_catalog" => baseline_input,
        "environment" => {
          "ruby" => RUBY_VERSION,
          "platform" => RUBY_PLATFORM
        },
        "trusted_remote" => nil,
        "summary" => summary,
        "next_action" => {
          "kind" => "remote_validation_required",
          "argv" => [ "bin/hive-release-candidate", "dispatch", "--sha", paths.candidate_sha ]
        }
      }
      paths.atomic_json(File.join(directory, "evidence.json"), document)
      paths.atomic_write(File.join(directory, "summary.md"), render_summary(document))
      paths.immutable_tree!(directory)
      paths.atomic_json(
        paths.current_path,
        {
          "schema" => "hive-release-candidate-current",
          "schema_version" => SCHEMA_VERSION,
          "candidate_sha" => paths.candidate_sha,
          "attempt_id" => attempt_id,
          "evidence" => paths.relative(paths.evidence_path(attempt_id))
        }
      )
      document
    rescue StandardError
      FileUtils.rm_rf(directory) if directory && File.directory?(directory)
      raise
    end

    def load(attempt_id)
      attempt_id = current_attempt_id if attempt_id.to_s == "current"
      path = paths.evidence_path(attempt_id)
      unless File.file?(path) && !File.symlink?(path)
        raise UnavailableError, "attempt evidence does not exist: #{attempt_id}"
      end
      document = JSON.parse(File.read(path))
      unless document.is_a?(Hash) &&
             document["schema"] == EVIDENCE_SCHEMA &&
             document["schema_version"] == SCHEMA_VERSION &&
             document["candidate_sha"] == paths.candidate_sha &&
             document["attempt_id"] == attempt_id
        raise Error, "attempt evidence identity is invalid: #{attempt_id}"
      end
      document
    rescue JSON::ParserError => e
      raise Error, "attempt evidence is invalid: #{e.message}"
    end

    def list
      return [] unless File.directory?(paths.attempts_dir) && !File.symlink?(paths.attempts_dir)

      current = current_attempt_id(required: false)
      Dir.children(paths.attempts_dir).sort.filter_map do |name|
        next unless SAFE_ATTEMPT.match?(name)

        document = load(name)
        {
          "attempt_id" => name,
          "current" => name == current,
          "scope_status" => document.fetch("scope_status"),
          "qa_status" => document.fetch("qa_status"),
          "blockers" => document.fetch("blockers"),
          "inspect_argv" => [
            "bin/hive-release-candidate", "inspect", "--sha", paths.candidate_sha,
            "--attempt", name
          ]
        }
      end
    end

    def verify_resume_identity!(source, current_identity)
      unless source.fetch("identity") == current_identity
        raise Error, "stale candidate evidence identity; start a new candidate evidence universe"
      end
      true
    end

    def render_summary(document)
      summary = document.fetch("summary")
      <<~MARKDOWN
        # Hive release candidate #{document.fetch("candidate_sha")}

        Attempt: #{document.fetch("attempt_id")}
        Trust: #{document.fetch("trust_scope")}
        Requested scope: #{document.fetch("scope_status")}
        QA: #{document.fetch("qa_status")}
        Gates: #{summary.fetch("passed")} passed, #{summary.fetch("failed")} failed, #{summary.fetch("unavailable")} unavailable
        Blockers: #{document.fetch("blockers").join(", ")}
      MARKDOWN
    end

    private

    def normalize_gate(result, attempt_id:)
      name = result.fetch("name").to_s
      gate = GateRegistry.new.fetch(name)
      status = result.fetch("status").to_s
      raise Error, "invalid gate status #{status.inspect}" unless GATE_STATUSES.include?(status)

      {
        "name" => name,
        "class" => gate.gate_class,
        "status" => status,
        "attempt_id" => attempt_id,
        "reason" => result["reason"],
        "evidence_path" => result["evidence_path"],
        "details" => result["details"]
      }
    end

    def scope_status(results, interrupted:)
      return "partial" if interrupted || results.any? { |result| %w[pending running].include?(result["status"]) }
      return "failed" if results.any? { |result| result["status"] == "failed" }
      return "unavailable" if results.empty? || results.any? { |result| %w[skipped unavailable].include?(result["status"]) }

      "passed"
    end

    def effective_gate_set(predecessor, current)
      references = predecessor ? predecessor.fetch("effective_gate_set", []).map(&:dup) : []
      current.each do |gate|
        references.reject! { |reference| reference["name"] == gate["name"] }
        references << {
          "name" => gate["name"],
          "attempt_id" => gate["attempt_id"],
          "status" => gate["status"]
        }
      end
      references.sort_by { |reference| reference["name"] }
    end

    def summary_for(current, effective)
      statuses = effective.map { |reference| reference.fetch("status") }
      {
        "requested" => current.size,
        "effective" => effective.size,
        "passed" => statuses.count("passed"),
        "failed" => statuses.count("failed"),
        "unavailable" => statuses.count { |status| %w[skipped unavailable].include?(status) },
        "partial" => statuses.count { |status| %w[pending running].include?(status) }
      }
    end

    def current_attempt_id(required: true)
      unless File.file?(paths.current_path) && !File.symlink?(paths.current_path)
        raise UnavailableError, "candidate has no current attempt" if required
        return nil
      end
      payload = JSON.parse(File.read(paths.current_path))
      payload.fetch("attempt_id")
    rescue JSON::ParserError, KeyError => e
      raise Error, "current attempt index is invalid: #{e.message}"
    end

    def input_digest(inputs, name)
      record = inputs.fetch(name)
      digest = record.fetch("sha256")
      raise Error, "invalid #{name} input digest" unless /\A[0-9a-f]{64}\z/.match?(digest)

      digest
    end

    def baseline_dependency_digest(inputs)
      digest = inputs.fetch("baselines").fetch("catalog_dependency_closure_sha256")
      unless /\A[0-9a-f]{64}\z/.match?(digest)
        raise Error, "invalid baseline dependency closure input digest"
      end

      digest
    end

    def baseline_cache_digest(cache)
      identity = cache.slice(
        "status", "release_assets_sha256", "verified_dependency_closure_sha256"
      )
      required = %w[release_assets_sha256 status verified_dependency_closure_sha256]
      unless identity.keys.sort == required &&
             identity["status"].is_a?(String) &&
             %w[available invalid missing unavailable].include?(identity["status"]) &&
             %w[release_assets_sha256 verified_dependency_closure_sha256].all? do |key|
               identity[key].nil? || /\A[0-9a-f]{64}\z/.match?(identity[key])
             end
        raise Error, "invalid authenticated baseline cache identity"
      end
      digest_json(identity)
    end

    def validate_identity!(identity)
      expected = digest_json(identity.reject { |key, _value| key == "fingerprint" })
      raise Error, "candidate evidence fingerprint is invalid" unless identity["fingerprint"] == expected
    end

    def digest_file(path)
      unless File.file?(path) && !File.symlink?(path)
        raise Error, "identity input is missing or unsafe: #{path}"
      end
      Digest::SHA256.file(path).hexdigest
    end

    def digest_json(value)
      Digest::SHA256.hexdigest(JSON.generate(deep_sort(value)))
    end

    def deep_sort(value)
      case value
      when Hash
        value.keys.sort.to_h { |key| [ key, deep_sort(value.fetch(key)) ] }
      when Array
        value.map { |entry| deep_sort(entry) }
      else
        value
      end
    end

    def artifact_records
      manifest = JSON.parse(File.read(paths.manifest_path))
      manifest.fetch("files").map do |name, record|
        record.merge("path" => paths.relative(File.join(paths.candidate_dir, name)))
      end.sort_by { |record| record.fetch("path") }
    end

    def coverage_input
      read_input("coverage")
    end

    def baseline_input
      read_input("baselines")
    end

    def read_input(name)
      path = File.join(paths.inputs_dir, "#{name}.json")
      JSON.parse(File.read(path))
    rescue Errno::ENOENT, JSON::ParserError => e
      raise Error, "cannot read #{name} input manifest: #{e.message}"
    end

    def newer_version?(candidate, baseline)
      Gem::Version.new(candidate) > Gem::Version.new(baseline)
    rescue ArgumentError, TypeError
      false
    end
  end
end
