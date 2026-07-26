require "test_helper"
require_relative "../../support/module_helpers"
require "hive/commands/module/install"
require "hive/commands/module/update"
require "hive/commands/module/state_change"
require "hive/commands/module/list"
require "hive/module_package/normalizer"
require "hive/modules/entrypoints"
require "hive/workflow_package/manifest"
require "hive/workflow_package/registry_client"

class ModuleLifecycleCommandTest < Minitest::Test
  include HiveTestHelper
  include HiveModuleTestHelper

  class TTYInput < StringIO
    def tty? = true
  end

  FakeCatalog = Data.define(:package_root, :resolution) do
    def fetch(_source, destination:)
      FileUtils.cp_r(File.join(package_root, "."), destination)
      resolution
    end
  end

  def setup
    Hive::Modules::Entrypoints.register("demo.run") { 0 }
    Hive::Modules::Entrypoints.register("demo.new") { 0 }
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

      assert_raises(Hive::Commands::Module::OwnershipError) do
        install_command(project, store, package, resolution, dry_run: true).call!
      end
    end
  end

  def test_native_install_runs_structural_health_and_commits_one_setup_intent
    with_tmp_dir do |project|
      state = File.join(project, ".hive-state")
      FileUtils.mkdir_p(state)
      File.write(
        File.join(state, "config.yml"),
        { "hive_state_path" => ".hive-state" }.to_yaml
      )
      package = File.join(project, "package")
      hooks = [
        {
          "id" => "setup",
          "target" => { "kind" => "entrypoint", "id" => "demo.run" },
          "default_enabled" => true, "schedules" => [],
          "events" => [ "project.registered" ], "concurrency" => "drop"
        }
      ]
      resolution, = write_module_package(package, hooks: hooks)
      store = Hive::ModulePackage::ManagedStore.new(state)
      common = {
        project_root: project, json: true, stdout: StringIO.new,
        settings: [ "mode=safe", "api_token=" ], hooks: [ "setup=enabled" ],
        grants: [ "filesystem_read=repository" ],
        setup_context: { "project_id" => "project-1", "project" => "demo" },
        catalog_client: FakeCatalog.new(package, resolution), store: store,
        committer: ->(*) { }
      }

      preview = Hive::Commands::Module::Install.new(
        "honeycomb/demo", **common, yes: false, dry_run: true, receipt: nil
      ).call!
      result = Hive::Commands::Module::Install.new(
        "honeycomb/demo", **common, yes: true, dry_run: false,
        receipt: preview.fetch("preview_receipt")
      ).call!

      assert_equal "installed", result.fetch("status")
      intent = store.inspect_setup_outbox("demo")
      assert_equal "project-1", intent.fetch("project_id")
      assert_equal [ "setup" ], intent.fetch("hooks")
      assert_equal(
        result.dig("selection", "active", "source_commit"),
        intent.fetch("source_commit")
      )
    end
  end

  def test_native_install_health_failure_rolls_back_before_commit
    with_fixture do |project, store, package, resolution|
      preview = install_command(
        project, store, package, resolution, dry_run: true
      ).call!
      command = Hive::Commands::Module::Install.new(
        "honeycomb/demo", project_root: project, json: true,
        stdout: StringIO.new, yes: true, dry_run: false,
        receipt: preview.fetch("preview_receipt"),
        settings: [ "mode=safe", "api_token=" ],
        hooks: [ "schedule=enabled" ],
        grants: [ "filesystem_read=repository" ],
        activation_health_check: ->(*) { false },
        catalog_client: FakeCatalog.new(package, resolution), store: store,
        committer: ->(*) { flunk "failed health must not commit" }
      )

      error = assert_raises(Hive::ConfigError) { command.call! }
      assert_equal "module activation health check failed", error.message
      assert_nil store.inspect_selection("demo")
      assert_equal [], store.generation_commits("demo")
    end
  end

  def test_non_tty_install_never_prompts_and_stays_choice_and_receipt_bound
    with_fixture do |project, store, package, resolution|
      output = StringIO.new
      preview = Hive::Commands::Module::Install.new(
        "honeycomb/demo", project_root: project, json: false, stdout: output,
        stdin: StringIO.new("yes\nyes\n"), yes: false, dry_run: true,
        receipt: nil, settings: [ "mode=safe", "api_token=" ],
        hooks: [ "schedule=enabled" ], grants: [ "filesystem_read=repository" ],
        catalog_client: FakeCatalog.new(package, resolution), store: store,
        committer: ->(*) { }
      ).call!
      refute_match(/Setting mode|Enable hook|Grant filesystem|Apply install/, output.string)

      assert_raises(Hive::Commands::Module::ConsentRequired) do
        Hive::Commands::Module::Install.new(
          "honeycomb/demo", project_root: project, json: false, stdout: StringIO.new,
          stdin: StringIO.new("yes\n"), yes: true, dry_run: false, receipt: nil,
          settings: [ "mode=safe", "api_token=" ], hooks: [ "schedule=enabled" ],
          grants: [ "filesystem_read=repository" ],
          catalog_client: FakeCatalog.new(package, resolution), store: store,
          committer: ->(*) { }
        ).call!
      end

      result = Hive::Commands::Module::Install.new(
        "honeycomb/demo", project_root: project, json: false, stdout: StringIO.new,
        stdin: StringIO.new("no\n"), yes: true, dry_run: false,
        receipt: preview.fetch("preview_receipt"),
        settings: [ "mode=safe", "api_token=" ], hooks: [ "schedule=enabled" ],
        grants: [ "filesystem_read=repository" ],
        catalog_client: FakeCatalog.new(package, resolution), store: store,
        committer: ->(*) { }
      ).call!
      assert_equal "installed", result.fetch("status")
      assert store.selected("demo")
    end
  end

  def test_interactive_install_collects_choices_and_confirms_each_permission_atom_before_apply
    with_fixture do |project, store, package, resolution|
      output = StringIO.new
      command = Hive::Commands::Module::Install.new(
        "honeycomb/demo", project_root: project, json: false, stdout: output,
        stdin: TTYInput.new("\n\nyes\nyes\nyes\n"), yes: false, dry_run: false,
        receipt: nil, settings: [], hooks: [], grants: [],
        catalog_client: FakeCatalog.new(package, resolution), store: store,
        committer: ->(*) { }
      )

      result = command.call!

      assert_equal "installed", result.fetch("status")
      configuration = store.configuration(
        "demo", store.selected("demo").dig("active", "configuration_digest")
      )
      assert_equal({ "api_token" => nil, "mode" => "safe" }, configuration.settings)
      assert_equal({ "schedule" => true }, configuration.hooks)
      assert_equal [ "repository" ], configuration.grants.fetch("filesystem_read")
      prompts = output.string
      setting = prompts.index("Setting mode")
      hook = prompts.index("Enable hook schedule")
      permission = prompts.index("Grant filesystem read: repository")
      transaction = prompts.index("Apply install for honeycomb/demo?")
      assert setting && hook && permission && transaction
      assert_operator setting, :<, hook
      assert_operator hook, :<, permission
      assert_operator permission, :<, transaction
    end
  end

  def test_interactive_install_declining_one_permission_atom_mutates_nothing
    with_fixture do |project, store, package, resolution|
      command = Hive::Commands::Module::Install.new(
        "honeycomb/demo", project_root: project, json: false, stdout: StringIO.new,
        stdin: TTYInput.new("\n\nno\nno\n"), yes: false, dry_run: false,
        receipt: nil, settings: [], hooks: [], grants: [],
        catalog_client: FakeCatalog.new(package, resolution), store: store,
        committer: ->(*) { flunk "declined permission must not commit" }
      )

      assert_raises(Hive::Commands::Module::ConsentRequired) { command.call! }
      assert_nil store.inspect_selection("demo")
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
      update_hooks = [
        {
          "id" => "schedule", "target" => { "kind" => "entrypoint", "id" => "demo.run" },
          "default_enabled" => false, "schedules" => [ "0 * * * *" ], "events" => [],
          "concurrency" => "drop"
        },
        {
          "id" => "new-hook", "target" => { "kind" => "entrypoint", "id" => "demo.new" },
          "default_enabled" => true, "schedules" => [], "events" => [ "task.completed" ],
          "concurrency" => "drop"
        }
      ]
      new_resolution, = write_module_package(
        update_root, version: "1.1.0", commit: "b" * 40, hooks: update_hooks
      )
      update_preview = Hive::Commands::Module::Update.new(
        "demo", project_root: project, json: true, stdout: StringIO.new, yes: false, dry_run: true,
        receipt: nil, settings: [], hooks: [], grants: [ "filesystem_read=repository" ],
        catalog_client: FakeCatalog.new(update_root, new_resolution), store: store, committer: ->(*) { }
      ).call!
      assert_equal true, update_preview.dig("proposed", "hooks", 0, "enabled")
      assert_equal false, update_preview.dig("proposed", "hooks", 1, "enabled")
      explicitly_enabled = Hive::Commands::Module::Update.new(
        "demo", project_root: project, json: true, stdout: StringIO.new,
        yes: false, dry_run: true, receipt: nil, settings: [],
        hooks: [ "new-hook=enabled" ], grants: [ "filesystem_read=repository" ],
        catalog_client: FakeCatalog.new(update_root, new_resolution), store: store,
        committer: ->(*) { }
      ).call!
      assert_equal true, explicitly_enabled.dig("proposed", "hooks", 1, "enabled")
      Hive::Commands::Module::Update.new(
        "demo", project_root: project, json: true, stdout: StringIO.new, yes: true, dry_run: false,
        receipt: update_preview.fetch("preview_receipt"), settings: [], hooks: [],
        grants: [ "filesystem_read=repository" ],
        catalog_client: FakeCatalog.new(update_root, new_resolution), store: store, committer: ->(*) { }
      ).call!
      assert_equal "b" * 40, store.selected("demo").dig("active", "source_commit")
      configuration = store.configuration("demo", store.selected("demo").dig("active", "configuration_digest"))
      assert_equal true, configuration.hooks.fetch("schedule")
      assert_equal({ "api_token" => nil, "mode" => "safe" }, configuration.settings)

      replay = Hive::Commands::Module::Update.new(
        "demo", project_root: project, json: true, stdout: StringIO.new, yes: true, dry_run: false,
        receipt: update_preview.fetch("preview_receipt"), settings: [], hooks: [],
        grants: [ "filesystem_read=repository" ],
        catalog_client: FakeCatalog.new(update_root, new_resolution), store: store, committer: ->(*) { }
      ).call!
      assert_equal "already_current", replay.fetch("status")

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
        project_root: project, json: true, stdout: StringIO.new, store: store,
        inspector: Hive::Modules::Inspector.new(
          store: store, project_id: "project-1"
        )
      ).call!

      assert_equal [ "demo" ], payload.fetch("modules").map { |row| row.fetch("name") }
      refute_includes JSON.generate(payload), "super-secret"
    end
  end

  def test_choice_parsers_cover_disabled_hooks_typed_values_and_grant_errors
    with_tmp_dir do |root|
      resolution, descriptor = write_module_package(File.join(root, "package"))
      command = Hive::Commands::Module::Install.new(
        "honeycomb/demo", project_root: root, json: true, stdout: StringIO.new,
        yes: false, dry_run: true, receipt: nil, settings: [], hooks: [], grants: [],
        catalog_client: FakeCatalog.new(File.join(root, "package"), resolution),
        store: Hive::ModulePackage::ManagedStore.new(File.join(root, ".hive-state")),
        committer: ->(*) { }
      )

      command.instance_variable_set(:@hook_choices, [ "schedule=disabled" ])
      assert_equal({ "schedule" => false }, command.send(:parse_hooks))
      command.instance_variable_set(:@hook_choices, [ "schedule=maybe" ])
      assert_raises(Hive::ConfigError) { command.send(:parse_hooks) }

      command.instance_variable_set(:@grant_choices, [ "future=value" ])
      assert_raises(Hive::ConfigError) { command.send(:parse_grants, descriptor, nil) }
      command.instance_variable_set(:@grant_choices, [ "repository_write" ])
      assert_equal true, command.send(:parse_grants, descriptor, nil).fetch("repository_write")
      command.instance_variable_set(:@grant_choices, [ "repository_write=false" ])
      assert_equal false, command.send(:parse_grants, descriptor, nil).fetch("repository_write")
      command.instance_variable_set(:@grant_choices, [ "repository_write=maybe" ])
      assert_raises(Hive::ConfigError) { command.send(:parse_grants, descriptor, nil) }

      boolean = { "type" => "boolean", "required" => true }
      assert_equal true, command.send(:typed_value, "yes", boolean)
      assert_equal false, command.send(:typed_value, "off", boolean)
      assert_equal "maybe", command.send(:typed_value, "maybe", boolean)
      assert_equal 42, command.send(:typed_value, "42", "type" => "integer", "required" => true)
      assert_equal 1.5, command.send(:typed_value, "1.5", "type" => "number", "required" => true)
      assert_equal "bad", command.send(:typed_value, "bad", "type" => "integer", "required" => true)
    end
  end

  def test_legacy_honeycomb_uses_the_existing_workflow_store_and_rejects_fake_disable
    with_tmp_dir do |project|
      state = File.join(project, ".hive-state")
      FileUtils.mkdir_p(File.join(state, "stages"))
      File.write(
        File.join(state, "config.yml"),
        Hive::Config::DEFAULTS.merge("hive_state_path" => ".hive-state").to_yaml
      )
      package = File.join(project, "legacy-package")
      resolution = write_legacy_package(package)
      workflow_store = Hive::WorkflowPackage::ManagedStore.new(state)
      module_store = Hive::ModulePackage::ManagedStore.new(state)
      command = lambda do |**options|
        Hive::Commands::Module::Install.new(
          "honeycomb/demo", project_root: project, json: true,
          stdout: StringIO.new, settings: [], hooks: [], grants: [],
          catalog_client: FakeCatalog.new(package, resolution),
          store: module_store, workflow_store: workflow_store,
          committer: ->(*) { }, **options
        )
      end

      preview = command.call(yes: false, dry_run: true, receipt: nil).call!
      assert_equal "preview", preview.fetch("status")
      assert_equal "workflow", preview.dig("candidate", "type")
      installed = command.call(
        yes: true, dry_run: false, receipt: preview.fetch("preview_receipt")
      ).call!
      assert_equal "installed", installed.fetch("status")
      assert workflow_store.selected("demo")
      assert_nil module_store.inspect_selection("demo", include_tombstone: true)
      refute File.exist?(File.join(state, "modules", "demo"))

      disable = Hive::Commands::Module::StateChange.new(
        "disable", "demo", project_root: project, json: true,
        stdout: StringIO.new, yes: false, dry_run: true, receipt: nil,
        store: module_store, committer: ->(*) { }
      )
      error = assert_raises(Hive::Commands::Module::OwnershipError) do
        disable.call!
      end
      assert_match(/no durable enabled state/, error.message)

      inspector = Hive::Modules::Inspector.new(
        store: module_store, workflow_store: workflow_store,
        project_config: Hive::Config.load(project), project_id: "project-1"
      )
      status = inspector.inspect("demo")
      assert_equal "active", status["lifecycle_state"]
      assert_equal "legacy_workflow", status.dig("active", "origin")
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

  def write_legacy_package(root)
    FileUtils.mkdir_p(File.join(root, "instructions"))
    File.write(File.join(root, "README.md"), "# Demo\n")
    File.write(File.join(root, "honeycomb.yml"), "name: demo\nversion: 1.0.0\n")
    File.write(File.join(root, "instructions", "work.md"), "Read only.\n")
    File.write(File.join(root, "workflow.yml"), <<~YAML)
      id: demo
      stages:
        - name: inbox
          kind: terminal
          state_file: idea.md
        - name: work
          kind: agent
          state_file: work.md
          advance_verb: work
          instruction: instructions/work.md
          permissions: read-only
        - name: done
          kind: terminal
          state_file: done.md
          advance_verb: done
    YAML
    permissions = {
      "tools" => [ "Read" ], "deny" => [ "Bash" ], "directories" => [],
      "commands" => [], "domains" => [], "credentials" => []
    }
    manifest = Hive::WorkflowPackage::Manifest.build(
      root,
      metadata: {
        "name" => "demo", "version" => "1.0.0", "summary" => "Demo",
        "author" => { "name" => "Test" }, "dependencies" => {},
        "permissions" => permissions
      }
    )
    File.binwrite(File.join(root, "manifest.json"), manifest.bytes)
    workflow_resolution = Hive::WorkflowPackage::RegistryClient::Resolution.new(
      name: "demo", version: "1.0.0", source_commit: "a" * 40,
      catalog_commit: "b" * 40, source_revision: "a" * 40,
      manifest_digest: manifest.digest, hive_min_version: "0.4.3",
      summary: "Demo", permissions: permissions
    )
    descriptor = Hive::ModulePackage::Normalizer.from_honeycomb(
      manifest, resolution: workflow_resolution
    )
    Hive::ModulePackage::CatalogClient::Resolution.new(
      name: "demo", version: "1.0.0", type: "workflow",
      source_commit: "a" * 40, catalog_commit: "b" * 40,
      source_revision: "a" * 40, manifest_digest: manifest.digest,
      summary: "Demo", package_path: "packages/demo/1.0.0",
      descriptor: descriptor
    )
  end
end
