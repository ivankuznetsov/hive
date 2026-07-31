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
      actuals: [ actuals ]
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
        actuals: [ actuals_from(unknown) ]
      )
    end

    assert_raises(Hive::ConfigError) do
      ORACLE.new.call(
        descriptor: descriptor,
        lane: "deterministic",
        actuals: []
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
    rows = observations.fetch("observations").map do |row|
      JSON.parse(JSON.generate(row)).tap do |copy|
        copy.delete("decision_class")
      end
    end
    ACTUALS.from_h(
      "schema" => ACTUALS::SCHEMA,
      "schema_version" => ACTUALS::SCHEMA_VERSION,
      "actuals" => rows
    )
  end
end
