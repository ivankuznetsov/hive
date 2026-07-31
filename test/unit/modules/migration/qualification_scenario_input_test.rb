require "test_helper"
require "hive/modules/migration/qualification_scenario_input"

class ModulesMigrationQualificationScenarioInputTest < Minitest::Test
  INPUT =
    Hive::Modules::Migration::QualificationScenarioInput

  def test_loads_canonical_stimulus_without_descriptor_expectations
    input = INPUT.load(
      scenario_bytes,
      expected_case_id: "ordinary-due-clean"
    )

    assert_equal "ordinary-due-clean", input.case_id
    assert_equal "patrol", input.module_name
    assert_equal "timer_due", input.operation
    assert_equal Time.utc(2026, 7, 31, 12, 34, 56, 123_456),
                 input.clock
    assert_empty input.faults
    assert_equal [], input.reviewer_findings
  end

  def test_rejects_expectation_fields_and_case_substitution
    expectation_fields = %w[
      control decision_class decision_expectations
      expected_legacy_effect_keys matrix repository_sha trigger_digest
    ]
    expectation_fields.each do |field|
      bytes = scenario_bytes.sub(
        "reviewer:\n",
        "#{field}: forged\nreviewer:\n"
      )

      error = assert_raises(Hive::ConfigError) do
        INPUT.load(
          bytes,
          expected_case_id: "ordinary-due-clean"
        )
      end
      assert_match(/scenario input is malformed/, error.message, field)
    end

    assert_raises(Hive::ConfigError) do
      INPUT.load(
        scenario_bytes,
        expected_case_id: "foreign-case"
      )
    end
  end

  def test_rejects_yaml_aliases_unbounded_findings_and_unknown_faults
    aliased = <<~YAML
      schema: hive-patrol-qualification-scenario
      schema_version: 1
      case_id: ordinary-due-clean
      module: patrol
      operation: timer_due
      clock: "2026-07-31T12:34:56.123456Z"
      faults: &faults []
      reviewer:
        findings: *faults
    YAML
    assert_raises(Hive::ConfigError) do
      INPUT.load(
        aliased,
        expected_case_id: "ordinary-due-clean"
      )
    end

    too_many = scenario_bytes.sub(
      "    []\n",
      (1..33).map { |index| "    - id: finding-#{index}\n" }.join
    )
    assert_raises(Hive::ConfigError) do
      INPUT.load(
        too_many,
        expected_case_id: "ordinary-due-clean"
      )
    end

    unknown_fault = scenario_bytes.sub(
      "faults: []",
      "faults: [after_untrusted_expectation]"
    )
    assert_raises(Hive::ConfigError) do
      INPUT.load(
        unknown_fault,
        expected_case_id: "ordinary-due-clean"
      )
    end
  end

  private

  def scenario_bytes
    <<~YAML
      schema: hive-patrol-qualification-scenario
      schema_version: 1
      case_id: ordinary-due-clean
      module: patrol
      operation: timer_due
      clock: "2026-07-31T12:34:56.123456Z"
      faults: []
      reviewer:
        findings:
          []
    YAML
  end
end
