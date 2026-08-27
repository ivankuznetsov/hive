# frozen_string_literal: true

require_relative "baseline_catalog"
require_relative "installed_target"
require_relative "invariant_snapshot"
require_relative "process_teardown"
require_relative "upgrade_survivor/channel_prefix_oracle"
require_relative "upgrade_survivor/reviewed_channel_updater"
require_relative "upgrade_survivor/fixed_channel_executor"
require_relative "upgrade_survivor/state_snapshotter"
require_relative "upgrade_survivor/fixed_phase_executor"

module HiveReleaseCandidate
  class UpgradeSurvivor
    PHASES = {
      "latest-stable" => [
        [ "baseline", "before" ],
        [ "candidate", "candidate_transition" ],
        [ "candidate", "after" ],
        [ "candidate", "idempotency" ]
      ],
      "legacy-bench-v041" => [
        [ "baseline", "before" ],
        [ "observer", "observer" ],
        [ "candidate", "candidate_transition" ],
        [ "candidate", "after" ],
        [ "candidate", "idempotency" ]
      ]
    }.freeze
    ALLOWED_MIGRATIONS = {
      "latest-stable" => %w[
        /install_identity
      ],
      "legacy-bench-v041" => %w[
        /builtin_runtime
        /configuration/default_workflow
        /default_workflow
        /doctor_json
        /global_registry
        /install_identity
        /legacy_descriptor
        /legacy_instructions
        /project_registry
      ]
    }.freeze
    OUTPUT_LIMIT = 64 * 1024

    def initialize(catalog:, targets:, run_root:, sandbox_contract:, cache_contract:,
                   candidate_manifest:, phase_executor: nil, channel_executor: nil,
                   process_teardown: nil)
      @catalog = catalog
      @targets = targets.transform_keys(&:to_s)
      @run_root = prepare_run_root!(run_root)
      @sandbox_contract = sandbox_contract
      @cache_contract = cache_contract
      @process_teardown = process_teardown || ProcessTeardown.new
      @candidate_manifest = candidate_manifest
      @phase_executor = phase_executor || FixedPhaseExecutor.new(process_teardown: @process_teardown)
      @channel_executor = channel_executor || FixedChannelExecutor.new(targets: @targets)
    end

    def run(row_id:, platform:)
      entry = @catalog.fetch(row_id)
      unavailable = preflight(entry, platform)
      return unavailable if unavailable

      receipts = execute_phases(entry)
      reasons = validate_phase_receipts(entry, receipts)
      snapshots = snapshot_receipts(entry, receipts, reasons)
      compare_invariants(entry, snapshots, reasons)
      channel = execute_channel(entry, platform, reasons)
      teardown = execute_teardown(receipts, reasons)
      status = reasons.empty? ? "passed" : "failed"
      {
        "schema" => "hive-release-candidate-upgrade-survivor",
        "schema_version" => SCHEMA_VERSION,
        "row_id" => entry.id,
        "platform" => platform,
        "status" => status,
        "reason" => reasons.first,
        "reasons" => reasons.uniq,
        "phases" => receipts,
        "invariants" => snapshots,
        "channel" => channel,
        "teardown" => teardown,
        "trust_scope" => "local",
        "qa_status" => "qa_blocked",
        "blockers" => [ "remote_validation_required" ] + reasons.uniq
      }
    rescue Error => e
      failed(entry&.id || row_id, platform, e.message)
    rescue StandardError => e
      failed(entry&.id || row_id, platform, "upgrade_runner_error", diagnostic: e.message)
    end

    private

    def preflight(entry, platform)
      unless entry.required_platforms.include?(platform)
        return unavailable(entry.id, platform, "baseline_platform_incompatible")
      end
      unless @sandbox_contract.is_a?(Hash) &&
             @sandbox_contract["status"] == "available" &&
             @sandbox_contract["network_after_staging"] == "none"
        return unavailable(entry.id, platform, "disposable_sandbox_unavailable")
      end
      unless @cache_contract.is_a?(Hash) &&
             @cache_contract["status"] == "available" &&
             /\A[0-9a-f]{64}\z/.match?(@cache_contract["release_assets_sha256"].to_s) &&
             /\A[0-9a-f]{64}\z/.match?(@cache_contract["verified_dependency_closure_sha256"].to_s)
        return unavailable(entry.id, platform, "authenticated_baseline_cache_unavailable")
      end
      required_roles = PHASES.fetch(entry.id).map(&:first).uniq
      missing = required_roles.reject { |role| @targets[role].is_a?(InstalledTarget) }
      unless missing.empty?
        reason = missing.include?("observer") ?
          "required_observer_target_unavailable" : "required_installed_target_unavailable"
        return unavailable(entry.id, platform, reason)
      end
      mismatched = required_roles.find { |role| @targets.fetch(role).role != role }
      return unavailable(entry.id, platform, "installed_target_role_mismatch") if mismatched

      producer = entry.packages.fetch("producer")
      baseline = @targets.fetch("baseline")
      unless baseline.manifest["version"] == producer.fetch("version") &&
             baseline.manifest["gem_sha256"] == producer.dig("artifact", "sha256")
        return unavailable(entry.id, platform, "baseline_target_identity_mismatch")
      end
      if entry.packages["observer"]
        observer = @targets.fetch("observer")
        package = entry.packages.fetch("observer")
        unless observer.manifest["version"] == package.fetch("version") &&
               observer.manifest["gem_sha256"] == package.dig("artifact", "sha256")
          return unavailable(entry.id, platform, "observer_target_identity_mismatch")
        end
      end
      candidate = @targets.fetch("candidate")
      candidate_gem = @candidate_manifest.is_a?(Hash) &&
        @candidate_manifest["files"].is_a?(Hash) &&
        @candidate_manifest["files"].values.find { |record| record["kind"] == "gem" }
      unless @candidate_manifest.is_a?(Hash) &&
             SAFE_SHA.match?(@candidate_manifest["candidate_sha"].to_s) &&
             @candidate_manifest["hive_version"] == candidate.manifest["version"] &&
             candidate_gem &&
             candidate_gem["sha256"] == candidate.manifest["gem_sha256"]
        return unavailable(entry.id, platform, "candidate_target_identity_mismatch")
      end
      nil
    end

    def execute_phases(entry)
      PHASES.fetch(entry.id).map do |role, phase|
        target = @targets.fetch(role)
        receipt = @phase_executor.call(
          target: target, phase: phase, row: entry, run_root: @run_root
        )
        normalize_receipt(receipt, role: role, phase: phase)
      rescue StandardError => e
        {
          "role" => role, "phase" => phase, "status" => "failed",
          "reason" => "phase_execution_failed", "diagnostic" => bounded(e.message),
          "stdout" => "", "stderr" => "", "processes" => [], "services" => []
        }
      end
    end

    def normalize_receipt(value, role:, phase:)
      raise Error, "#{phase} phase did not return evidence" unless value.is_a?(Hash)

      value.transform_keys(&:to_s).merge(
        "role" => role, "phase" => phase,
        "stdout" => bounded(value["stdout"].to_s),
        "stderr" => bounded(value["stderr"].to_s),
        "stdout_truncated" => value["stdout"].to_s.bytesize > OUTPUT_LIMIT,
        "stderr_truncated" => value["stderr"].to_s.bytesize > OUTPUT_LIMIT,
        "processes" => Array(value["processes"]),
        "services" => Array(value["services"])
      )
    end

    def validate_phase_receipts(entry, receipts)
      reasons = []
      receipts.each do |receipt|
        expected = receipt["phase"] == "observer" ? "expected_failure_observed" : "passed"
        reasons << (receipt["reason"] || "upgrade_phase_failed") unless receipt["status"] == expected
      end
      producer = receipts.first
      reasons << "fixture_cannot_substitute_for_real_producer" unless producer["producer_kind"] == "real-installed"
      unless producer["target_gem_sha256"] == entry.packages.dig("producer", "artifact", "sha256")
        reasons << "producer_identity_mismatch"
      end
      if entry.id == "legacy-bench-v041"
        observer = receipts.find { |receipt| receipt["phase"] == "observer" }
        unless observer &&
               observer["producer_kind"] == "real-installed" &&
               observer["target_gem_sha256"] == entry.packages.dig("observer", "artifact", "sha256") &&
               observer["reason"] == "legacy_workflow_collision" &&
               observer["observation"] == {
                 "outcome" => "expected_failure",
                 "code" => "workflow_id_collision:bench"
               }
          reasons << "required_broken_intermediate_observation_missing"
        end
        after = receipts.find { |receipt| receipt["phase"] == "after" }
        reasons << "legacy_task_cannot_continue" unless after && after["task_continuation"] == true
      end
      reasons
    end

    def snapshot_receipts(entry, receipts, reasons)
      receipts.to_h do |receipt|
        sections = receipt["snapshot"]
        begin
          [ receipt.fetch("phase"), InvariantSnapshot.build(row_id: entry.id, sections: sections) ]
        rescue Error => e
          reasons << "invalid_#{receipt.fetch('phase')}_snapshot"
          [ receipt.fetch("phase"), { "status" => "invalid", "diagnostic" => bounded(e.message) } ]
        end
      end
    end

    def compare_invariants(entry, snapshots, reasons)
      before = snapshots["before"]
      after = snapshots["after"]
      idempotency = snapshots["idempotency"]
      if valid_snapshot?(before) && valid_snapshot?(after)
        transition = InvariantSnapshot.compare(
          before: before, after: after,
          allowed_migrations: ALLOWED_MIGRATIONS.fetch(entry.id)
        )
        snapshots["transition_diff"] = transition
        reasons << "invariant_mismatch" unless transition["passed"]
      end
      if valid_snapshot?(after) && valid_snapshot?(idempotency)
        repeat = InvariantSnapshot.compare(
          before: after, after: idempotency, allowed_migrations: []
        )
        snapshots["idempotency_diff"] = repeat
        reasons << "second_run_not_idempotent" unless repeat["passed"]
      end
    end

    def execute_channel(entry, platform, reasons)
      candidate = @targets.fetch("candidate")
      receipt = @channel_executor.call(
        row: entry, platform: platform, candidate_target: candidate, run_root: @run_root
      )
      unless receipt.is_a?(Hash)
        reasons << "channel_evidence_missing"
        return { "status" => "failed", "reason" => "channel_evidence_missing" }
      end
      expected_channel = ChannelPrefixOracle::CHANNELS.fetch(platform)
      checks = receipt["status"] == "passed" &&
        receipt["channel"] == expected_channel &&
        receipt["candidate_gem_sha256"] == candidate.manifest.fetch("gem_sha256") &&
        receipt["stale_files"] == [] &&
        receipt["wrapper_role"] == "candidate" &&
        receipt["sidecars_current"] == true &&
        receipt["dependencies_current"] == true
      unless checks
        reasons << receipt["reason"].to_s unless receipt["reason"].to_s.empty?
        reasons << "channel_faithful_update_failed"
      end
      receipt
    rescue StandardError => e
      reasons << "channel_faithful_update_failed"
      { "status" => "failed", "reason" => "channel_faithful_update_failed", "diagnostic" => bounded(e.message) }
    end

    def execute_teardown(receipts, reasons)
      processes = receipts.flat_map { |receipt| receipt.fetch("processes", []) }
      services = receipts.flat_map { |receipt| receipt.fetch("services", []) }
      @process_teardown.verify!(processes: processes, services: services)
    rescue Error => e
      reasons << "upgrade_process_leak"
      { "status" => "failed", "reason" => "upgrade_process_leak", "diagnostic" => bounded(e.message) }
    end

    def valid_snapshot?(value)
      value.is_a?(Hash) && value["schema"] == "hive-release-candidate-invariant-snapshot"
    end

    def prepare_run_root!(value)
      root = File.expand_path(value)
      parent = File.dirname(root)
      parent_stat = File.lstat(parent)
      unless parent_stat.directory? && !parent_stat.symlink? && parent_stat.uid == Process.uid
        raise Error, "upgrade run parent must be an owned directory"
      end
      Dir.mkdir(root, 0o700) unless File.exist?(root) || File.symlink?(root)
      stat = File.lstat(root)
      unless stat.directory? && !stat.symlink? && stat.uid == Process.uid
        raise Error, "upgrade run root must be an owned directory"
      end
      root
    rescue Errno::ENOENT, Errno::EACCES, Errno::EEXIST
      raise Error, "upgrade run root must be an owned directory"
    end

    def unavailable(row_id, platform, reason)
      {
        "schema" => "hive-release-candidate-upgrade-survivor",
        "schema_version" => SCHEMA_VERSION,
        "row_id" => row_id, "platform" => platform,
        "status" => "unavailable", "reason" => reason,
        "reasons" => [ reason ], "phases" => [],
        "trust_scope" => "local", "qa_status" => "qa_blocked",
        "blockers" => [ "remote_validation_required", reason ],
        "next_action_argv" => [
          "bin/hive-release-candidate", "dispatch", "--sha",
          @candidate_manifest.is_a?(Hash) && SAFE_SHA.match?(@candidate_manifest["candidate_sha"].to_s) ?
            @candidate_manifest.fetch("candidate_sha") : "<candidate-sha>"
        ]
      }
    end

    def failed(row_id, platform, reason, diagnostic: nil)
      unavailable(row_id, platform, reason).merge(
        "status" => "failed", "diagnostic" => diagnostic
      )
    end

    def bounded(value)
      string = value.to_s.b.byteslice(0, OUTPUT_LIMIT)
      string.force_encoding(Encoding::UTF_8).scrub
    end
  end
end
