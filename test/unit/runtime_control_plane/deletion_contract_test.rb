require "test_helper"
require "hive/runtime_control_plane/cutover"

class RuntimeControlPlaneDeletionContractTest < Minitest::Test
  include HiveTestHelper

  ROOT = File.expand_path("../../..", __dir__)
  RETIRED_SOURCE_FILES = %w[
    lib/hive/attempts/decision_index.rb
    lib/hive/attempts/pending_finalization_store.rb
    lib/hive/attempts/permanent_proof_store.rb
    lib/hive/attempts/point_storage.rb
    lib/hive/attempts/record_migration.rb
    lib/hive/attempts/storage_health.rb
    lib/hive/attempts/store.rb
    lib/hive/daemon/dispatch_request_queue.rb
    lib/hive/daemon/dispatch_result_queue.rb
    lib/hive/daemon/pr_merge_reconciliation_store.rb
    lib/hive/daemon/queue_directory.rb
    lib/hive/point_storage.rb
    lib/hive/commands/circuits.rb
    lib/hive/provider_health.rb
    lib/hive/provider_health/attempt_observer.rb
    lib/hive/provider_health/audit.rb
    lib/hive/provider_health/circuit.rb
    lib/hive/provider_health/event.rb
    lib/hive/provider_health/evidence.rb
    lib/hive/provider_health/repository.rb
    lib/hive/provider_health/store.rb
    lib/hive/provider_routing/operational_projection.rb
    lib/hive/provider_routing/policy_repository.rb
    lib/hive/recovery/migration.rb
    lib/hive/runtime_control_plane/diagnostics.rb
    lib/hive/runtime_control_plane/identity.rb
    lib/hive/runtime_control_plane/legacy_import.rb
  ].freeze
  RETIRED_SCHEMA_FILES = %w[
    schemas/hive-attempt.v3.json
    schemas/hive-attempt.v4.json
    schemas/hive-circuits.v1.json
    schemas/hive-pr-merge-reconciliation.v1.json
    schemas/hive-provider-health-event.v1.json
    schemas/hive-provider-health.v1.json
    schemas/hive-routing-policy.v1.json
  ].freeze
  RETIRED_CONSTANTS = %w[
    Hive::Attempts::DecisionIndex
    Hive::Attempts::PendingFinalizationStore
    Hive::Attempts::PermanentProofStore
    Hive::Attempts::RecordMigration
    Hive::Attempts::StorageHealth
    Hive::Attempts::Store
    Hive::Daemon::DispatchRequestQueue
    Hive::Daemon::DispatchResultQueue
    Hive::Daemon::PrMergeReconciliationStore
    Hive::ProviderHealth
    Hive::ProviderRouting::OperationalProjection
    Hive::ProviderRouting::PolicyRepository
    Hive::ProviderRouting::PolicyStore
  ].freeze
  RETIRED_ENVIRONMENT_PATHS = %w[HIVE_ATTEMPT_STORE_ROOT HIVE_USAGE_DB_PATH].freeze
  RETAINED_FILE_STORES = %w[
    lib/hive/artifact_firewall.rb
    lib/hive/atomic_file.rb
    lib/hive/managed_directory.rb
    lib/hive/task_journal.rb
    lib/hive/task_projection/reader.rb
    lib/hive/workflow_package/publish_store.rb
  ].freeze
  CURRENT_OPERATOR_GUIDES = %w[
    skills/hive/references/status-and-watch.md
    openclaw/skills/hive/references/status-and-watch.md
    wiki/cli.md
  ].freeze

  def test_retired_runtime_sources_schemas_and_constants_are_absent
    (RETIRED_SOURCE_FILES + RETIRED_SCHEMA_FILES).each do |relative|
      refute_path_exists File.join(ROOT, relative), relative
    end

    production = Dir.glob(File.join(ROOT, "{bin,lib}/**/*")).select { |path| File.file?(path) }
    RETIRED_CONSTANTS.each do |constant|
      offenders = production.select { |path| File.binread(path).include?(constant) }
      assert_empty offenders, "#{constant} remains in #{offenders.map { |path| path.delete_prefix("#{ROOT}/") }}"
    end
  end

  def test_legacy_decoder_is_absent_and_retired_environment_paths_are_not_runtime_inputs
    refute $LOADED_FEATURES.any? { |path| path.end_with?("/runtime_control_plane/legacy_import.rb") }

    production = Dir.glob(File.join(ROOT, "{bin,lib}/**/*")).select { |path| File.file?(path) }
    RETIRED_ENVIRONMENT_PATHS.each do |name|
      offenders = production.select { |path| File.binread(path).include?(name) }
      assert_empty offenders, "#{name} remains in #{offenders.map { |path| path.delete_prefix("#{ROOT}/") }}"
    end
    decoder_references = production.select { |path| File.binread(path).include?("LegacyImport") }
    assert_empty decoder_references
  end

  def test_clean_bootstrap_never_creates_a_retired_runtime_root
    with_tmp_dir do |root|
      state = File.join(root, "state")
      data = File.join(root, "data")
      FileUtils.mkdir_p([ state, data ])
      services = Struct.new(:events) do
        def stop!(**) = events << :stopped
        def activate! = events << :active
      end.new([])

      Hive::RuntimeControlPlane::Cutover.new(
        state_home: state, data_home: data, projects: [], services: services
      ).bootstrap(confirm: true)

      assert_path_exists Hive::Paths.runtime_control_plane_path(state)
      assert_path_exists Hive::Paths.runtime_payload_root(state)
      Hive::RuntimeControlPlane::Cutover::TARGETS.each do |target|
        home = target.home == :state ? state : data
        refute_path_exists File.join(home, target.relative_path), target.relative_path
      end
    end
  end

  def test_unrelated_task_workflow_and_artifact_file_stores_remain
    RETAINED_FILE_STORES.each { |relative| assert_path_exists File.join(ROOT, relative) }
  end

  def test_current_operator_guides_do_not_advertise_the_retired_circuits_command
    CURRENT_OPERATOR_GUIDES.each do |relative|
      refute_includes File.binread(File.join(ROOT, relative)), "hive circuits", relative
    end
  end
end
