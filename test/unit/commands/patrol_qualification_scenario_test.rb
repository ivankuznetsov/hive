require "test_helper"
require "digest"
require "hive/commands/patrol_qualification_scenario"
require "hive/modules/migration/qualification_scenario_actuals"
require "hive/modules/migration/qualification_scenario_request"

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
      refute actuals.actuals.fetch(0).key?("decision_class")
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
          "output",
          "scenario-actuals.json"
        )
      )
      refute_path_exists File.join(root, "cases")
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

  def with_workspace
    with_tmp_dir do |root|
      File.chmod(0o700, root)
      scenario = scenario_bytes
      scenario_path =
        File.join(root, "inputs", "scenarios", "ordinary.yml")
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
        "case_id" => "ordinary-due-clean",
        "scenario_sha256" =>
          Digest::SHA256.hexdigest(scenario),
        "scenario_ref" => "inputs/scenarios/ordinary.yml",
        "package_root_ref" => "targets/source",
        "sandbox_root_ref" =>
          "cases/ordinary-due-clean/sandbox",
        "output_ref" =>
          "cases/ordinary-due-clean/output/scenario-actuals.json",
        "project" => {
          "project_id" =>
            "11111111-1111-4111-8111-111111111111",
          "name" => "qualification-demo",
          "repository" =>
            "github.com/example/qualification-demo"
        }
      }
      request_ref = "requests/ordinary-due-clean.json"
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
end
