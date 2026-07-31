require "test_helper"
require "json_schemer"
require "hive/modules/migration/qualification_scenario_actuals"
require_relative "../../../support/qualification_run_fixture"

class ModulesMigrationQualificationScenarioActualsTest <
    Minitest::Test
  include QualificationRunFixture

  MODEL =
    Hive::Modules::Migration::QualificationScenarioActuals

  def test_round_trips_candidate_actuals_without_oracle_fields
    payload = valid_payload

    actuals = MODEL.from_h(payload)
    loaded = MODEL.load(MODEL.canonical(actuals.to_h))

    assert_equal payload, loaded.to_h
    assert_equal 1, loaded.actuals.length
    row = loaded.actuals.fetch(0)
    refute row.key?("decision_class")
    refute loaded.to_h.key?("run_id")
    refute loaded.to_h.key?("lane")
    refute loaded.to_h.key?("scenario_manifest_sha256")
    assert_predicate loaded.payload, :frozen?
    assert_empty schema.validate(loaded.to_h).to_a
  end

  def test_rejects_descriptor_or_expectation_authority
    %w[
      decision_class decision_expectations expected_legacy_effect_keys
      run_id lane scenario_manifest_sha256
    ].each do |field|
      value = valid_payload
      if field == "decision_class"
        value.dig("actuals", 0)[field] = "forged"
      else
        value[field] = "forged"
      end

      assert_raises(Hive::ConfigError, field) do
        MODEL.from_h(value)
      end
    end
  end

  def test_rejects_noncanonical_or_broken_production_links
    assert_raises(Hive::ConfigError) do
      MODEL.load(JSON.pretty_generate(valid_payload))
    end

    value = valid_payload
    value.dig("actuals", 0, "decisions", 0)["event_id"] =
      "evt-#{"f" * 64}"
    assert_raises(Hive::ConfigError) do
      MODEL.from_h(value)
    end
  end

  private

  def valid_payload
    fixture = qualification_run_fixture
    observation =
      qualification_scenario_observations(
        fixture,
        lane: "deterministic"
      ).fetch("observations").fetch(0)
    {
      "schema" => MODEL::SCHEMA,
      "schema_version" => MODEL::SCHEMA_VERSION,
      "actuals" => [
        JSON.parse(JSON.generate(observation)).tap do |row|
          row.delete("decision_class")
        end
      ]
    }
  end

  def schema
    @schema ||= JSONSchemer.schema(
      JSON.parse(
        File.binread(
          Hive::Schemas.schema_path(MODEL::SCHEMA)
        )
      )
    )
  end
end
