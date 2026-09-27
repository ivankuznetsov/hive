# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "digest"
require "fileutils"
require "json"
require "socket"
require "tmpdir"
require "yaml"
require "hive/command_maintenance_authority"
require "hive/command_receipt_maintenance"
require "hive/command_receipt_pruner"
require "hive/command_receipt_store"
require "hive/paths"
require "hive/runtime_control_plane"
require "hive/runtime_control_plane/command_schema_installation"

module CommandReceiptMeasurement
  SAMPLE_COUNT = Integer(ENV.fetch("HIVE_RECEIPT_MEASUREMENT_SAMPLES", "100"))
  MAXIMUM_RESULT_BYTES = 220 * 1024
  PACKAGE = {
    version: "0.0.0-qualification",
    location: "https://example.invalid/command-receipt-compat.gem",
    sha256: "9" * 64
  }.freeze

  module_function

  def run
    Dir.mktmpdir("hive-command-receipt-measurement") do |dir|
      project, database, store, maintenance, pruner = environment(dir)
      settlements = measure_settlement(
        project, database, store, maintenance, count: SAMPLE_COUNT
      )
      finalization = measure_maximum_finalization(project, database, store)
      prune = measure_prune(database, pruner)
      puts JSON.pretty_generate(
        "schema" => "hive-command-receipt-measurement",
        "schema_version" => 1,
        "ruby" => RUBY_DESCRIPTION,
        "sqlite" => SQLite3::SQLITE_VERSION,
        "page_size" => pragma(database, "page_size"),
        "journal_mode" => database.read { |db| db.fetch("PRAGMA journal_mode").first.values.first },
        "settlement" => settlements,
        "maximum_finalization" => finalization,
        "prune_batch" => prune
      )
    ensure
      database&.disconnect
    end
  end

  def environment(dir)
    project = File.join(dir, "project")
    FileUtils.mkdir_p(File.join(project, ".hive-state"))
    File.write(
      File.join(project, ".hive-state", "config.yml"),
      { "command_receipts" => { "keyed_intake_enabled" => true } }.to_yaml
    )
    system("git", "init", "--quiet", project, exception: true)
    state = File.join(dir, "state")
    FileUtils.mkdir_p(state, mode: 0o700)
    database = Hive::RuntimeControlPlane::Database.new(
      path: Hive::Paths.runtime_control_plane_path(state)
    ).migrate!
    Hive::RuntimeControlPlane::CommandSchemaInstallation.install!(
      database: database, package_coordinates: PACKAGE
    )
    store = Hive::CommandReceiptStore.new(database: database)
    authority = Hive::CommandMaintenanceAuthority.new(
      principal: "owner", principal_source: "qualification",
      installation_owner: true
    )
    [
      project, database, store,
      Hive::CommandReceiptMaintenance.new(database: database, authority: authority),
      Hive::CommandReceiptPruner.new(database: database, authority: authority)
    ]
  end

  def measure_settlement(project, database, store, maintenance, count:)
    durations = count.times.map do |index|
      claim = store.reserve(
        project_root: project, key: "settlement-#{index}", command: "approve",
        target: "task-#{index}", request: {}, principal: "owner", execute: true,
        owner_process_start: "qualification"
      )
      effect = store.prepare_effect(
        claim, ordinal: 0, kind: "approve:default", identity: { "target" => "task-#{index}" }
      )
      observation = {
        "source" => "qualification_provider",
        "correlation_id" => "provider-operation-#{index}",
        "evidence" => { "observed_state" => "applied", "revision" => index }
      }
      store.record_effect_observation(
        receipt_id: claim.receipt_id, effect_id: effect.fetch(:effect_id),
        principal: claim.principal, request_fingerprint: claim.request_fingerprint,
        **observation.transform_keys(&:to_sym)
      )
      result = replay_result("settled-#{index}")
      store.complete_effect(claim, effect_id: effect.fetch(:effect_id), result: result, status: 0)
      store.mark_unresolved(claim, reason: "qualification_lost_final_acknowledgement")
      row = store.receipt(claim.receipt_id)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      persisted_effect = database.read do |db|
        db[:command_effects][receipt_id: claim.receipt_id, ordinal: 0]
      end
      persisted = Hive::RuntimeControlPlane::Codec.load_json(
        persisted_effect.fetch(:evidence_json)
      )
      authoritative_observation = Array(persisted.fetch("observations")).find do |entry|
        entry["source"] == "qualification_provider"
      end
      evidence = {
        "outcome" => "succeeded",
        "result" => persisted.fetch("authoritative_result"),
        "effects" => [ {
          "effect_id" => persisted_effect.fetch(:effect_id),
          "ordinal" => persisted_effect.fetch(:ordinal),
          "identity_sha256" => Digest::SHA256.hexdigest(
            persisted_effect.fetch(:identity_json)
          ),
          "observation" => authoritative_observation
        } ]
      }
      maintenance.retire_with_evidence(
        claim.receipt_id, expected_generation: row.fetch(:generation),
        evidence: evidence, reason: "qualification exact provider correlation",
        confirm: false
      )
      maintenance.retire_with_evidence(
        claim.receipt_id, expected_generation: row.fetch(:generation),
        evidence: evidence, reason: "qualification exact provider correlation",
        confirm: true
      )
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end
    milliseconds = durations.map { |value| value * 1_000 }.sort
    p50 = percentile(milliseconds, 0.50)
    p95 = percentile(milliseconds, 0.95)
    {
      "samples" => count,
      "workflow" => "read exact provider observation, build evidence, preview, confirm",
      "p50_ms" => p50.round(3), "p95_ms" => p95.round(3),
      "p95_minutes" => (p95 / 60_000).round(8),
      "conditional_receipts_per_day" => {
        "T_absent" => nil,
        "T_0_minutes" => 0,
        "T_30_minutes_at_lab_p95" => (30 / (p95 / 60_000)).floor
      }
    }
  end

  def measure_maximum_finalization(project, database, store)
    claim = store.reserve(
      project_root: project, key: "maximum-finalization", command: "approve",
      target: "maximum", request: {}, principal: "owner", execute: true,
      owner_process_start: "qualification"
    )
    effect = store.prepare_effect(
      claim, ordinal: 0, kind: "approve:default", identity: { "target" => "maximum" }
    )
    result = replay_result("x" * MAXIMUM_RESULT_BYTES)
    store.complete_effect(claim, effect_id: effect.fetch(:effect_id), result: result, status: 0)
    checkpoint(database)
    before = allocation(database)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    store.succeed(claim, result: result, status: 0)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    after = allocation(database)
    {
      "payload_bytes" => MAXIMUM_RESULT_BYTES,
      "elapsed_ms" => (elapsed * 1_000).round(3),
      "main_allocated_delta_bytes" => after.fetch("main_allocated_bytes") -
        before.fetch("main_allocated_bytes"),
      "wal_growth_bytes" => after.fetch("wal_bytes") - before.fetch("wal_bytes"),
      "total_physical_delta_bytes" => after.fetch("total_physical_bytes") -
        before.fetch("total_physical_bytes")
    }
  end

  def measure_prune(database, pruner)
    cutoff = Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc - 31 * 86_400)
    database.transaction do |db|
      ids = db[:command_receipts].where(state: "succeeded").limit(100).select_map(:receipt_id)
      db[:command_receipts].where(receipt_id: ids).update(terminal_at: cutoff)
    end
    checkpoint(database)
    before = allocation(database)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = pruner.prune(
      namespace_id: database.read { |db| db[:command_namespaces].first.fetch(:namespace_id) },
      limit: 100
    )
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    after = allocation(database)
    {
      "candidate_limit" => 100,
      "deleted" => result.fetch("outcomes").count { |row| row.fetch("outcome") == "deleted" },
      "elapsed_ms" => (elapsed * 1_000).round(3),
      "main_allocated_delta_bytes" => after.fetch("main_allocated_bytes") -
        before.fetch("main_allocated_bytes"),
      "wal_growth_bytes" => after.fetch("wal_bytes") - before.fetch("wal_bytes"),
      "reusable_page_delta" => after.fetch("freelist_pages") - before.fetch("freelist_pages")
    }
  end

  def replay_result(value)
    payload = { "schema" => "hive-approve", "schema_version" => 2, "ok" => true, "value" => value }
    {
      "format" => "json", "payload" => payload,
      "expanded_sha256" => Digest::SHA256.hexdigest(
        Hive::RuntimeControlPlane::Codec.dump_json(payload)
      )
    }
  end

  def checkpoint(database)
    database.read { |db| db.fetch("PRAGMA wal_checkpoint(TRUNCATE)").all }
  end

  def allocation(database)
    page_size = pragma(database, "page_size")
    pages = pragma(database, "page_count")
    freelist = pragma(database, "freelist_count")
    wal = File.exist?("#{database.path}-wal") ? File.size("#{database.path}-wal") : 0
    {
      "main_allocated_bytes" => pages * page_size,
      "occupied_main_bytes" => (pages - freelist) * page_size,
      "freelist_pages" => freelist,
      "wal_bytes" => wal,
      "total_physical_bytes" => pages * page_size + wal
    }
  end

  def pragma(database, name)
    database.read { |db| Integer(db.fetch("PRAGMA #{name}").first.values.first) }
  end

  def percentile(values, fraction)
    values.fetch([ (values.length * fraction).ceil - 1, 0 ].max)
  end
end

CommandReceiptMeasurement.run if $PROGRAM_NAME == __FILE__
