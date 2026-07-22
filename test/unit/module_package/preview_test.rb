require "test_helper"
require_relative "../../support/module_helpers"
require "hive/module_package/preview"

class ModulePackagePreviewTest < Minitest::Test
  include HiveTestHelper
  include HiveModuleTestHelper

  def test_update_preserves_existing_hooks_and_disables_new_hooks
    with_tmp_dir do |root|
      old_resolution, old_descriptor = write_module_package(File.join(root, "old"))
      old_configuration = Hive::ModulePackage::Configuration.build(
        old_descriptor, generation: old_resolution,
        settings: { "mode" => "safe", "api_token" => nil }, hooks: { "schedule" => true },
        grants: exact_grants(old_descriptor)
      )
      current = selection(old_resolution, old_configuration)
      hooks = old_descriptor.hooks + [
        {
          "id" => "task", "target" => { "kind" => "entrypoint", "id" => "demo.task" },
          "default_enabled" => false, "schedules" => [], "events" => [ "task.completed" ],
          "concurrency" => "drop"
        }
      ]
      new_resolution, descriptor = write_module_package(
        File.join(root, "new"), version: "1.1.0", commit: "b" * 40, hooks: hooks
      )

      preview = Hive::ModulePackage::Preview.build(
        operation: "update", descriptor: descriptor, generation: new_resolution,
        current: current, current_configuration: old_configuration,
        settings: {}, hooks: {}, grants: exact_grants(descriptor), now: Time.utc(2026, 7, 22)
      )

      assert_equal true, preview.configuration.hooks.fetch("schedule")
      assert_equal false, preview.configuration.hooks.fetch("task")
      assert_equal [ "task" ], preview.diff.hooks.fetch("added")
      preview.verify!(digest: preview.digest, current: current, now: Time.utc(2026, 7, 22, 0, 1))
      assert_raises(Hive::ConcurrentRunError) do
        preview.verify!(digest: preview.digest, current: current.merge("enabled" => false), now: Time.utc(2026, 7, 22, 0, 1))
      end
    end
  end

  private

  def selection(resolution, configuration)
    {
      "schema_version" => 1, "name" => resolution.name, "installed" => true, "enabled" => true,
      "active" => {
        "version" => resolution.version, "catalog_commit" => resolution.catalog_commit,
        "source_commit" => resolution.source_commit, "manifest_digest" => resolution.manifest_digest,
        "configuration_digest" => configuration.digest
      },
      "previous" => nil, "epoch" => 1, "high_water_at" => "2026-07-22T00:00:00Z",
      "receipt_digest" => "f" * 64
    }
  end
end
