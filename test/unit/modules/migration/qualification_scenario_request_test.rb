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
    assert_equal 2, request.generation
    assert_nil request.stop_after
    assert_equal(
      "github.com/example/qualification-demo",
      request.project.fetch("repository")
    )
    assert_empty schema.validate(request.to_h).to_a
    with_tmp_dir do |root|
      assert_equal File.join(root, "targets", "candidate"),
                   request.resolve(root, request.package_root_ref)
      assert_equal(
        File.join(
          root,
          "cases",
          "ordinary-due-clean",
          "generations",
          "2",
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

  def test_rejects_invalid_generations_and_mismatched_output_refs
    [ 0, 4, "2", nil ].each do |generation|
      request = valid_request.merge("generation" => generation)
      assert_raises(Hive::ConfigError, generation.inspect) do
        REQUEST.load(canonical(request))
      end
    end

    request = valid_request.merge(
      "output_ref" =>
        "cases/ordinary-due-clean/generations/1/output/" \
        "scenario-actuals.json"
    )
    assert_raises(Hive::ConfigError) do
      REQUEST.load(canonical(request))
    end
  end

  def test_rejects_unknown_stop_after
    request = valid_request.merge("stop_after" => "after-anything")

    assert_raises(Hive::ConfigError) do
      REQUEST.load(canonical(request))
    end
  end

  def test_accepts_only_the_closed_checkpoint_vocabulary
    REQUEST::STOP_AFTER.each do |checkpoint|
      request = REQUEST.load(
        canonical(
          valid_request.merge("stop_after" => checkpoint)
        )
      )

      assert_equal checkpoint, request.stop_after
      assert_empty schema.validate(request.to_h).to_a
    end
  end

  private

  def valid_request
    {
      "schema" => "hive-patrol-qualification-scenario-request",
      "schema_version" => 1,
      "case_id" => "ordinary-due-clean",
      "generation" => 2,
      "stop_after" => nil,
      "scenario_sha256" => "c" * 64,
      "scenario_ref" => "inputs/scenarios/scenario.yml",
      "package_root_ref" => "targets/candidate",
      "sandbox_root_ref" =>
        "cases/ordinary-due-clean/sandbox",
      "output_ref" =>
        "cases/ordinary-due-clean/generations/2/output/" \
        "scenario-actuals.json",
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
