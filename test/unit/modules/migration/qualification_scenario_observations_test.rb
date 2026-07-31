require "test_helper"
require "json_schemer"
require "hive/modules/migration/qualification_scenario_observations"
require_relative "../../../support/qualification_run_fixture"

class ModulesMigrationQualificationScenarioObservationsTest <
    Minitest::Test
  include QualificationRunFixture

  MODEL =
    Hive::Modules::Migration::QualificationScenarioObservations

  def test_valid_canonical_round_trip_binds_a_real_retry_lineage
    payload = valid_payload
    observations = MODEL.from_h(payload)
    loaded = MODEL.load(MODEL.canonical(observations.to_h))
    row = loaded.observations.fetch(0)

    assert_equal payload, loaded.to_h
    assert_empty schema.validate(loaded.to_h).to_a
    assert_equal %w[lost terminal],
                 row.fetch("attempts").map { |attempt| attempt["state"] }
    assert_equal(
      row.fetch("attempt_id"),
      row.dig("decision", "attempt_id")
    )
    refute_equal row.fetch("decision_id"),
                 row.dig("decision", "decision_id")
    assert_predicate loaded.payload, :frozen?
    assert_predicate row.fetch("attempts"), :frozen?
  end

  def test_rejects_unknown_keys_at_every_contract_layer
    mutations = [
      lambda { |value| value["unknown"] = true },
      lambda { |value| value.dig("observations", 0)["unknown"] = true },
      lambda do |value|
        value.dig("observations", 0, "event")["unknown"] = true
      end,
      lambda do |value|
        value.dig("observations", 0, "decision")["unknown"] = true
      end,
      lambda do |value|
        value.dig("observations", 0, "attempts", 0)["unknown"] = true
      end
    ]

    mutations.each do |mutation|
      value = valid_payload
      mutation.call(value)

      assert_raises(Hive::ConfigError) { MODEL.from_h(value) }
    end
  end

  def test_rejects_oversize_noncanonical_and_unbounded_rows
    assert_raises(Hive::ConfigError) do
      MODEL.load(" " * (MODEL::MAX_BYTES + 1))
    end
    assert_raises(Hive::ConfigError) do
      MODEL.load(JSON.pretty_generate(valid_payload))
    end

    value = valid_payload
    value["observations"] =
      Array.new(MODEL::MAX_OBSERVATIONS + 1) do
        deep_copy(value.dig("observations", 0))
      end
    assert_raises(Hive::ConfigError) { MODEL.from_h(value) }
  end

  def test_rejects_duplicate_or_out_of_order_case_decisions
    duplicate = valid_payload
    duplicate["observations"] <<
      deep_copy(duplicate.dig("observations", 0))
    assert_raises(Hive::ConfigError) do
      MODEL.from_h(duplicate)
    end

    out_of_order = valid_payload
    other = deep_copy(out_of_order.dig("observations", 0))
    other["case_id"] = "z-case"
    other["decision_id"] = "f" * 64
    out_of_order["observations"] = [
      other,
      out_of_order.dig("observations", 0)
    ]
    assert_raises(Hive::ConfigError) do
      MODEL.from_h(out_of_order)
    end
  end

  def test_rejects_one_comparator_decision_reused_by_two_cases
    reused = valid_payload
    original = reused.dig("observations", 0)
    other_case = deep_copy(original)
    other_case["case_id"] = "z-case"
    reused["observations"] = [ original, other_case ]

    assert_raises(Hive::ConfigError) do
      MODEL.from_h(reused)
    end
  end

  def test_allows_a_nonfault_observation_with_zero_legacy_effects
    payload = valid_payload
    row = payload.dig("observations", 0)
    row["fault_checkpoint"] = nil
    row["legacy_effect_keys"] = []

    observations = MODEL.from_h(payload)

    assert_nil observations.observations
      .fetch(0)
      .fetch("fault_checkpoint")
    assert_empty observations.observations
      .fetch(0)
      .fetch("legacy_effect_keys")
    assert_empty schema.validate(observations.to_h).to_a
  end

  def test_rejects_broken_event_decision_and_attempt_links
    mutations = [
      lambda do |row|
        row["event_id"] = "evt-#{"f" * 64}"
      end,
      lambda do |row|
        row.dig("decision")["event_id"] = "evt-#{"f" * 64}"
      end,
      lambda do |row|
        row.dig("attempts", 0, "subject")[
          "configuration_digest"
        ] = "a" * 64
      end
    ]

    mutations.each do |mutation|
      value = valid_payload
      mutation.call(value.dig("observations", 0))

      assert_raises(Hive::ConfigError) { MODEL.from_h(value) }
    end
  end

  def test_rejects_broken_retry_lineage_and_synthetic_generations
    predecessor = valid_payload
    predecessor.dig(
      "observations", 0, "attempts", 1
    )["predecessor_attempt_id"] =
      "33333333-3333-4333-8333-333333333333"
    reseal_projections_only!(
      predecessor.dig("observations", 0)
    )
    assert_raises(Hive::ConfigError) do
      MODEL.from_h(predecessor)
    end

    generation = valid_payload
    successor = generation.dig("observations", 0, "attempts", 1)
    successor["task_generation"] = "f" * 64
    successor["receipt"]["task_generation"] = "f" * 64
    reseal_projections_only!(
      generation.dig("observations", 0)
    )
    assert_raises(Hive::ConfigError) do
      MODEL.from_h(generation)
    end
  end

  private

  def valid_payload
    fixture = qualification_run_fixture
    deep_copy(
      qualification_scenario_observations(
        fixture, lane: "deterministic"
      )
    )
  end

  def deep_copy(value)
    JSON.parse(JSON.generate(value))
  end

  def reseal_projections_only!(row)
    row.fetch("attempts").each do |attempt|
      if attempt["receipt"]
        attempt["receipt_sha256"] =
          sha(canonical(attempt.fetch("receipt")))
      end
      attempt["projection_sha256"] = sha(
        canonical(
          attempt.reject do |key, _value|
            key == "projection_sha256"
          end
        )
      )
    end
  end

  def schema
    @schema ||= JSONSchemer.schema(
      JSON.parse(
        File.binread(
          Hive::Schemas.schema_path(
            "hive-patrol-qualification-scenario-observations"
          )
        )
      )
    )
  end
end
