require "test_helper"
require_relative "../../support/module_helpers"
require "hive/module_package/configuration"
require "hive/modules/hook_attempt"

class ModulesHookAttemptTest < Minitest::Test
  include HiveTestHelper
  include HiveModuleTestHelper

  def test_build_rejects_selection_and_configuration_identity_drift
    with_tmp_dir do |root|
      resolution, descriptor = write_module_package(File.join(root, "package"))
      configuration = Hive::ModulePackage::Configuration.build(
        descriptor, generation: resolution,
        settings: { "mode" => "safe", "api_token" => nil },
        hooks: { "schedule" => true }, grants: exact_grants(descriptor)
      )
      selection = {
        "active" => {
          "configuration_digest" => "f" * 64,
          "source_commit" => resolution.source_commit
        },
        "epoch" => 1
      }
      event = {
        "event_id" => "evt-1", "event_name" => "schedule"
      }

      assert_raises(Hive::ConfigError) do
        Hive::Modules::HookAttempt.build(
          project: "demo", project_id: "project-1", module_name: "demo",
          hook: descriptor.hooks.first, selection: selection,
          configuration: configuration, event: event, package_root: root
        )
      end
    end
  end

  def test_snapshot_validation_covers_every_target_shape_and_key_errors
    %w[entrypoint command workflow].each do |kind|
      assert Hive::Modules::HookAttempt.validate_execution_snapshot!(
        valid_snapshot(kind)
      )
    end
    assert_raises(Hive::ConfigError) do
      Hive::Modules::HookAttempt.validate_execution_snapshot!(
        valid_snapshot("future")
      )
    end

    snapshot = Class.new(Hash) do
      def fetch(key, *defaults)
        raise KeyError, key if key == "task_input_epoch"

        super
      end
    end.new
    snapshot.merge!(valid_snapshot("entrypoint"))
    assert_raises(Hive::ConfigError) do
      Hive::Modules::HookAttempt.validate_execution_snapshot!(snapshot)
    end
  end

  private

  def valid_snapshot(kind)
    target = case kind
    when "entrypoint"
      { "kind" => kind, "id" => "demo.run" }
    when "command"
      { "kind" => kind, "id" => "git status", "argv" => %w[git status] }
    when "workflow"
      {
        "kind" => kind, "id" => "review", "descriptor" => "review.yml",
        "files" => [ { "path" => "review.yml" } ]
      }
    else
      { "kind" => kind, "id" => "future" }
    end
    subject = {
      "kind" => "module_hook", "project_id" => "project-1",
      "module" => "demo", "hook" => "schedule",
      "event_id" => "evt-1", "occurrence_id" => "evt-1",
      "event_name" => "schedule", "module_generation" => "a" * 40,
      "configuration_digest" => "b" * 64, "grant_digest" => "c" * 64
    }
    {
      "schema_version" => 1, "subject" => subject,
      "descriptor" => {
        "id" => "schedule", "target" => target.slice("kind", "id")
      },
      "target" => target, "configuration" => { "mode" => "safe" },
      "grants" => { "filesystem_read" => [ "repository" ] },
      "ownership_generation" => "1:#{'a' * 40}", "task_input_epoch" => 1
    }
  end
end
