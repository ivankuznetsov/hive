require_relative "../../test_helper"
require_relative "scenario_parser"

class E2EScenarioParserTest < Minitest::Test
  def test_template_parses
    scenario = Hive::E2E::ScenarioParser.parse(File.expand_path("../scenarios/_template.yml", __dir__))

    assert_equal "template", scenario.name
    assert scenario.steps.any? { |step| step.kind == "ruby_block" }
  end

  def test_unknown_step_kind_reports_line
    Dir.mktmpdir("scenario") do |dir|
      path = File.join(dir, "bad.yml")
      File.write(path, <<~YAML)
        name: bad
        steps:
          - kind: nope
      YAML

      error = assert_raises(Hive::E2E::ScenarioParser::InvalidScenario) do
        Hive::E2E::ScenarioParser.parse(path)
      end
      assert_includes error.message, "unknown step kind"
      assert_operator error.line, :>, 0
    end
  end

  def test_tui_keys_text_with_paste_option_parses
    Dir.mktmpdir("scenario") do |dir|
      path = File.join(dir, "paste.yml")
      File.write(path, <<~YAML)
        name: paste_ok
        steps:
          - kind: tui_keys
            text: "hello"
            paste: true
      YAML

      scenario = Hive::E2E::ScenarioParser.parse(path)
      assert_equal true, scenario.steps.first.args["paste"]
      assert_equal "hello", scenario.steps.first.args["text"]
    end
  end

  def test_tui_keys_rejects_both_keys_and_text
    Dir.mktmpdir("scenario") do |dir|
      path = File.join(dir, "bad.yml")
      File.write(path, <<~YAML)
        name: bad
        steps:
          - kind: tui_keys
            keys: "Enter"
            text: "hello"
      YAML

      error = assert_raises(Hive::E2E::ScenarioParser::InvalidScenario) do
        Hive::E2E::ScenarioParser.parse(path)
      end
      assert_includes error.message, "exactly one of keys or text"
    end
  end

  def test_rejects_unsafe_scenario_names_before_runner_uses_paths
    [ "../bad", "/tmp/bad", "nested/name", ".", "bad name" ].each do |name|
      Dir.mktmpdir("scenario") do |dir|
        path = File.join(dir, "bad.yml")
        File.write(path, <<~YAML)
          name: #{name.inspect}
          steps:
            - kind: cli
              args: [version]
        YAML

        error = assert_raises(Hive::E2E::ScenarioParser::InvalidScenario) do
          Hive::E2E::ScenarioParser.parse(path)
        end
        assert_includes error.message, "scenario name must be a safe basename"
      end
    end
  end

  def test_incident_metadata_parses_without_changing_legacy_scenarios
    Dir.mktmpdir("scenario") do |dir|
      path = File.join(dir, "incident.yml")
      File.write(path, <<~YAML)
        name: incident_fixture
        description: Reproduces a synthetic dispatch ordering failure.
        tags: [incident-regression]
        incident_id: dispatch-ordering
        sibling_task_id: "#9767"
        pending: true
        steps:
          - kind: cli
            args: [version]
      YAML

      scenario = Hive::E2E::ScenarioParser.parse(path)

      assert_equal "dispatch-ordering", scenario.incident_id
      assert_equal "#9767", scenario.sibling_task_id
      assert_equal true, scenario.pending
    end

    legacy = Hive::E2E::ScenarioParser.parse(File.expand_path("../scenarios/full_pipeline_happy_path.yml", __dir__))
    assert_nil legacy.incident_id
    assert_nil legacy.sibling_task_id
    assert_equal false, legacy.pending
  end

  def test_incident_metadata_requires_description_ids_and_sanitized_values
    invalid_documents = {
      "description" => <<~YAML,
        name: missing_description
        tags: [incident-regression]
        incident_id: missing-description
        sibling_task_id: "#9767"
        pending: true
        steps:
          - kind: cli
            args: [version]
      YAML
      "incident_id" => <<~YAML,
        name: unsafe_incident
        description: Synthetic incident.
        tags: [incident-regression]
        incident_id: "Unsafe Incident"
        sibling_task_id: "#9767"
        pending: true
        steps:
          - kind: cli
            args: [version]
      YAML
      "sibling_task_id" => <<~YAML,
        name: missing_sibling
        description: Synthetic incident.
        tags: [incident-regression]
        incident_id: missing-sibling
        pending: true
        steps:
          - kind: cli
            args: [version]
      YAML
      "pending" => <<~YAML
        name: invalid_pending
        description: Synthetic incident.
        tags: [incident-regression]
        incident_id: invalid-pending
        sibling_task_id: "#9767"
        pending: later
        steps:
          - kind: cli
            args: [version]
      YAML
    }

    invalid_documents.each do |field, yaml|
      Dir.mktmpdir("scenario") do |dir|
        path = File.join(dir, "invalid.yml")
        File.write(path, yaml)

        error = assert_raises(Hive::E2E::ScenarioParser::InvalidScenario) do
          Hive::E2E::ScenarioParser.parse(path)
        end
        assert_includes error.message, field
        assert_operator error.line, :>, 0
      end
    end
  end
end
