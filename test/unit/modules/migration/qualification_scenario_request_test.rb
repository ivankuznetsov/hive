require "test_helper"
require "json_schemer"
require "hive/modules/migration/qualification_scenario_request"

class ModulesMigrationQualificationScenarioRequestTest < Minitest::Test
  include HiveTestHelper

  REQUEST =
    Hive::Modules::Migration::QualificationScenarioRequest

  def test_loads_only_process_confined_stimulus_authority
    request = REQUEST.load(canonical(valid_request))

    assert_equal "ordinary-due-clean", request.case_id
    assert_equal(
      "github.com/example/qualification-demo",
      request.project.fetch("repository")
    )
    assert_empty schema.validate(request.to_h).to_a
    with_tmp_dir do |root|
      assert_equal File.join(root, "targets", "source"),
                   request.resolve(root, request.package_root_ref)
      assert_equal(
        File.join(
          root,
          "cases",
          "ordinary-due-clean",
          "output",
          "scenario-actuals.json"
        ),
        request.resolve(root, request.output_ref)
      )
    end
  end

  def test_rejects_noncanonical_unknown_or_expectation_authority
    bytes = JSON.pretty_generate(valid_request)
    assert_raises(Hive::ConfigError) { REQUEST.load(bytes) }

    %w[
      control decision_class decision_expectations
      expected_legacy_effect_keys matrix
    ].each do |field|
      value = valid_request.merge(field => "forged")
      error = assert_raises(Hive::ConfigError) do
        REQUEST.load(canonical(value))
      end
      assert_match(/scenario request is malformed/, error.message, field)
    end
  end

  def test_rejects_escaping_or_ambiguous_refs
    %w[
      ../scenario.yml /tmp/scenario.yml inputs//scenario.yml
      inputs/./scenario.yml inputs\\scenario.yml
    ].each do |value|
      request = valid_request.merge("scenario_ref" => value)
      assert_raises(Hive::ConfigError, value) do
        REQUEST.load(canonical(request))
      end
    end
  end

  private

  def valid_request
    {
      "schema" => "hive-patrol-qualification-scenario-request",
      "schema_version" => 1,
      "case_id" => "ordinary-due-clean",
      "scenario_sha256" => "c" * 64,
      "scenario_ref" => "inputs/scenarios/scenario.yml",
      "package_root_ref" => "targets/source",
      "sandbox_root_ref" =>
        "cases/ordinary-due-clean/sandbox",
      "output_ref" =>
        "cases/ordinary-due-clean/output/scenario-actuals.json",
      "project" => {
        "project_id" => "11111111-1111-4111-8111-111111111111",
        "name" => "qualification-demo",
        "repository" =>
          "github.com/example/qualification-demo"
      }
    }
  end

  def canonical(value)
    Hive::WorkflowPackage::CanonicalJSON.generate(value)
  end

  def schema
    @schema ||= JSONSchemer.schema(
      JSON.parse(
        File.binread(
          Hive::Schemas.schema_path(REQUEST::SCHEMA)
        )
      )
    )
  end
end
