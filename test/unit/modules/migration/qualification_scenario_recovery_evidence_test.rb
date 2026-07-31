require "test_helper"
require "hive/modules/migration/qualification_scenario_evidence_collector"
require "hive/modules/migration/qualification_scenario_input"
require "hive/modules/migration/qualification_scenario_orchestrator"
require "hive/modules/migration/qualification_scenario_recovery_evidence"
require "hive/workflow_package/canonical_yaml"
require_relative "../../../support/qualification_run_fixture"

class ModulesMigrationQualificationScenarioRecoveryEvidenceTest <
    Minitest::Test
  include QualificationRunFixture

  BUILDER =
    Hive::Modules::Migration::QualificationScenarioRecoveryEvidence
  COLLECTOR =
    Hive::Modules::Migration::QualificationScenarioEvidenceCollector
  INPUT =
    Hive::Modules::Migration::QualificationScenarioInput
  ORCHESTRATOR =
    Hive::Modules::Migration::QualificationScenarioOrchestrator
  Snapshot = Data.define(:sha256)
  Checkpoint = Data.define(:checkpoint, :facts, :state_sha256)
  Generation =
    Data.define(:after_snapshot, :checkpoint_evidence, :receipt)

  def test_builds_public_fault_fields_only_from_host_generations
    context = fixture_context
    result = process_result(
      recovery_plan: "after_legacy_capture",
      generations: [
        generation(
          "1" * 64,
          checkpoint: "after_legacy_capture",
          attempt_count: 0,
          decision_count: 0
        ),
        generation("2" * 64)
      ]
    )

    projection = BUILDER.new.call(
      result: result,
      scenario_input: scenario_input(
        operation: "ordinary_positive_fixture",
        faults: [ "after_legacy_capture" ]
      ),
      candidate_row: context.fetch(:candidate),
      terminal_evidence: context.fetch(:terminal)
    )

    assert_equal "after_legacy_capture",
                 projection.fields.fetch("fault_checkpoint")
    assert_equal "1" * 64,
                 projection.fields.fetch(
                   "pre_fault_durable_state_sha256"
                 )
    assert_equal "2" * 64,
                 projection.fields.fetch(
                   "recovered_durable_state_sha256"
                 )
    assert_equal 2,
                 projection.fields.fetch("restart_generation")
    assert_equal(
      %w[legacy_capture legacy_recovery],
      projection.fields.fetch("recovery_trace").map do |row|
        row.fetch("phase")
      end
    )
    assert_equal result.sha256, projection.process_result_sha256
  end

  def test_builds_reconciliation_failure_as_a_host_plan_not_a_public_fault
    context = fixture_context
    result = process_result(
      recovery_plan: "reconciliation_failure",
      generations: [
        generation(
          "3" * 64,
          checkpoint: "before_effect_settlement",
          attempt_count: 0,
          decision_count: 0
        ),
        generation(
          "4" * 64,
          checkpoint: "reconciliation_failure",
          attempt_count: 0,
          decision_count: 0
        ),
        generation("5" * 64)
      ]
    )

    projection = BUILDER.new.call(
      result: result,
      scenario_input: scenario_input(
        operation: "reconciliation_failure",
        faults: []
      ),
      candidate_row: context.fetch(:candidate),
      terminal_evidence: context.fetch(:terminal)
    )

    assert_nil projection.fields.fetch("fault_checkpoint")
    assert_equal 3,
                 projection.fields.fetch("restart_generation")
    assert_equal "3" * 64,
                 projection.fields.fetch(
                   "pre_fault_durable_state_sha256"
                 )
    assert_equal(
      %w[
        effect_dispatch_uncertain reconciliation_failure effect_recovery
      ],
      projection.fields.fetch("recovery_trace").map do |row|
        row.fetch("phase")
      end
    )
  end

  def test_rejects_a_process_plan_that_does_not_match_the_scenario
    context = fixture_context
    result = process_result(
      recovery_plan: nil,
      generations: [ generation("6" * 64) ]
    )

    error = assert_raises(Hive::ConfigError) do
      BUILDER.new.call(
        result: result,
        scenario_input: scenario_input(
          operation: "ordinary_positive_fixture",
          faults: [ "after_legacy_capture" ]
        ),
        candidate_row: context.fetch(:candidate),
        terminal_evidence: context.fetch(:terminal)
      )
    end
    assert_equal BUILDER::ERROR, error.message
  end

  private

  def fixture_context
    fixture = qualification_run_fixture
    observations = qualification_scenario_observations(
      fixture,
      lane: "deterministic"
    )
    candidate =
      qualification_candidate_actuals(observations)
        .actuals.fetch(0)
    {
      candidate: candidate,
      terminal: COLLECTOR::Projection.new(
        case_id: "patrol-case",
        module_name: "patrol",
        event: {},
        decisions: [],
        attempts: [],
        comparator_record: {},
        capture: {},
        receipts: [],
        bindings: {},
        effect_index: {},
        terminal_effects: [],
        product_state: {},
        unverified_claims: {}
      ).freeze
    }.freeze
  end

  def scenario_input(operation:, faults:)
    INPUT.load(
      Hive::WorkflowPackage::CanonicalYAML.dump(
        "schema" => INPUT::SCHEMA,
        "schema_version" => INPUT::SCHEMA_VERSION,
        "case_id" => "patrol-case",
        "module" => "patrol",
        "operation" => operation,
        "clock" => "2026-07-31T12:34:56.123456Z",
        "faults" => faults,
        "reviewer" => { "findings" => [] }
      ),
      expected_case_id: "patrol-case"
    )
  end

  def process_result(recovery_plan:, generations:)
    ORCHESTRATOR::Result.new(
      payload: {
        "case_id" => "patrol-case",
        "recovery_plan" => recovery_plan,
        "generation_count" => generations.length,
        "restart_count" => generations.length - 1,
        "final_output_sha256" => "e" * 64,
        "result_sha256" => "f" * 64
      }.freeze,
      generations: generations
    )
  end

  def generation(
    digest,
    checkpoint: nil,
    attempt_count: nil,
    decision_count: nil
  )
    evidence =
      if checkpoint
        Checkpoint.new(
          checkpoint: checkpoint,
          facts: {
            "attempt_count" => attempt_count,
            "decision_count" => decision_count
          }.freeze,
          state_sha256: digest
        ).freeze
      end
    Generation.new(
      after_snapshot: Snapshot.new(sha256: digest).freeze,
      checkpoint_evidence: evidence,
      receipt: nil
    ).freeze
  end
end
