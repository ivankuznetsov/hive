# frozen_string_literal: true

require "rubygems"

module HiveReleaseCandidate
  class GateExecution
    def initialize(gate_executor: nil)
      @gate_executor = gate_executor
    end

    def call(gate, artifacts:, inputs:, manifest:, baseline_cache:)
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
  end
end
