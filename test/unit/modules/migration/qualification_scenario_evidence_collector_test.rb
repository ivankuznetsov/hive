require "test_helper"
require "hive/modules/migration/qualification_scenario_driver"
require "hive/modules/migration/qualification_scenario_evidence_collector"
require "hive/modules/migration/qualification_scenario_input"
require "hive/modules/migration/qualification_target_inventory"

class QualificationScenarioEvidenceCollectorTest < Minitest::Test
  include HiveTestHelper

  COLLECTOR =
    Hive::Modules::Migration::QualificationScenarioEvidenceCollector
  DRIVER = Hive::Modules::Migration::QualificationScenarioDriver
  INPUT = Hive::Modules::Migration::QualificationScenarioInput
  NOW = Time.utc(2026, 7, 31, 12, 34, 56, 123_456)
  PROJECT = {
    "project_id" => "11111111-1111-4111-8111-111111111111",
    "name" => "qualification-demo",
    "repository" => "github.com/example/qualification-demo"
  }.freeze
  CANDIDATE_SOURCE_ROOT =
    File.expand_path("../../../..", __dir__).freeze

  def test_collects_immutable_host_evidence_from_raw_stores
    with_tmp_dir do |sandbox|
      result = run_driver(sandbox)
      evidence = collect(result)

      assert_instance_of COLLECTOR::Projection, evidence
      assert_equal result.observation.fetch("case_id"),
                   evidence.case_id
      assert_equal result.observation.fetch("event_id"),
                   evidence.bindings.fetch("event_id")
      assert_equal result.observation.fetch("decision_id"),
                   evidence.bindings.fetch("comparator_decision_id")
      assert_equal 7, evidence.decisions.length
      assert_equal(
        result.observation.fetch("decisions").map do |decision|
          decision.fetch("decision_id")
        end,
        evidence.bindings.fetch("candidate_decision_ids")
      )
      assert_equal result.observation.fetch("legacy_capture_id"),
                   evidence.bindings.fetch("capture_id")
      assert_equal(
        result.observation.fetch("attempts").map do |attempt|
          attempt.fetch("attempt_id")
        end,
        evidence.bindings.fetch("attempt_ids")
      )
      assert_equal 0,
                   evidence.terminal_effects.fetch(
                     "pending_effect_count"
                   )
      assert_equal 0,
                   evidence.terminal_effects.fetch(
                     "pending_outbox_count"
                   )
      assert_empty evidence.effect_index.fetch("duplicate_keys")
      assert_equal "retired_fence",
                   evidence.terminal_effects.fetch(
                     "occurrence_proof"
                   )
      assert evidence.frozen?
      assert evidence.to_h.frozen?
      assert evidence.receipts.all?(&:frozen?)
    end
  end

  def test_collection_does_not_mutate_candidate_bytes_or_metadata
    with_tmp_dir do |sandbox|
      result = run_driver(sandbox)
      events = File.join(
        result.hive_state_path,
        "module-runtime",
        "events"
      )
      File.chmod(0o750, events)
      inventory =
        Hive::Modules::Migration::QualificationTargetInventory.new
      before = inventory.call(sandbox)

      collect(result)

      after = inventory.call(sandbox)
      assert_equal before.digest, after.digest
      assert_equal before.entries, after.entries
      assert_equal 0o750, File.stat(events).mode & 0o777
    end
  end

  def test_accepts_dot_and_underscore_from_the_shared_case_id_contract
    with_tmp_dir do |sandbox|
      result = run_driver(sandbox)
      candidate = mutable(result.observation)
      candidate["case_id"] = "case.one_case"

      evidence = collect(result, candidate_row: candidate)

      assert_equal "case.one_case", evidence.case_id
    end
  end

  def test_rejects_candidate_process_claims_and_marks_terminal_store_limits
    with_tmp_dir do |sandbox|
      result = run_driver(sandbox)
      honest = collect(result)

      # Terminal stores can prove a recovered terminal lineage. They cannot
      # count externally supervised OS process generations or identify a
      # previous exit point. LaneRunner supplies those facts independently,
      # while candidate Actuals reject the fields altogether.
      {
        "fault_checkpoint" => "during_reconciliation",
        "restart_generation" => 99,
        "pre_fault_durable_state_sha256" => "f" * 64,
        "recovered_durable_state_sha256" => "e" * 64,
        "recovery_trace" => []
      }.each do |key, value|
        candidate = mutable(result.observation)
        candidate[key] = value
        assert_rejected do
          collect(result, candidate_row: candidate)
        end
      end
      assert_equal(
        %w[
          fault_checkpoint pre_fault_durable_state_sha256
          recovered_durable_state_sha256 recovery_trace
          restart_generation
        ],
        honest.unverified_claims.keys.sort
      )
      %w[
        fault_checkpoint pre_fault_durable_state_sha256
        recovered_durable_state_sha256 recovery_trace
        restart_generation
      ].each do |key|
        refute honest.to_h.key?(key)
      end
    end
  end

  def test_collects_a_terminal_case_without_effects
    with_tmp_dir do |sandbox|
      result = run_driver(
        sandbox,
        operation: "timer_not_due"
      )
      evidence = collect(result)

      assert_empty evidence.receipts
      assert_empty evidence.bindings.fetch("intent_ids")
      assert_empty evidence.bindings.fetch("receipt_ids")
      assert_equal 0,
                   evidence.terminal_effects.fetch(
                     "effect_count"
                   )
      assert_equal 0,
                   evidence.terminal_effects.fetch(
                     "pending_effect_count"
                   )
    end
  end

  def test_collects_architecture_job_manifest_and_retirement_evidence
    with_tmp_dir do |sandbox|
      result = run_driver(
        sandbox,
        module_name: "architecture-patrol",
        operation: "architecture_positive_fixture",
        findings: [ architecture_thesis ]
      )
      evidence = collect(result)
      product = evidence.product_state

      assert_equal "architecture-patrol", evidence.module_name
      assert_equal "architecture_patrol_v3_job",
                   product.fetch("type")
      assert_equal evidence.capture.dig("outcome", "job_id"),
                   product.fetch("job_id")
      assert product.dig("job", "complete")
      assert_equal "complete", product.dig("job", "state")
      assert_equal 1, product.dig("job", "actions").length
      assert_equal product.fetch("job_id"),
                   product.dig("manifest", "job_id")
      assert_equal result.observation.fetch("repository_sha"),
                   product.dig("manifest", "source", "merge_sha")
      assert_equal(
        evidence.receipts.map do |receipt|
          receipt.fetch("intent").fetch("intent_id")
        end.sort,
        product.fetch("transition_intent_ids")
      )
      assert product.fetch("occurrence_retired")
      assert_equal "retired_fence",
                   evidence.terminal_effects.fetch(
                     "occurrence_proof"
                   )
      assert_equal(
        %w[actions],
        evidence.bindings
          .fetch("candidate_decision_ids")
          .map do |decision_id|
            evidence.decisions
              .find do |decision|
                decision.fetch("decision_id") == decision_id
              end
              .fetch("hook")
          end
      )
    end
  end

  def test_rejects_tampered_architecture_job_and_manifest
    with_tmp_dir do |sandbox|
      result = run_driver(
        File.join(sandbox, "source"),
        module_name: "architecture-patrol",
        operation: "architecture_positive_fixture",
        findings: [ architecture_thesis ]
      )

      assert_copy_rejected(sandbox, result, "tampered-job") do |copy|
        path = Dir.glob(
          File.join(
            copy, "hive-state", "refactor_patrol",
            "v3", "jobs", "*.json"
          )
        ).fetch(0)
        job = JSON.parse(File.binread(path))
        job["complete"] = false
        File.binwrite(path, canonical(job))
      end
      assert_copy_rejected(
        sandbox, result, "tampered-manifest"
      ) do |copy|
        path = Dir.glob(
          File.join(
            copy, "hive-state", "refactor_patrol",
            "v2", "manifests", "*.json"
          )
        ).fetch(0)
        manifest = JSON.parse(File.binread(path))
        manifest["manifest_checksum"] = "f" * 64
        File.binwrite(path, JSON.pretty_generate(manifest))
      end
      assert_copy_rejected(
        sandbox, result, "tampered-event-envelope"
      ) do |copy|
        events = File.join(
          copy, "hive-state", "module-runtime", "events"
        )
        event_path =
          Dir.glob(File.join(events, "evt-*.json")).fetch(0)
        event = JSON.parse(File.binread(event_path))
        event.fetch("payload")["schedule"] = "*/11 * * * *"
        File.binwrite(event_path, canonical(event))
        index_path = File.join(events, "index.json")
        index = JSON.parse(File.binread(index_path))
        index["latest_schedules"] = {
          "architecture-patrol\0*/11 * * * *" =>
            event.fetch("occurred_at")
        }
        File.binwrite(index_path, canonical(index))
      end
      assert_copy_rejected(
        sandbox, result, "tampered-retirement-generation"
      ) do |copy|
        records = File.join(
          copy, "hive-state", "refactor_patrol",
          "v3", "occurrences", "records"
        )
        state_path = File.join(
          records, "journal-state.json"
        )
        state = JSON.parse(File.binread(state_path))
        state["recovery_inventory_generation"] = 3
        File.binwrite(state_path, canonical(state))
        index_path = File.join(
          records, "recovery-index.json"
        )
        index = JSON.parse(File.binread(index_path))
        index["generation"] = 3
        File.binwrite(index_path, canonical(index))
      end
    end
  end

  def test_collects_architecture_clean_negative_product_state
    with_tmp_dir do |sandbox|
      result = run_driver(
        sandbox,
        module_name: "architecture-patrol",
        operation: "architecture_positive_fixture"
      )
      evidence = collect(result)

      assert_equal "architecture-patrol", evidence.module_name
      assert_equal "scheduled-discovery",
                   evidence.event.dig(
                     "payload", "target_hook"
                   )
      assert_equal "no_theses",
                   evidence.product_state.dig(
                     "job", "zero_reason"
                   )
      assert_empty evidence.product_state.dig(
        "job", "actions"
      )
      assert evidence.product_state.fetch(
        "occurrence_retired"
      )
    end
  end

  def test_rejects_candidate_digest_without_matching_raw_evidence
    with_tmp_dir do |sandbox|
      result = run_driver(sandbox)
      candidate = mutable(result.observation)
      candidate["comparator_semantic_digest"] = "f" * 64

      assert_rejected do
        collect(result, candidate_row: candidate)
      end
    end
  end

  def test_binds_recovered_attempt_lineage_without_claiming_restart_proof
    skip "POSIX fork unavailable" unless Process.respond_to?(:fork)

    with_tmp_dir do |sandbox|
      result = run_driver(
        sandbox,
        faults: [ "after_module_decision" ]
      )
      evidence = collect(result)

      assert_equal %w[lost terminal],
                   evidence.attempts.map { |attempt|
                     attempt.fetch("state")
                   }
      assert_equal(
        result.observation.fetch("attempts").map do |attempt|
          attempt.fetch("attempt_id")
        end,
        evidence.bindings.fetch("attempt_ids")
      )
      assert evidence.unverified_claims.key?(
        "restart_generation"
      )
      refute evidence.to_h.key?("fault_checkpoint")
    end
  end

  def test_binds_effect_recovery_receipts_to_the_retired_occurrence
    skip "POSIX fork unavailable" unless Process.respond_to?(:fork)

    %w[after_effect_intent during_reconciliation].each do |fault|
      with_tmp_dir do |sandbox|
        result = run_driver(sandbox, faults: [ fault ])
        evidence = collect(result)

        assert_equal result.observation.fetch("legacy_capture_id"),
                     evidence.bindings.fetch("capture_id"),
                     fault
        assert_equal evidence.capture.fetch("effect_ids").sort,
                     evidence.bindings.fetch("receipt_ids"),
                     fault
        assert_equal 0,
                     evidence.terminal_effects.fetch(
                       "pending_effect_count"
                     ),
                     fault
        assert_empty evidence.effect_index.fetch("duplicate_keys"),
                     fault
      end
    end
  end

  def test_rejects_missing_extra_foreign_and_tampered_raw_records
    with_tmp_dir do |sandbox|
      result = run_driver(File.join(sandbox, "source"))

      assert_copy_rejected(sandbox, result, "missing-event") do |copy|
        FileUtils.rm_f(Dir.glob(
          File.join(copy, "hive-state", "module-runtime",
                    "events", "evt-*.json")
        ).fetch(0))
      end
      assert_copy_rejected(sandbox, result, "foreign-event") do |copy|
        ledger = Hive::Modules::EventLedger.new(
          root: File.join(copy, "hive-state", "module-runtime")
        )
        ledger.record(
          project_id: "22222222-2222-4222-8222-222222222222",
          project: "foreign",
          event_name: "schedule",
          occurred_at: NOW,
          source: { "type" => "schedule", "id" => "foreign" },
          idempotency_key: "foreign",
          payload: {
            "schedule" => "*/10 * * * *",
            "target_module" => "patrol"
          },
          recorded_at: NOW
        )
      end
      assert_copy_rejected(sandbox, result, "extra-attempt") do |copy|
        records = File.join(
          copy, "hive-home", "attempts", "v2", "records"
        )
        source = Dir.glob(File.join(records, "*.json")).fetch(0)
        FileUtils.cp(source, File.join(records, "foreign.json"))
      end
      assert_copy_rejected(sandbox, result, "tampered-decision") do |copy|
        path = relevant_decision_path(copy)
        decision = JSON.parse(File.binread(path))
        decision["reason"] = "disabled"
        File.binwrite(path, canonical(decision))
      end
      assert_copy_rejected(sandbox, result, "missing-receipt") do |copy|
        FileUtils.rm_f(Dir.glob(
          File.join(copy, "hive-state", "module-runtime",
                    "migration", "patrol-evidence",
                    "receipts", "receipt-*.json")
        ).fetch(0))
      end
    end
  end

  def test_rejects_terminal_state_without_exact_retirement_proof
    with_tmp_dir do |sandbox|
      result = run_driver(File.join(sandbox, "source"))

      assert_copy_rejected(sandbox, result, "open-fence") do |copy|
        path = File.join(
          copy, "hive-state", "patrol", "occurrences",
          "journal-state.json"
        )
        state = JSON.parse(File.binread(path))
        state.fetch("sequence_high_waters").fetch(0)["closed"] = false
        File.binwrite(path, canonical(state))
      end
    end
  end

  private

  def collect(result, candidate_row: result.observation,
              sandbox_root: File.dirname(result.hive_state_path))
    COLLECTOR.new.call(
      case_id: candidate_row.fetch("case_id"),
      sandbox_root: sandbox_root,
      candidate_row: candidate_row
    )
  end

  def assert_copy_rejected(parent, result, name)
    source = File.dirname(result.hive_state_path)
    copy = File.join(parent, name)
    FileUtils.cp_r(source, copy)
    yield copy

    assert_rejected do
      collect(
        result,
        candidate_row: result.observation,
        sandbox_root: copy
      )
    end
  end

  def assert_rejected(&block)
    error = assert_raises(Hive::ConfigError, &block)
    assert_equal "patrol qualification host evidence is malformed",
                 error.message
  end

  def relevant_decision_path(sandbox)
    paths = Dir.glob(
      File.join(
        sandbox, "hive-state", "module-runtime",
        "decisions", "dec-*.json"
      )
    )
    paths.find do |path|
      decision = JSON.parse(File.binread(path))
      decision["module"] == "patrol" &&
        decision["hook"] == "scheduled-scan"
    end || raise("relevant decision is unavailable")
  end

  def mutable(value)
    JSON.parse(JSON.generate(value))
  end

  def canonical(value)
    Hive::WorkflowPackage::CanonicalJSON.generate(value)
  end

  def run_driver(
    sandbox,
    module_name: "patrol",
    operation: "timer_due",
    findings: [],
    faults: []
  )
    generation_plan =
      if faults.one?
        DRIVER::GENERATION_PLANS.fetch(faults.fetch(0))
      else
        [ nil ]
      end
    with_env(
      "HIVE_HOME" => File.join(sandbox, "hive-home")
    ) do
      generation_plan.each_with_index do |stop_after, offset|
        generation = offset + 1
        if stop_after
          run_stopping_generation!(
            sandbox,
            generation: generation,
            stop_after: stop_after,
            module_name: module_name,
            operation: operation,
            findings: findings,
            faults: faults
          )
          next
        end

        return driver(
          sandbox,
          generation: generation,
          stop_after: nil,
          module_name: module_name,
          operation: operation,
          findings: findings,
          faults: faults
        ).call
      end
    end
    raise "qualification generation plan did not finish"
  end

  def driver(
    sandbox,
    generation:,
    stop_after:,
    module_name:,
    operation:,
    findings:,
    faults:
  )
    DRIVER.new(
      candidate_source_root: CANDIDATE_SOURCE_ROOT,
      sandbox_root: sandbox,
      project: PROJECT,
      generation: generation,
      stop_after: stop_after,
      scenario_input:
        scenario_input(
          module_name: module_name,
          operation: operation,
          findings: findings,
          faults: faults
        )
    )
  end

  def run_stopping_generation!(
    sandbox,
    generation:,
    stop_after:,
    module_name:,
    operation:,
    findings:,
    faults:
  )
    pid = fork do
      driver(
        sandbox,
        generation: generation,
        stop_after: stop_after,
        module_name: module_name,
        operation: operation,
        findings: findings,
        faults: faults
      ).call
      Process.exit!(71)
    rescue StandardError
      Process.exit!(70)
    end
    _pid, status = Process.wait2(pid)
    assert status.exited?, stop_after
    assert_equal 76, status.exitstatus, stop_after
  ensure
    if pid
      begin
        Process.kill("KILL", pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
  end

  def scenario_input(
    module_name: "patrol",
    operation: "timer_due",
    findings: [],
    faults: []
  )
    prefix =
      module_name == "patrol" ?
        "ordinary" : "architecture"
    case_id = "#{prefix}-#{operation.tr('_', '-')}"
    INPUT.load(
      Hive::WorkflowPackage::CanonicalYAML.dump(
        "schema" => "hive-patrol-qualification-scenario",
        "schema_version" => 1,
        "case_id" => case_id,
        "module" => module_name,
        "operation" => operation,
        "clock" => NOW.utc.iso8601(6),
        "faults" => faults,
        "reviewer" => { "findings" => findings }
      ),
      expected_case_id: case_id
    )
  end

  def architecture_thesis
    {
      "feature" => "Checkout",
      "problem" =>
        "Checkout mixes validation and payment orchestration",
      "cost" =>
        "Frequent changes touch the same file and its callers",
      "evidence" => [
        {
          "file" => "lib/checkout.rb",
          "line" => 12,
          "snippet" => "def charge_and_validate",
          "claim" =>
            "validation and payment orchestration share one method"
        }
      ],
      "proposed_refactor" =>
        "Extract payment orchestration behind a checkout boundary",
      "expected_leverage" => {
        "drivers" => [
          {
            "signal" => "churn",
            "relief" => 1,
            "mechanism" =>
              "isolate payment edits from validation code"
          }
        ]
      },
      "confidence" => "medium",
      "risk" => {
        "caps" => { "single_feature" => true },
        "public_api_impact" => false,
        "public_api_details" => [],
        "cross_feature_impact" => false,
        "cross_feature_details" => [],
        "flags" => []
      },
      "required_validation" => {
        "commands" => [ "test" ],
        "characterization_first" => false,
        "notes" => "Run checkout tests"
      },
      "follow_up_approval_state" => "pending"
    }
  end
end
