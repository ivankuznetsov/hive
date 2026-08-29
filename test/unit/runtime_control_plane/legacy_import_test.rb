require "test_helper"
require "fileutils"
require "json"
require "sequel"
require "yaml"
require "hive/runtime_control_plane/legacy_import"

class RuntimeControlPlaneLegacyImportTest < Minitest::Test
  include HiveTestHelper

  FIXTURE_ROOT = File.expand_path(
    "../../fixtures/runtime_control_plane/legacy_home", __dir__
  ).freeze
  BASELINE_PATH = File.expand_path(
    "../../fixtures/runtime_control_plane/affected_production.yml", __dir__
  ).freeze

  def test_golden_fixture_is_deterministic_and_every_source_is_classified_once
    with_fixture_home do |state_home, data_home, project_root|
      first = importer(state_home, data_home, project_root).call
      second = importer(state_home, data_home, project_root).call

      assert_equal first.digest, second.digest
      assert_equal first.to_h, second.to_h
      identities = first.ledger.map { |entry| entry.fetch("source_identity") }
      assert_equal identities.uniq.sort, identities.sort
      assert first.ledger.all? { |entry| %w[imported superseded proven_empty].include?(entry.fetch("disposition")) }
      assert_equal 1, first.records.fetch("dispatch_requests").length
      assert_equal 1, first.records.fetch("dispatch_sequence").length
      assert_equal 1, first.records.fetch("attempts").length
      assert_equal 1, first.records.fetch("usage_sessions").length
      assert_equal 1, first.records.fetch("pr_merge_reconciliations").length
      assert_equal 1, first.records.fetch("task_projections").length
      assert_equal 2, first.records.fetch("retained_payloads").length
    end
  end

  def test_claimed_requests_live_attempts_and_task_leases_must_be_proven_empty
    with_fixture_home do |state_home, data_home, project_root|
      claimed = File.join(state_home, "dispatch_requests", "claimed.json.claimed")
      File.binwrite(claimed, JSON.generate("schema" => "hive-dispatch-request", "request_id" => "claimed"))
      error = assert_raises(Hive::RuntimeControlPlane::LegacyImport::QuiescenceError) do
        importer(state_home, data_home, project_root).call
      end
      assert_equal :claimed_dispatch_request, error.code
      File.unlink(claimed)

      attempt = File.join(state_home, "attempts", "v4", "records", "attempt-1.json")
      bytes = JSON.parse(File.binread(attempt)).merge("state" => "running")
      File.binwrite(attempt, JSON.generate(bytes))
      error = assert_raises(Hive::RuntimeControlPlane::LegacyImport::QuiescenceError) do
        importer(state_home, data_home, project_root).call
      end
      assert_equal :live_attempt, error.code
      File.unlink(attempt)

      lease = File.join(project_root, ".hive", "tasks", "task-1", ".lock")
      FileUtils.mkdir_p(File.dirname(lease))
      File.binwrite(lease, "held")
      File.open(lease, File::RDWR) do |held|
        held.flock(File::LOCK_EX)
        error = assert_raises(Hive::RuntimeControlPlane::LegacyImport::QuiescenceError) do
          importer(state_home, data_home, project_root).call
        end
        assert_equal :active_task_lease, error.code
      end
    end
  end

  def test_capacity_reservations_and_provider_probes_must_be_proven_empty
    with_fixture_home do |state_home, data_home, project_root|
      capacity = File.join(
        state_home, "attempts", "v4", "decision-indexes", "live-capacity", "host.json"
      )
      document = JSON.parse(File.binread(capacity))
      document["value"]["reservations"] = {
        "attempt-1" => { "phase" => "active", "project" => "alpha", "task_slug" => "task-1" }
      }
      File.binwrite(capacity, JSON.generate(document))
      error = assert_raises(Hive::RuntimeControlPlane::LegacyImport::QuiescenceError) do
        importer(state_home, data_home, project_root).call
      end
      assert_equal :active_capacity_reservation, error.code
      document["value"]["reservations"] = {}
      File.binwrite(capacity, JSON.generate(document))

      health = File.join(state_home, "provider-health", "v1", "account.json")
      document = JSON.parse(File.binread(health)).merge(
        "probe" => { "attempt_id" => "attempt-1", "generation" => 2 }
      )
      File.binwrite(health, JSON.generate(document))
      error = assert_raises(Hive::RuntimeControlPlane::LegacyImport::QuiescenceError) do
        importer(state_home, data_home, project_root).call
      end
      assert_equal :in_flight_probe, error.code
    end
  end

  def test_real_provider_probe_intent_must_be_proven_empty
    with_fixture_home do |state_home, data_home, project_root|
      intents = File.join(state_home, "provider-health", "v1", "intents")
      FileUtils.mkdir_p(intents)
      path = File.join(intents, "probe.json")
      File.binwrite(
        path,
        JSON.generate(
          "schema" => "hive-provider-health-probe-intent",
          "schema_version" => 1,
          "intent" => {
            "attempt_id" => "attempt-1", "intent_id" => "intent-1",
            "ownership_fence" => "fence-1", "requirements" => [],
            "task_generation" => 3
          },
          "bindings" => []
        )
      )

      error = assert_raises(Hive::RuntimeControlPlane::LegacyImport::QuiescenceError) do
        importer(state_home, data_home, project_root).call
      end
      assert_equal :in_flight_probe, error.code
      assert_equal path, error.path
    end
  end

  def test_malformed_duplicate_and_cross_project_records_fail_with_typed_results
    with_fixture_home do |state_home, data_home, project_root|
      record = File.join(state_home, "dispatch_results", "result-1.json")
      duplicate = File.join(state_home, "dispatch_results", "result-duplicate.json")
      FileUtils.cp(record, duplicate)
      error = assert_raises(Hive::RuntimeControlPlane::LegacyImport::ClassificationError) do
        importer(state_home, data_home, project_root).call
      end
      assert_equal :duplicate_source_identity, error.code
      File.unlink(duplicate)

      File.binwrite(record, "[")
      error = assert_raises(Hive::RuntimeControlPlane::LegacyImport::ClassificationError) do
        importer(state_home, data_home, project_root).call
      end
      assert_equal :malformed_source, error.code

      FileUtils.cp(File.join(FIXTURE_ROOT, "state", "dispatch_results", "result-1.json"), record)
      reconciliation = File.join(
        project_root, ".hive-state", "daemon", "pr-merge-reconciliation.json"
      )
      document = JSON.parse(File.binread(reconciliation)).merge("project" => "other")
      File.binwrite(reconciliation, JSON.generate(document))
      error = assert_raises(Hive::RuntimeControlPlane::LegacyImport::ClassificationError) do
        importer(state_home, data_home, project_root).call
      end
      assert_equal :cross_project_record, error.code
    end
  end

  def test_orphaned_retired_root_is_found_independently_of_project_registration
    with_fixture_home do |state_home, data_home, project_root|
      orphan = File.join(state_home, "provider-health", "v1", "orphan.bin")
      FileUtils.mkdir_p(File.dirname(orphan))
      File.binwrite(orphan, "not-json")

      error = assert_raises(Hive::RuntimeControlPlane::LegacyImport::ClassificationError) do
        importer(state_home, data_home, project_root).call
      end
      assert_equal :malformed_source, error.code
      assert_equal orphan, error.path
      File.unlink(orphan)

      unattributed = File.join(state_home, "attempts", "v4", "unattributed")
      FileUtils.mkdir_p(unattributed)
      File.binwrite(File.join(unattributed, "state.json"), "{}")
      error = assert_raises(Hive::RuntimeControlPlane::LegacyImport::ClassificationError) do
        importer(state_home, data_home, project_root).call
      end
      assert_equal :unattributed_source, error.code
      assert_equal File.join(state_home, "attempts", "v4"), error.path
    end
  end

  def test_affected_production_baseline_reproduces_at_pinned_commit
    manifest = YAML.safe_load_file(BASELINE_PATH, permitted_classes: [], aliases: false)
    assert_equal "1eab41d6b4bdac6664dc1e94ad1ccfb6ef604dd1", manifest.fetch("base_commit")
    assert_equal 9_951, manifest.fetch("baseline_lines")
    assert_equal "physical_source_lines", manifest.fetch("counting_rule")
    assert_includes manifest.fetch("legacy_writers"), "Hive::Attempts::Store"
    assert_equal "require_empty", manifest.dig("domains", "capacity_reservations")
    assert_equal %w[HIVE_ATTEMPT_STORE_ROOT HIVE_USAGE_DB_PATH],
                 manifest.fetch("path_overrides")
    assert_includes manifest.fetch("required_absences"), "runtime-control-plane.sqlite3"

    observed = manifest.fetch("paths").sum do |entry|
      bytes = `git show #{manifest.fetch("base_commit")}:#{entry.fetch("path")}`
      assert $CHILD_STATUS.success?, entry.fetch("path")
      lines = bytes.lines.length
      assert_equal entry.fetch("lines"), lines, entry.fetch("path")
      lines
    end
    assert_equal 9_951, observed
  end

  def test_attempt_and_usage_path_overrides_are_inventoried
    with_fixture_home do |state_home, data_home, project_root|
      scratch = File.dirname(state_home)
      attempt_root = File.join(scratch, "custom", "attempts")
      usage_path = File.join(scratch, "custom", "usage.sqlite3")
      FileUtils.mkdir_p(File.dirname(attempt_root))
      FileUtils.mv(File.join(state_home, "attempts", "v4"), attempt_root)
      FileUtils.mv(File.join(data_home, "usage.db"), usage_path)
      FileUtils.mv(
        File.join(data_home, "usage.db.patrol-discovery-allowances"),
        "#{usage_path}.patrol-discovery-allowances"
      )

      result = importer(
        state_home, data_home, project_root,
        attempt_root: attempt_root, usage_path: usage_path
      ).call

      assert_equal 1, result.records.fetch("attempts").length
      assert_equal 1, result.records.fetch("usage_sessions").length
      assert_equal 1, result.records.fetch("patrol_allowances").length
      assert result.ledger.any? do |entry|
        entry.fetch("source_identity").start_with?("retained_payloads:attempts/v4/")
      end
    end
  end

  def test_normal_runtime_entrypoint_does_not_load_frozen_decoders
    ruby = <<~'RUBY'
      $LOAD_PATH.unshift File.expand_path("lib", Dir.pwd)
      require "hive/runtime_control_plane"
      abort "legacy importer loaded" if $LOADED_FEATURES.any? { |path| path.end_with?("runtime_control_plane/legacy_import.rb") }
    RUBY
    assert system(RbConfig.ruby, "-e", ruby)
  end

  def test_recovery_inventory_entrypoint_loads_decoder_only_when_called
    ruby = <<~'RUBY'
      $LOAD_PATH.unshift File.expand_path("lib", Dir.pwd)
      require "hive/recovery/migration"
      abort "legacy importer loaded eagerly" if $LOADED_FEATURES.any? { |path| path.end_with?("runtime_control_plane/legacy_import.rb") }
    RUBY
    assert system(RbConfig.ruby, "-e", ruby)
  end

  def test_recovery_inventory_entrypoint_uses_the_frozen_decoder
    with_fixture_home do |state_home, data_home, project_root|
      require "hive/recovery/migration"
      direct = importer(state_home, data_home, project_root).call
      recovered = Hive::Recovery::Migration.inventory_runtime(
        state_home: state_home, data_home: data_home, project_roots: [ project_root ]
      )
      assert_equal direct.digest, recovered.digest
      assert_equal direct.ledger, recovered.ledger
    end
  end

  private

  def with_fixture_home
    with_tmp_dir do |root|
      FileUtils.cp_r(File.join(FIXTURE_ROOT, "."), root)
      state_home = File.join(root, "state")
      data_home = File.join(root, "data")
      project_root = File.join(root, "projects", "alpha")
      build_usage_database(File.join(data_home, "usage.db"))
      yield state_home, data_home, project_root
    end
  end

  def build_usage_database(path)
    FileUtils.mkdir_p(File.dirname(path))
    database = Sequel.sqlite(path)
    database.create_table(:token_usage) do
      String :id, primary_key: true
      String :agent, null: false
      String :started_at, null: false
      String :attempt_id
      String :session_id
      Integer :task_generation
    end
    database[:token_usage].insert(
      id: "usage-1", agent: "codex", started_at: "2026-08-29T12:00:00.000000Z",
      attempt_id: "attempt-1", session_id: "session-1", task_generation: 3
    )
  ensure
    database&.disconnect
  end

  def importer(state_home, data_home, project_root, **options)
    Hive::RuntimeControlPlane::LegacyImport.new(
      state_home: state_home, data_home: data_home, project_roots: [ project_root ],
      **options
    )
  end
end
