require "test_helper"
require "hive/attempts/dispatcher"
require "hive/attempts/store"
require "hive/commands/module_hook"
require "hive/module_package/catalog_client"
require "hive/module_package/managed_store"
require "hive/module_package/preview"
require "hive/module_package/validator"
require "hive/modules/decision_journal"
require "hive/modules/dispatcher"
require "hive/modules/entrypoints"
require "hive/modules/event_ledger"

class ArchitecturePatrolModuleIntegrationTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 22, 18, 0, 0)

  class Launcher
    attr_reader :record
    def preflight! = true
    def launch(record, claim_capability:)
      @record = record
      { "claimed" => !claim_capability.empty? }
    end
  end

  def teardown
    Hive::Modules::Entrypoints.reset!
    super
  end

  def test_merged_pr_shadow_hook_uses_durable_attempt_without_touching_architecture_state
    with_tmp_global_config do
      with_tmp_dir do |project_root|
        state = File.join(project_root, ".hive-state")
        FileUtils.mkdir_p(state)
        File.write(File.join(state, "config.yml"), { "hive_state_path" => ".hive-state" }.to_yaml)
        entry = Hive::Config.register_project(name: "demo", path: project_root)
        package = File.expand_path("../../modules/architecture-patrol", __dir__)
        validation = Hive::ModulePackage::Validator.validate!(package, catalog_commit: "f" * 40)
        resolution = resolution(validation)
        store = Hive::ModulePackage::ManagedStore.new(state)
        preview = Hive::ModulePackage::Preview.build(
          operation: "install", descriptor: validation.descriptor, generation: resolution,
          current: nil, current_configuration: nil,
          settings: { "shadow_mode" => true, "dry_run" => false },
          hooks: {
            "setup" => false, "scheduled-discovery" => false,
            "merged-pr-discovery" => true, "actions" => false
          },
          grants: validation.descriptor.permissions, now: NOW - 60
        )
        store.apply(preview, package_root: package, resolution: resolution, now: NOW - 60)
        ledger = Hive::Modules::EventLedger.new(root: File.join(state, "module-runtime"))
        event = ledger.record(
          project_id: entry.fetch("project_id"), project: "demo",
          event_name: "pull_request.merged", occurred_at: NOW,
          source: { "type" => "github_pull_request", "id" => "org/repo#7" },
          idempotency_key: "pr-7", payload: {
            "repository" => "org/repo", "number" => 7, "merge_commit" => "b" * 40,
            "manifest_digest" => "a" * 64, "job_id" => "job-7"
          }, recorded_at: NOW
        ).event
        attempts = Hive::Attempts::Store.new(root: File.join(project_root, "attempts"))
        launcher = Launcher.new
        dispatcher = Hive::Modules::Dispatcher.new(
          store: store, attempt_store: attempts,
          attempt_dispatcher: Hive::Attempts::Dispatcher.new(
            store: attempts, launcher: launcher, id_generator: -> { "attempt-1" },
            capability_generator: -> { "c" * 64 }
          ),
          project_id: entry.fetch("project_id"), project: "demo",
          decision_journal: Hive::Modules::DecisionJournal.new(root: File.join(state, "module-runtime")),
          clock: -> { NOW }
        )

        result = dispatcher.dispatch(
          module_name: "architecture-patrol", hook_id: "merged-pr-discovery", event: event
        )
        assert result.launched?
        assert attempts.scan.records.fetch(0).module_hook?
        command = Hive::Commands::ModuleHook.from_argv(launcher.record["worker_argv"].drop(2))
        assert_equal 0, command.call
        refute File.exist?(File.join(state, "refactor_patrol")),
               "shadow proof cannot initialize legacy mutator state"
      end
    end
  end

  private

  def resolution(validation)
    descriptor = validation.descriptor
    Hive::ModulePackage::CatalogClient::Resolution.new(
      name: descriptor.name, version: descriptor.version, type: descriptor.type,
      source_commit: descriptor.source.fetch("revision"), catalog_commit: "f" * 40,
      source_revision: descriptor.source.fetch("revision"), manifest_digest: validation.manifest.digest,
      summary: descriptor.description, package_path: "modules/architecture-patrol/0.1.0",
      descriptor: descriptor
    )
  end
end
