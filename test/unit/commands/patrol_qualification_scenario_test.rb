require "test_helper"
require "digest"
require "hive/commands/patrol_qualification_scenario"
require "hive/modules/migration/qualification_scenario_actuals"
require "hive/modules/migration/qualification_scenario_request"
require "hive/workflow_package/canonical_yaml"

class CommandsPatrolQualificationScenarioTest < Minitest::Test
  include HiveTestHelper

  COMMAND = Hive::Commands::PatrolQualificationScenario
  REQUEST =
    Hive::Modules::Migration::QualificationScenarioRequest
  ACTUALS =
    Hive::Modules::Migration::QualificationScenarioActuals
  SOURCE_ROOT = File.expand_path("../../..", __dir__).freeze

  def test_executes_one_stimulus_only_case_and_atomically_writes_actuals
    with_workspace do |root, _request_path, request_ref|
      with_env(
        "HIVE_HOME" =>
          File.join(
            root,
            "cases",
            "ordinary-due-clean",
            "sandbox",
            "hive-home"
          )
      ) do
        assert_equal(
          0,
          COMMAND.from_argv(
            [
              "--workspace", root,
              "--request", request_ref
            ]
          ).call
        )
      end

      output =
        File.join(
          root,
          "cases",
          "ordinary-due-clean",
          "generations",
          "1",
          "output",
          "scenario-actuals.json"
        )
      assert_equal 0o600, File.stat(output).mode & 0o777
      actuals = ACTUALS.load(File.binread(output))
      assert_equal 1, actuals.actuals.length
      assert_equal(
        "ordinary-due-clean",
        actuals.actuals.fetch(0).fetch("case_id")
      )
      refute actuals.to_h.key?("run_id")
      ACTUALS::ORACLE_KEYS.each do |key|
        refute actuals.actuals.fetch(0).key?(key), key
      end
    end
  end

  def test_fails_closed_before_execution_for_changed_scenario
    with_workspace do |root, _request_path, request_ref|
      scenario =
        File.join(root, "inputs", "scenarios", "ordinary.yml")
      File.binwrite(scenario, "#{File.binread(scenario)}# changed\n")
      File.chmod(0o600, scenario)

      error = assert_raises(Hive::ConfigError) do
        with_env(
          "HIVE_HOME" =>
            File.join(
              root,
              "cases",
              "ordinary-due-clean",
              "sandbox",
              "hive-home"
            )
        ) do
          COMMAND.from_argv(
            [
              "--workspace", root,
              "--request", request_ref
            ]
          ).call
        end
      end
      assert_match(/scenario digest changed/, error.message)
      refute_path_exists(
        File.join(
          root,
          "cases",
          "ordinary-due-clean",
          "generations",
          "1",
          "output",
          "scenario-actuals.json"
        )
      )
      refute_path_exists File.join(root, "cases")
    end
  end

  def test_executes_architecture_control_through_private_command
    case_id = "architecture-positive"
    with_workspace(
      case_id: case_id,
      scenario_file: "architecture.yml",
      scenario: architecture_scenario_bytes(case_id)
    ) do |root, _request_path, request_ref|
      with_env(
        "HIVE_HOME" =>
          File.join(
            root,
            "cases",
            case_id,
            "sandbox",
            "hive-home"
          )
      ) do
        assert_equal(
          0,
          COMMAND.from_argv(
            [
              "--workspace", root,
              "--request", request_ref
            ]
          ).call
        )
      end

      output =
        File.join(
          root,
          "cases",
          case_id,
          "generations",
          "1",
          "output",
          "scenario-actuals.json"
        )
      actual = ACTUALS.load(File.binread(output)).actuals.fetch(0)
      assert_equal case_id, actual.fetch("case_id")
      assert_equal "architecture-patrol", actual.fetch("module")
      assert_equal "actions",
                   actual.dig("event", "payload", "target_hook")
      assert_equal(
        [ "succeeded" ],
        actual.fetch("attempts").map do |attempt|
          attempt.fetch("outcome")
        end
      )
    end
  end

  def test_rejects_non_private_request_and_unknown_argv
    with_workspace do |root, request_path, request_ref|
      File.chmod(0o644, request_path)
      assert_raises(Hive::ConfigError) do
        COMMAND.from_argv(
          [
            "--workspace", root,
            "--request", request_ref
          ]
        ).call
      end
    end

    assert_raises(Hive::ConfigError) do
      COMMAND.from_argv([ "--other", "/tmp/request.json" ])
    end
  end

  private

  def with_workspace(
    case_id: "ordinary-due-clean",
    scenario_file: "ordinary.yml",
    scenario: scenario_bytes
  )
    with_tmp_dir do |root|
      File.chmod(0o700, root)
      scenario_path =
        File.join(root, "inputs", "scenarios", scenario_file)
      FileUtils.mkdir_p(File.dirname(scenario_path), mode: 0o700)
      File.binwrite(scenario_path, scenario)
      File.chmod(0o600, scenario_path)
      FileUtils.mkdir_p(
        File.join(root, "targets", "source", "modules"),
        mode: 0o700
      )
      %w[architecture-patrol patrol].each do |name|
        FileUtils.cp_r(
          File.join(SOURCE_ROOT, "modules", name),
          File.join(
            root,
            "targets",
            "source",
            "modules",
            name
          )
        )
      end
      request = {
        "schema" => REQUEST::SCHEMA,
        "schema_version" => REQUEST::SCHEMA_VERSION,
        "case_id" => case_id,
        "generation" => 1,
        "stop_after" => nil,
        "scenario_sha256" =>
          Digest::SHA256.hexdigest(scenario),
        "scenario_ref" =>
          "inputs/scenarios/#{scenario_file}",
        "package_root_ref" => "targets/source",
        "sandbox_root_ref" =>
          "cases/#{case_id}/sandbox",
        "output_ref" =>
          "cases/#{case_id}/generations/1/output/" \
          "scenario-actuals.json",
        "project" => {
          "project_id" =>
            "11111111-1111-4111-8111-111111111111",
          "name" => "qualification-demo",
          "repository" =>
            "github.com/example/qualification-demo"
        }
      }
      request_ref = "requests/#{case_id}/generation-1.json"
      request_path = File.join(root, request_ref)
      FileUtils.mkdir_p(File.dirname(request_path), mode: 0o700)
      File.binwrite(
        request_path,
        REQUEST.canonical(request)
      )
      File.chmod(0o600, request_path)
      yield root, request_path, request_ref
    end
  end

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

  def architecture_scenario_bytes(case_id)
    Hive::WorkflowPackage::CanonicalYAML.dump(
      "schema" => "hive-patrol-qualification-scenario",
      "schema_version" => 1,
      "case_id" => case_id,
      "module" => "architecture-patrol",
      "operation" => "architecture_positive_fixture",
      "clock" => "2026-07-31T12:34:56.123456Z",
      "faults" => [],
      "reviewer" => {
        "findings" => [ architecture_thesis ]
      }
    )
  end

  def architecture_thesis
    {
      "feature" => "Checkout",
      "problem" =>
        "Checkout mixes validation and payment orchestration",
      "cost" =>
        "Frequent changes touch the same file and its callers",
      "evidence" => [
        {
          "file" => "lib/checkout.rb",
          "line" => 12,
          "snippet" => "def charge_and_validate",
          "claim" =>
            "validation and payment orchestration share one method"
        }
      ],
      "proposed_refactor" =>
        "Extract payment orchestration behind a checkout boundary",
      "expected_leverage" => {
        "drivers" => [
          {
            "signal" => "churn",
            "relief" => 1,
            "mechanism" =>
              "isolate payment edits from validation code"
          }
        ]
      },
      "confidence" => "medium",
      "risk" => {
        "caps" => { "single_feature" => true },
        "public_api_impact" => false,
        "public_api_details" => [],
        "cross_feature_impact" => false,
        "cross_feature_details" => [],
        "flags" => []
      },
      "required_validation" => {
        "commands" => [ "test" ],
        "characterization_first" => false,
        "notes" => "Run checkout tests"
      },
      "follow_up_approval_state" => "pending"
    }
  end
end
