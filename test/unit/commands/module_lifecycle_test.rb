require "test_helper"
require_relative "../../support/module_helpers"
require "hive/commands/module/install"
require "hive/commands/module/update"
require "hive/commands/module/state_change"
require "hive/commands/module/list"

class ModuleLifecycleCommandTest < Minitest::Test
  include HiveTestHelper
  include HiveModuleTestHelper

  FakeCatalog = Data.define(:package_root, :resolution) do
    def fetch(_source, destination:)
      FileUtils.cp_r(File.join(package_root, "."), destination)
      resolution
    end
  end

  def test_noninteractive_install_requires_complete_choices_and_exact_receipt
    with_fixture do |project, store, package, resolution|
      incomplete = install_command(project, store, package, resolution, dry_run: true, settings: [])
      assert_raises(Hive::ConfigError) { incomplete.call! }

      preview = install_command(project, store, package, resolution, dry_run: true).call!
      assert_equal "preview", preview.fetch("status")
      assert_match(/\A[0-9]+\.[0-9a-f]{64}\z/, preview.fetch("preview_receipt"))
      assert_nil store.selected("demo")

      assert_raises(Hive::Commands::Module::ConsentRequired) do
        install_command(project, store, package, resolution, yes: true).call!
      end
      applied = install_command(
        project, store, package, resolution, yes: true, receipt: preview.fetch("preview_receipt")
      ).call!
      assert_equal "installed", applied.fetch("status")
      assert store.selected("demo")

      replay = install_command(
        project, store, package, resolution, yes: true, receipt: preview.fetch("preview_receipt")
      ).call!
      assert_equal "already_current", replay.fetch("status")
    end
  end

  def test_update_preserves_choices_and_state_changes_are_receipt_bound
    with_fixture do |project, store, package, resolution|
      install_preview = install_command(project, store, package, resolution, dry_run: true).call!
      install_command(
        project, store, package, resolution, yes: true,
        receipt: install_preview.fetch("preview_receipt")
      ).call!
      update_root = File.join(project, "update-package")
      new_resolution, = write_module_package(update_root, version: "1.1.0", commit: "b" * 40)
      update_preview = Hive::Commands::Module::Update.new(
        "demo", project_root: project, json: true, stdout: StringIO.new, yes: false, dry_run: true,
        receipt: nil, settings: [], hooks: [], grants: [ "filesystem_read=repository" ],
        catalog_client: FakeCatalog.new(update_root, new_resolution), store: store, committer: ->(*) { }
      ).call!
      Hive::Commands::Module::Update.new(
        "demo", project_root: project, json: true, stdout: StringIO.new, yes: true, dry_run: false,
        receipt: update_preview.fetch("preview_receipt"), settings: [], hooks: [],
        grants: [ "filesystem_read=repository" ],
        catalog_client: FakeCatalog.new(update_root, new_resolution), store: store, committer: ->(*) { }
      ).call!
      assert_equal "b" * 40, store.selected("demo").dig("active", "source_commit")
      configuration = store.configuration("demo", store.selected("demo").dig("active", "configuration_digest"))
      assert_equal true, configuration.hooks.fetch("schedule")

      state_preview = Hive::Commands::Module::StateChange.new(
        "disable", "demo", project_root: project, json: true, stdout: StringIO.new,
        yes: false, dry_run: true, receipt: nil, store: store, committer: ->(*) { }
      ).call!
      Hive::Commands::Module::StateChange.new(
        "disable", "demo", project_root: project, json: true, stdout: StringIO.new,
        yes: true, dry_run: false, receipt: state_preview.fetch("preview_receipt"),
        store: store, committer: ->(*) { }
      ).call!
      refute store.selected("demo").fetch("enabled")
    end
  end

  def test_list_is_project_local_and_redacted
    with_fixture do |project, store, package, resolution|
      preview = install_command(project, store, package, resolution, dry_run: true).call!
      install_command(project, store, package, resolution, yes: true, receipt: preview.fetch("preview_receipt")).call!

      payload = Hive::Commands::Module::List.new(
        project_root: project, json: true, stdout: StringIO.new, store: store
      ).call!

      assert_equal [ "demo" ], payload.fetch("modules").map { |row| row.fetch("name") }
      refute_includes JSON.generate(payload), "super-secret"
    end
  end

  private

  def with_fixture
    with_tmp_dir do |project|
      state = File.join(project, ".hive-state")
      FileUtils.mkdir_p(state)
      File.write(File.join(state, "config.yml"), { "hive_state_path" => ".hive-state" }.to_yaml)
      package = File.join(project, "package")
      resolution, = write_module_package(package)
      store = Hive::ModulePackage::ManagedStore.new(state)
      yield project, store, package, resolution
    end
  end

  def install_command(project, store, package, resolution, yes: false, dry_run: false, receipt: nil,
                      settings: [ "mode=safe", "api_token=" ])
    Hive::Commands::Module::Install.new(
      "honeycomb/demo", project_root: project, json: true, stdout: StringIO.new,
      yes: yes, dry_run: dry_run, receipt: receipt, settings: settings,
      hooks: [ "schedule=true" ], grants: [ "filesystem_read=repository" ],
      catalog_client: FakeCatalog.new(package, resolution), store: store, committer: ->(*) { }
    )
  end
end
