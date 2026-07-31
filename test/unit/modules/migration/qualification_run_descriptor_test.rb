require "test_helper"
require "json_schemer"
require "hive/modules/migration/qualification_run_descriptor"
require_relative "../../../support/qualification_run_fixture"

class QualificationRunDescriptorTest < Minitest::Test
  include QualificationRunFixture

  def test_loads_one_strict_immutable_authority_document
    fixture = qualification_run_fixture
    descriptor =
      Hive::Modules::Migration::QualificationRunDescriptor.load(
        fixture.fetch(:descriptor)
      )

    assert_equal fixture.dig(:payload, "run_id"),
                 descriptor.run_id
    assert_equal fixture.dig(:payload, "candidate"),
                 descriptor.candidate
    assert_equal fixture.dig(:payload, "project"),
                 descriptor.project
    assert_equal qualification_module_selections,
                 descriptor.module_selections
    assert_equal(
      fixture.dig(:payload, "expectations"),
      descriptor.authority_for("deterministic")
        .slice(
          "decision_expectations",
          "expected_legacy_effect_keys",
          "required_matrix",
          "required_faults"
        )
    )
    assert descriptor.frozen?
    assert descriptor.payload.frozen?
    assert_empty descriptor_schema.validate(descriptor.payload).to_a
  end

  def test_rejects_unknown_keys_unsafe_refs_and_aggregate_drift
    fixture = qualification_run_fixture
    mutations = []
    mutations << fixture.fetch(:payload).merge("latest" => true)
    mutations << deep_copy(fixture.fetch(:payload)).tap do |payload|
      payload["artifact_refs"]["installed"]["bundle"] =
        "../../foreign.json"
    end
    mutations << deep_copy(fixture.fetch(:payload)).tap do |payload|
      payload["scenarios"]["cases"] <<
        payload["scenarios"]["cases"].first
    end
    mutations << deep_copy(fixture.fetch(:payload)).tap do |payload|
      payload["expectations"]["required_matrix"] = []
    end
    mutations << deep_copy(fixture.fetch(:payload)).tap do |payload|
      payload["prepared_at"] = "2026-07-30T09:00:00Z"
    end
    mutations << deep_copy(fixture.fetch(:payload)).tap do |payload|
      payload["prepared_at"] = "2026-07-30T10:00:00.000000+01:00"
    end
    mutations << deep_copy(fixture.fetch(:payload)).tap do |payload|
      payload["lanes"]["installed"]["credential_bindings"] <<
        "AWS_SECRET_ACCESS_KEY"
    end
    mutations << deep_copy(fixture.fetch(:payload)).tap do |payload|
      payload["project"]["repository"] = "github.com/Owner/Evidence"
    end
    mutations << deep_copy(fixture.fetch(:payload)).tap do |payload|
      payload["scenarios"]["cases"].first[
        "decision_expectations"
      ].first["repository"] = "github.com/other/repository"
      payload["expectations"][
        "decision_expectations"
      ].first["repository"] = "github.com/other/repository"
    end
    mutations << deep_copy(fixture.fetch(:payload)).tap do |payload|
      payload["descriptor_sha256"] = "0" * 64
    end
    mutations << deep_copy(fixture.fetch(:payload)).tap do |payload|
      payload["run_id"] = "patrol-#{"0" * 64}"
      payload["descriptor_sha256"] = sha(
        canonical(
          payload.reject do |key, _value|
            key == "descriptor_sha256"
          end
        )
      )
    end

    mutations.each_with_index do |payload, index|
      seal_qualification_payload!(payload) if index < 9
      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::
          QualificationRunDescriptor.load(canonical(payload))
      end
    end
  end

  def test_rejects_pending_skipped_or_unsupported_case_state
    %w[pending skipped unsupported].each do |state|
      payload = deep_copy(
        qualification_run_fixture.fetch(:payload)
      )
      payload["scenarios"]["cases"].first["status"] = state
      seal_qualification_payload!(payload)

      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::
          QualificationRunDescriptor.load(canonical(payload))
      end
    end
  end

  def test_rejects_one_comparator_decision_reused_across_cases
    payload = deep_copy(
      qualification_run_fixture.fetch(:payload)
    )
    reused_case =
      deep_copy(payload.dig("scenarios", "cases", 0))
    reused_case["case_id"] = "patrol-case-restart"
    payload.dig("scenarios", "cases") << reused_case
    seal_qualification_payload!(payload)

    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::
        QualificationRunDescriptor.load(canonical(payload))
    end
  end

  def test_allows_empty_case_faults_and_effects_with_strict_run_authority
    payload = descriptor_with_empty_case_evidence
    descriptor =
      Hive::Modules::Migration::QualificationRunDescriptor.load(
        canonical(payload)
      )
    empty_case = descriptor.scenarios.fetch("cases").find do |row|
      row.fetch("case_id") == "clean-negative-case"
    end

    assert_empty empty_case.fetch("faults")
    assert_empty empty_case.fetch("expected_legacy_effect_keys")
    refute_empty descriptor.expectations.fetch("required_faults")
    refute_empty(
      descriptor.expectations.fetch(
        "expected_legacy_effect_keys"
      )
    )
    assert_empty descriptor_schema.validate(descriptor.payload).to_a
  end

  def test_empty_case_evidence_still_requires_exact_nonempty_aggregates
    aggregate_drift = [
      descriptor_with_empty_case_evidence.tap do |payload|
        payload.dig(
          "scenarios", "cases", 1, "faults"
        ) << "after_module_decision"
        seal_qualification_payload!(payload)
      end,
      descriptor_with_empty_case_evidence.tap do |payload|
        payload.dig(
          "scenarios", "cases", 1,
          "expected_legacy_effect_keys"
        ) << "effect-#{"f" * 64}"
        seal_qualification_payload!(payload)
      end
    ]
    aggregate_drift.each do |payload|
      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::
          QualificationRunDescriptor.load(canonical(payload))
      end
    end

    %w[required_faults expected_legacy_effect_keys].each do |key|
      payload = deep_copy(
        qualification_run_fixture.fetch(:payload)
      )
      case_key = key == "required_faults" ?
        "faults" : "expected_legacy_effect_keys"
      payload.dig("scenarios", "cases", 0)[case_key] = []
      payload.dig("expectations")[key] = []
      seal_qualification_payload!(payload)

      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::
          QualificationRunDescriptor.load(canonical(payload))
      end
    end
  end

  private

  def descriptor_with_empty_case_evidence
    payload = deep_copy(
      qualification_run_fixture.fetch(:payload)
    )
    empty_case =
      deep_copy(payload.dig("scenarios", "cases", 0))
    empty_case["case_id"] = "clean-negative-case"
    empty_case["faults"] = []
    empty_case["expected_legacy_effect_keys"] = []
    empty_case["matrix"] = [ "clean_negative" ]
    decision = empty_case.fetch("decision_expectations").fetch(0)
    decision["decision_id"] = "f" * 64
    decision["decision_class"] = "clean_negative"
    decision["trigger_digest"] = "e" * 64
    decision["control"] = "clean_negative"
    payload.dig("scenarios", "cases") << empty_case
    decisions = payload.dig("scenarios", "cases").flat_map do |row|
      row.fetch("decision_expectations")
    end.sort_by { |row| row.fetch("decision_id") }
    payload.dig(
      "expectations"
    )["decision_expectations"] =
      deep_copy(decisions)
    payload.dig(
      "expectations"
    )["required_matrix"] = %w[
      clean_negative ordinary_positive_finding
    ]
    seal_qualification_payload!(payload)
    payload
  end

  def deep_copy(value)
    JSON.parse(JSON.generate(value))
  end

  def descriptor_schema
    @descriptor_schema ||= JSONSchemer.schema(
      JSON.parse(
        File.binread(
          Hive::Schemas.schema_path(
            "hive-patrol-qualification-run"
          )
        )
      )
    )
  end
end
