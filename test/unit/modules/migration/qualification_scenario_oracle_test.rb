require "test_helper"
require "hive/modules/migration/qualification_scenario_actuals"
require "hive/modules/migration/qualification_scenario_oracle"
require "hive/modules/migration/qualification_run_descriptor"
require_relative "../../../support/qualification_run_fixture"

class ModulesMigrationQualificationScenarioOracleTest <
    Minitest::Test
  include QualificationRunFixture

  ORACLE =
    Hive::Modules::Migration::QualificationScenarioOracle
  ACTUALS =
    Hive::Modules::Migration::QualificationScenarioActuals
  DESCRIPTOR =
    Hive::Modules::Migration::QualificationRunDescriptor

  def test_host_binds_unlabelled_actuals_to_exact_descriptor_expectations
    fixture = qualification_run_fixture
    descriptor = DESCRIPTOR.load(fixture.fetch(:descriptor))
    expected =
      qualification_scenario_observations(
        fixture,
        lane: "deterministic"
      )
    actuals = actuals_from(expected)

    observations = ORACLE.new.call(
      descriptor: descriptor,
      lane: "deterministic",
      actuals: [ actuals ],
      recovery_evidence:
        qualification_host_recovery(expected)
    )

    assert_equal expected, observations.to_h
    assert_equal(
      "ordinary_positive_finding",
      observations.observations
        .fetch(0)
        .fetch("decision_class")
    )
  end

  def test_rejects_unknown_or_missing_candidate_actuals
    fixture = qualification_run_fixture
    descriptor = DESCRIPTOR.load(fixture.fetch(:descriptor))
    expected =
      qualification_scenario_observations(
        fixture,
        lane: "deterministic"
      )
    unknown = JSON.parse(JSON.generate(expected))
    unknown.dig("observations", 0)["decision_id"] = "f" * 64

    assert_raises(Hive::ConfigError) do
      ORACLE.new.call(
        descriptor: descriptor,
        lane: "deterministic",
        actuals: [ actuals_from(unknown) ],
        recovery_evidence:
          qualification_host_recovery(unknown)
      )
    end

    assert_raises(Hive::ConfigError) do
      ORACLE.new.call(
        descriptor: descriptor,
        lane: "deterministic",
        actuals: [],
        recovery_evidence:
          qualification_host_recovery(expected)
      )
    end
  end

  def test_rejects_a_forged_fault_recovery_trace
    fixture = qualification_run_fixture
    descriptor = DESCRIPTOR.load(fixture.fetch(:descriptor))
    expected =
      qualification_scenario_observations(
        fixture,
        lane: "deterministic"
      )
    recovery = qualification_host_recovery(expected)
    fields = JSON.parse(JSON.generate(recovery.fetch(0).fields))
    fields.fetch("recovery_trace").fetch(0)["phase"] =
      "module_finalize"
    forged = [
      Hive::Modules::Migration::
        QualificationScenarioRecoveryEvidence::Projection.new(
          case_id: recovery.fetch(0).case_id,
          process_result_sha256:
            recovery.fetch(0).process_result_sha256,
          fields: fields.freeze
        ).freeze
    ]

    assert_raises(Hive::ConfigError) do
      ORACLE.new.call(
        descriptor: descriptor,
        lane: "deterministic",
        actuals: [ actuals_from(expected) ],
        recovery_evidence: forged
      )
    end
  end

  def test_rejects_missing_or_extra_host_recovery_cases
    fixture = qualification_run_fixture
    descriptor = DESCRIPTOR.load(fixture.fetch(:descriptor))
    expected =
      qualification_scenario_observations(
        fixture,
        lane: "deterministic"
      )
    actuals = [ actuals_from(expected) ]
    recovery = qualification_host_recovery(expected)

    assert_raises(Hive::ConfigError) do
      ORACLE.new.call(
        descriptor: descriptor,
        lane: "deterministic",
        actuals: actuals,
        recovery_evidence: []
      )
    end
    assert_raises(Hive::ConfigError) do
      ORACLE.new.call(
        descriptor: descriptor,
        lane: "deterministic",
        actuals: actuals,
        recovery_evidence: recovery + recovery
      )
    end
  end

  def test_clean_negative_requires_a_completed_reviewed_ordinary_scan
    oracle = ORACLE.new
    reviewed_clean = {
      "review_complete" => true,
      "features_reviewed" => 1,
      "findings" => 0,
      "finding_ids" => []
    }

    assert oracle.send(
      :clean_negative?,
      "patrol",
      rationale: "due",
      outcome: reviewed_clean
    )
    refute oracle.send(
      :clean_negative?,
      "patrol",
      rationale: "not_due",
      outcome: reviewed_clean
    )
    refute oracle.send(
      :clean_negative?,
      "patrol",
      rationale: "due",
      outcome: reviewed_clean.merge(
        "features_reviewed" => 0
      )
    )
  end

  def test_clean_negative_requires_a_completed_no_theses_architecture_scan
    oracle = ORACLE.new
    reviewed_clean = {
      "complete" => true,
      "action_count" => 0,
      "zero_reason" => "no_theses"
    }

    assert oracle.send(
      :clean_negative?,
      "architecture-patrol",
      rationale: "due",
      outcome: reviewed_clean
    )
    refute oracle.send(
      :clean_negative?,
      "architecture-patrol",
      rationale: "not_due",
      outcome: reviewed_clean
    )
    refute oracle.send(
      :clean_negative?,
      "architecture-patrol",
      rationale: "due",
      outcome: reviewed_clean.merge(
        "zero_reason" => "not_due"
      )
    )
  end

  private

  def actuals_from(observations)
    qualification_candidate_actuals(observations)
  end
end
