# frozen_string_literal: true

require "rubygems"
require_relative "sandbox"

module HiveReleaseCandidate
  class GateExecution
    def initialize(gate_executor: nil, upgrade_executor: nil, sandbox: nil)
      @gate_executor = gate_executor
      @upgrade_executor = upgrade_executor
      @sandbox = sandbox || Sandbox.new
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

    private

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
  end
end
