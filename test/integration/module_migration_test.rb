require "test_helper"
require "json_schemer"
require "hive/module_package/catalog_client"
require "hive/module_package/managed_store"
require "hive/module_package/preview"
require "hive/module_package/validator"
require "hive/commands/module"
require "hive/commands/module/migration"
require "hive/modules/migration/patrols"
require "hive/modules/migration/report"
require "hive/modules/migration/shadow_comparator"

class ModuleMigrationIntegrationTest < Minitest::Test
  include HiveTestHelper

  START = Time.utc(2026, 7, 1)

  def test_adopts_state_in_place_and_rejects_synthetic_cutover_evidence
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      FileUtils.mkdir_p(state)
      File.write(File.join(state, "config.yml"), { "hive_state_path" => ".hive-state" }.to_yaml)
      patrol_state = File.join(state, "patrol", "state.json")
      architecture_state = File.join(state, "refactor_patrol", "legacy-proof.json")
      FileUtils.mkdir_p(File.dirname(patrol_state))
      FileUtils.mkdir_p(File.dirname(architecture_state))
      File.write(patrol_state, JSON.generate("last_run_at" => START.iso8601))
      File.write(architecture_state, JSON.generate("job_id" => "already-complete"))
      original = [ File.binread(patrol_state), File.binread(architecture_state) ]

      store = Hive::ModulePackage::ManagedStore.new(state)
      install(store, File.expand_path("../../modules/patrol", __dir__), settings: {
        "shadow_mode" => true, "trigger" => "timer", "poll_interval_sec" => 14_400,
        "task_completed_workflows" => "*", "dry_run" => false
      })
      install(store, File.expand_path("../../modules/architecture-patrol", __dir__), settings: {
        "shadow_mode" => true, "dry_run" => false
      })
      migration = Hive::Modules::Migration::Patrols.new(
        project_root: project_root, project: "demo", hive_state_path: state,
        module_store: store, quiescence_probe: ->(_name, _root) { :quiescent }
      )
      assert_raises(Hive::Commands::Module::UsageError) do
        Hive::Commands::Module::Migration.new(
          "future", project_root: project_root, json: true, stdout: StringIO.new
        ).call
      end
      adopted = migration.adopt!(now: START)
      assert_equal "shadowing", adopted.status
      status = Hive::Commands::Module::Migration.new(
        "status", project_root: project_root, json: true, stdout: StringIO.new
      ).call
      assert_equal "shadowing", status.fetch("status")
      assert_equal original, [ File.binread(patrol_state), File.binread(architecture_state) ]

      comparator = Hive::Modules::Migration::ShadowComparator.new(
        root: File.join(state, "module-runtime", "migration", "shadow")
      )
      digests = adopted.state.fetch("bindings").transform_values do |binding|
        binding.fetch("configuration_digest")
      end
      10.times do |index|
        %w[patrol architecture-patrol].each do |module_name|
          comparator.record!(
            module_name: module_name,
            trigger: {
              "kind" => "manual",
              "id" => "fixture:#{module_name}:#{index}"
            },
            module_projection:
              Hive::Modules::Migration::PatrolDecisionProjection.build(
                module_name: module_name,
                rationale: "not_due"
              ),
            configuration_digest: digests.fetch(module_name),
            occurred_at: START + (index * 24 * 60 * 60)
          )
        end
      end
      output = StringIO.new
      report = Hive::Commands::Module::Migration.new(
        "report", project_root: project_root, json: true, stdout: output,
        yes: true, reviewer: "fixture-reviewer"
      ).call
      assert_equal "evidence_required", report.fetch("status")
      assert_includes(
        report.fetch("blockers"),
        "deterministic:lane_evidence_missing"
      )
      assert_includes(
        report.fetch("blockers"),
        "installed:lane_evidence_missing"
      )
      assert_schema(
        "hive-module-shadow-decision",
        comparator.each_record.first
      )
      assert_schema("hive-module-migration-report", report)

      assert_raises(Hive::ConfigError) do
        Hive::Commands::Module::Migration.new(
          "cutover", project_root: project_root, json: true,
          stdout: StringIO.new, yes: true
        ).call
      end
      assert_equal "shadowing", migration.read.fetch("status")
      assert_equal original, [ File.binread(patrol_state), File.binread(architecture_state) ]
      assert_equal :shadow, Hive::Modules::Migration::Patrols.module_mode(
        project_root, "patrol", configured_shadow: false, hive_state_path: state
      )
    end
  end

  private

  def install(store, package, settings:)
    validation = Hive::ModulePackage::Validator.validate!(package, catalog_commit: "f" * 40)
    descriptor = validation.descriptor
    resolution = Hive::ModulePackage::CatalogClient::Resolution.new(
      name: descriptor.name, version: descriptor.version, type: descriptor.type,
      source_commit: descriptor.source.fetch("revision"), catalog_commit: "f" * 40,
      source_revision: descriptor.source.fetch("revision"), manifest_digest: validation.manifest.digest,
      summary: descriptor.description, package_path: "modules/#{descriptor.name}/#{descriptor.version}",
      descriptor: descriptor
    )
    preview = Hive::ModulePackage::Preview.build(
      operation: "install", descriptor: descriptor, generation: resolution,
      current: nil, current_configuration: nil, settings: settings,
      hooks: descriptor.hooks.to_h { |hook| [ hook.fetch("id"), false ] },
      grants: descriptor.permissions, now: START
    )
    store.apply(preview, package_root: package, resolution: resolution, now: START)
  end

  def assert_schema(name, payload)
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path(name))))
    assert schema.valid?(payload), schema.validate(payload).to_a.inspect
  end
end
