require "test_helper"
require_relative "../../support/module_helpers"
require "hive/web/module_lifecycle"

class WebModuleLifecycleTest < Minitest::Test
  include HiveTestHelper
  include HiveModuleTestHelper

  FakeCatalog = Struct.new(:package_root, :resolution) do
    def fetch(_source, destination:)
      FileUtils.cp_r(File.join(package_root, "."), destination)
      resolution
    end
  end

  def test_preview_apply_status_and_state_changes_share_the_domain_engine
    with_tmp_dir do |root|
      project = project_fixture(root)
      package = File.join(root, "package")
      resolution, = write_module_package(package)
      catalog = FakeCatalog.new(package, resolution)
      lifecycle = Hive::Web::ModuleLifecycle.new(
        catalog_client_factory: -> { catalog }, committer: ->(*) { },
        attempt_store: Hive::Attempts::Store.new(root: File.join(root, "attempts"), create_directories: false),
        clock: -> { Time.utc(2026, 7, 22, 12, 0, 0) }
      )
      choices = {
        "settings" => [ "mode=safe", "api_token=" ], "hooks" => [ "schedule=true" ],
        "grants" => [ "filesystem_read=repository" ]
      }

      preview = lifecycle.preview(project, operation: "install", source: "honeycomb/demo", choices: choices)
      assert_equal "preview", preview.fetch("status")
      assert_equal "safe", preview.dig("proposed", "settings", 0, "value")
      applied = lifecycle.apply(
        project, operation: "install", source: "honeycomb/demo", choices: choices,
        receipt: preview.fetch("preview_receipt")
      )
      assert_equal "installed", applied.fetch("status")
      assert_equal [ "demo" ], lifecycle.list(project).map { |row| row.fetch("name") }

      disable = lifecycle.preview(project, operation: "disable", name: "demo")
      lifecycle.apply(
        project, operation: "disable", name: "demo", receipt: disable.fetch("preview_receipt")
      )
      assert_equal "disabled", lifecycle.list(project).fetch(0).fetch("lifecycle_state")
    end
  end

  def test_apply_refetches_and_rejects_candidate_drift_without_mutation
    with_tmp_dir do |root|
      project = project_fixture(root)
      package = File.join(root, "package")
      resolution, = write_module_package(package)
      catalog = FakeCatalog.new(package, resolution)
      lifecycle = Hive::Web::ModuleLifecycle.new(
        catalog_client_factory: -> { catalog }, committer: ->(*) { }
      )
      choices = {
        "settings" => [ "mode=safe", "api_token=" ], "hooks" => [ "schedule=true" ],
        "grants" => [ "filesystem_read=repository" ]
      }
      preview = lifecycle.preview(project, operation: "install", source: "honeycomb/demo", choices: choices)
      changed = File.join(root, "changed")
      changed_resolution, = write_module_package(changed, version: "1.1.0", commit: "b" * 40)
      catalog.package_root = changed
      catalog.resolution = changed_resolution

      assert_raises(Hive::ConfigError) do
        lifecycle.apply(
          project, operation: "install", source: "honeycomb/demo", choices: choices,
          receipt: preview.fetch("preview_receipt")
        )
      end
      store = Hive::ModulePackage::ManagedStore.new(project.fetch("hive_state_path"))
      assert_nil store.inspect_selection("demo")
    end
  end

  private

  def project_fixture(root)
    state = File.join(root, ".hive-state")
    FileUtils.mkdir_p(state)
    File.write(File.join(state, "config.yml"), { "hive_state_path" => ".hive-state" }.to_yaml)
    { "name" => "demo", "path" => root, "hive_state_path" => state }
  end
end
