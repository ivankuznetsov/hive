require "test_helper"
require "hive/modules/migration/qualification_scenario_driver"
require "hive/modules/migration/qualification_scenario_evidence_collector"
require "hive/modules/migration/qualification_scenario_input"

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

  def test_marks_process_generation_and_fault_claims_unverified
    with_tmp_dir do |sandbox|
      result = run_driver(sandbox)
      honest = collect(result)
      candidate = mutable(result.observation)
      candidate["fault_checkpoint"] = "during_reconciliation"
      candidate["restart_generation"] = 99
      candidate["pre_fault_durable_state_sha256"] = "f" * 64
      candidate["recovered_durable_state_sha256"] = "e" * 64
      claimed = collect(result, candidate_row: candidate)

      # Terminal stores can prove a recovered terminal lineage. They cannot
      # count externally supervised OS process generations or identify where
      # a previous generation exited; the future LaneRunner orchestration
      # must supply those facts independently.
      assert_equal honest.to_h, claimed.to_h
      assert_equal(
        %w[
          fault_checkpoint pre_fault_durable_state_sha256
          recovered_durable_state_sha256 recovery_trace
          restart_generation
        ],
        claimed.unverified_claims.keys.sort
      )
      %w[
        fault_checkpoint pre_fault_durable_state_sha256
        recovered_durable_state_sha256 recovery_trace
        restart_generation
      ].each do |key|
        refute claimed.to_h.key?(key)
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

  def run_driver(sandbox, operation: "timer_due", faults: [])
    with_env(
      "HIVE_HOME" => File.join(sandbox, "hive-home")
    ) do
      DRIVER.new(
        candidate_source_root: CANDIDATE_SOURCE_ROOT,
        sandbox_root: sandbox,
        project: PROJECT,
        scenario_input:
          scenario_input(operation: operation, faults: faults)
      ).call
    end
  end

  def scenario_input(operation: "timer_due", faults: [])
    case_id = "ordinary-#{operation.tr('_', '-')}"
    INPUT.load(
      Hive::WorkflowPackage::CanonicalYAML.dump(
        "schema" => "hive-patrol-qualification-scenario",
        "schema_version" => 1,
        "case_id" => case_id,
        "module" => "patrol",
        "operation" => operation,
        "clock" => NOW.utc.iso8601(6),
        "faults" => faults,
        "reviewer" => { "findings" => [] }
      ),
      expected_case_id: case_id
    )
  end
end
