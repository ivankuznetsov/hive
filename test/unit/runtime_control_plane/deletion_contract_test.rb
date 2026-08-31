require "test_helper"
require "open3"
require "yaml"
require "hive/runtime_control_plane/cutover"

class RuntimeControlPlaneDeletionContractTest < Minitest::Test
  include HiveTestHelper

  ROOT = File.expand_path("../../..", __dir__)
  INVENTORY = File.join(ROOT, "test/fixtures/runtime_control_plane/affected_production.yml")
  PRODUCTION_PATHS = %w[bin lib schemas install.sh packaging web/config].freeze
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
    lib/hive/provider_health/store.rb
    lib/hive/recovery/migration.rb
    lib/hive/runtime_control_plane/diagnostics.rb
    lib/hive/runtime_control_plane/identity.rb
    lib/hive/runtime_control_plane/legacy_import.rb
  ].freeze
  RETIRED_SCHEMA_FILES = %w[
    schemas/hive-attempt.v3.json
    schemas/hive-attempt.v4.json
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
    Hive::ProviderHealth::Store
    Hive::ProviderRouting::PolicyStore
  ].freeze
  RETIRED_ENVIRONMENT_PATHS = %w[HIVE_ATTEMPT_STORE_ROOT HIVE_USAGE_DB_PATH].freeze
  RETAINED_FILE_STORES = %w[
    lib/hive/artifact_firewall.rb
    lib/hive/atomic_file.rb
    lib/hive/managed_directory.rb
    lib/hive/task_journal.rb
    lib/hive/task_projection/store.rb
    lib/hive/workflow_package/publish_store.rb
  ].freeze

  def test_final_affected_inventory_is_exact_and_at_least_twenty_percent_smaller
    inventory = YAML.safe_load_file(INVENTORY, permitted_classes: [], aliases: false)
    entries = inventory.fetch("final_paths")
    observed = entries.sum do |entry|
      path = File.join(ROOT, entry.fetch("path"))
      assert_path_exists path
      lines = File.foreach(path).count
      assert_equal entry.fetch("lines"), lines, entry.fetch("path")
      lines
    end

    assert_equal entries.map { |entry| entry.fetch("path") }.uniq.length, entries.length
    outside_net = outside_inventory_net_lines(inventory, entries)
    final_lines = observed + outside_net
    assert_equal inventory.fetch("final_inventory_lines"), observed
    assert_equal inventory.fetch("outside_inventory_net_lines"), outside_net
    assert_equal inventory.fetch("final_lines"), final_lines
    assert_operator final_lines, :<=, inventory.fetch("maximum_final_lines")
    assert_operator final_lines, :<=, (inventory.fetch("baseline_lines") * 0.8).floor
    assert_equal affected_production_files(inventory),
                 entries.map { |entry| entry.fetch("path") }.sort
  end

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

  private

  def affected_production_files(inventory)
    retained = inventory.fetch("paths").filter_map do |entry|
      entry.fetch("path") if File.file?(File.join(ROOT, entry.fetch("path")))
    end
    added = changed_production_files(inventory).filter_map do |status_code, path|
      path if status_code == "A" && File.file?(File.join(ROOT, path))
    end
    (retained + added).uniq.sort
  end

  def outside_inventory_net_lines(inventory, entries)
    classified = inventory.fetch("paths").map { |entry| entry.fetch("path") } +
      entries.map { |entry| entry.fetch("path") }
    changed_production_files(inventory).sum do |_status_code, path|
      next 0 if classified.include?(path)

      current = File.file?(File.join(ROOT, path)) ? File.foreach(File.join(ROOT, path)).count : 0
      current - base_line_count(inventory.fetch("base_commit"), path)
    end
  end

  def changed_production_files(inventory)
    output, error, status = Open3.capture3(
      "git", "diff", "--name-status", "--no-renames", inventory.fetch("base_commit"),
      "--", *PRODUCTION_PATHS, chdir: ROOT
    )
    assert status.success?, error
    changed = output.lines.map do |line|
      status_code, path = line.chomp.split("\t", 2)
      [ status_code, path ]
    end
    status_output, status_error, status = Open3.capture3(
      "git", "status", "--porcelain", "--untracked-files=all", chdir: ROOT
    )
    assert status.success?, status_error
    untracked = status_output.lines.filter_map do |line|
      path = line[3..].to_s.strip
      [ "A", path ] if line[0, 2] == "??" && production_path?(path)
    end
    (changed + untracked).uniq
  end

  def production_path?(path)
    path == "install.sh" || path.match?(%r{\A(?:bin|lib|schemas|packaging|web/config)/})
  end

  def base_line_count(commit, path)
    output, _error, status = Open3.capture3("git", "show", "#{commit}:#{path}", chdir: ROOT)
    status.success? ? output.lines.count : 0
  end
end
