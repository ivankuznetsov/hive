require "test_helper"
require_relative "../../support/module_helpers"
require "hive/module_package/configuration"
require "hive/modules/trigger_evaluator"

class ModulesTriggerEvaluatorTest < Minitest::Test
  include HiveTestHelper
  include HiveModuleTestHelper

  NOW = Time.utc(2026, 7, 22, 10, 0, 0)

  def test_named_and_scheduled_bindings_launch_from_same_pure_evaluator
    with_fixture do |selection, configuration, hook|
      evaluator = Hive::Modules::TriggerEvaluator.new
      named = evaluator.evaluate(
        selection: selection, configuration: configuration, hook: hook,
        hook_state: hook_state, event: event("task.completed")
      )
      scheduled = evaluator.evaluate(
        selection: selection, configuration: configuration, hook: hook,
        hook_state: hook_state, event: event("schedule", "payload" => { "schedule" => "0 * * * *" })
      )

      assert named.launch?
      assert scheduled.launch?
      assert_equal "admitted", named.reason
    end
  end

  def test_state_dedupe_concurrency_high_water_and_secret_gates_are_explainable
    with_fixture(secret_required: true) do |selection, configuration, hook|
      evaluator = Hive::Modules::TriggerEvaluator.new
      rows = {
        "disabled" => { selection: selection.merge("enabled" => false) },
        "activation_fenced" => { activation_fenced: true },
        "hook_disabled" => { hook_state: hook_state.merge("enabled" => false) },
        "duplicate" => { duplicate: true, secret_availability: { "API_TOKEN" => true } },
        "concurrency_blocked" => { concurrency_blocked: true, secret_availability: { "API_TOKEN" => true } },
        "permission_blocked" => { secret_availability: { "API_TOKEN" => false } },
        "cursor_stale" => { event: event("task.completed", "occurred_at" => NOW - 60) }
      }
      rows.each do |reason, overrides|
        arguments = {
          selection: selection, configuration: configuration, hook: hook,
          hook_state: hook_state, event: event("task.completed"),
          secret_availability: { "API_TOKEN" => true }
        }.merge(overrides)
        result = evaluator.evaluate(**arguments)
        refute result.launch?, reason
        assert_equal reason, result.reason
      end
    end
  end

  def test_uninstalled_and_malformed_bindings_fail_closed
    with_fixture do |selection, configuration, hook|
      evaluator = Hive::Modules::TriggerEvaluator.new
      uninstalled = evaluator.evaluate(
        selection: selection.merge("installed" => false), configuration: configuration,
        hook: hook, hook_state: hook_state, event: event("task.completed")
      )
      assert_equal "uninstalled", uninstalled.reason

      invalid = evaluator.evaluate(
        selection: selection, configuration: configuration,
        hook: nil, hook_state: hook_state, event: event("task.completed")
      )
      assert_equal "invalid_binding", invalid.reason

      malformed_time = evaluator.evaluate(
        selection: selection, configuration: configuration,
        hook: hook, hook_state: hook_state,
        event: event("task.completed", "occurred_at" => "not-a-time")
      )
      assert_equal "cursor_stale", malformed_time.reason
    end
  end

  private

  def with_fixture(secret_required: false)
    with_tmp_dir do |root|
      hooks = [
        {
          "id" => "task", "target" => { "kind" => "entrypoint", "id" => "demo.run" },
          "default_enabled" => true, "schedules" => [ "0 * * * *" ],
          "events" => [ "task.completed" ], "concurrency" => "drop"
        }
      ]
      settings = [
        { "name" => "mode", "type" => "enum", "required" => true, "default" => "safe", "values" => %w[safe fast] },
        { "name" => "api_token", "type" => "secret", "required" => secret_required, "secret" => true }
      ]
      resolution, descriptor = write_module_package(
        File.join(root, "package"), hooks: hooks, settings: settings
      )
      configuration = Hive::ModulePackage::Configuration.build(
        descriptor, generation: resolution,
        settings: { "mode" => "safe", "api_token" => secret_required ? "API_TOKEN" : nil },
        hooks: { "task" => true }, grants: exact_grants(descriptor)
      )
      selection = {
        "installed" => true, "enabled" => true, "epoch" => 1,
        "high_water_at" => (NOW - 30).iso8601(6),
        "active" => {
          "source_commit" => resolution.source_commit,
          "configuration_digest" => configuration.digest
        }
      }
      yield selection, configuration, hooks.first
    end
  end

  def hook_state
    { "enabled" => true, "cursor" => nil, "binding_digest" => "a" * 64 }
  end

  def event(name, overrides = {})
    {
      "event_id" => "evt-#{'f' * 64}", "event_name" => name,
      "occurred_at" => NOW.iso8601(6), "payload" => {}
    }.merge(overrides)
  end
end
