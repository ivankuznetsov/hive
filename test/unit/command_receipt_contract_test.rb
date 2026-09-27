# frozen_string_literal: true

require "test_helper"
require "hive/command_maintenance_authority"
require "hive/command_mutations"
require "hive/command_operation"
require "hive/command_receipt_capacity"
require "hive/command_receipt_maintenance"
require "hive/command_receipt_pruner"
require "hive/command_receipt_store"
require "hive/commands/receipt"
require "hive/commands/act"
require "hive/commands/answer"
require "hive/commands/approve"
require "hive/commands/new"
require "hive/commands/setup"
require "hive/commands/stage_action"
require "hive/commands/web/service_installer"
require "hive/cli"
require "hive/runtime_control_plane/admission_transition"
require "hive/runtime_control_plane/command_schema_installation"
require "hive/runtime_control_plane/command_schema_writer_guard"
require "hive/runtime_control_plane/installation"

class CommandReceiptContractTest < Minitest::Test
  include HiveTestHelper

  FakeClaim = Data.define(:state, :result, :public_receipt)
  TEST_PACKAGE = {
    version: "0.0.0-test", location: "https://example.invalid/compat.gem", sha256: "f" * 64
  }.freeze

  class Recorder
    attr_reader :calls

    def initialize(result = { "ok" => true })
      @result = result
      @calls = []
    end

    def method_missing(name, *args, **kwargs)
      @calls << [ name, args, kwargs ]
      @result
    end

    def respond_to_missing?(*_args) = true
  end

  def test_receipt_command_routes_every_operation_and_formats_output
    pruner = Recorder.new("route" => "prune")
    maintenance = Recorder.new("route" => "maintenance")

    preview = Hive::Commands::Receipt.new("prune", pruner: pruner)
    assert_equal({ "route" => "prune" }, preview.send(:execute))
    assert_equal :preview, pruner.calls.last.first
    confirmed = Hive::Commands::Receipt.new("prune", confirm: true, pruner: pruner)
    assert_equal({ "route" => "prune" }, confirmed.send(:execute))
    assert_equal :prune, pruner.calls.last.first

    {
      "settle_without_result" => { settle_without_result: true },
      "orphaned_owner" => { orphaned_owner: true }
    }.each do |method, options|
      command = Hive::Commands::Receipt.new(
        "retire", "receipt-1", expected_generation: 2, reason: "because",
        maintenance: maintenance, **options
      )
      assert_equal({ "route" => "maintenance" }, command.send(:execute))
      assert_equal method.to_sym, maintenance.calls.last.first
    end

    with_tmp_dir do |dir|
      evidence = File.join(dir, "evidence.json")
      File.write(evidence, JSON.generate("outcome" => "succeeded", "result" => { "ok" => true }))
      command = Hive::Commands::Receipt.new(
        "retire", "receipt-1", evidence: evidence, reason: "verified",
        maintenance: maintenance
      )
      command.send(:execute)
      assert_equal :retire_with_evidence, maintenance.calls.last.first
      assert_equal "succeeded", maintenance.calls.last.last.fetch(:evidence).fetch("outcome")
    end

    Hive::Commands::Receipt.new(
      "release-pin", "pin-1", force: true, reason: "done", maintenance: maintenance
    ).send(:execute)
    assert_equal :release_pin, maintenance.calls.last.first
    Hive::Commands::Receipt.new(
      "abandon-batch", "batch-1", reason: "dead", maintenance: maintenance
    ).send(:execute)
    assert_equal :abandon_batch, maintenance.calls.last.first

    assert_raises(Hive::UsageError) do
      Hive::Commands::Receipt.new("retire", "receipt-1", maintenance: maintenance).send(:execute)
    end
    assert_raises(Hive::UsageError) do
      Hive::Commands::Receipt.new("mystery").send(:execute)
    end
    assert_equal "hive-receipt-prune", preview.envelope_schema
    assert_equal "hive-command-receipt", Hive::Commands::Receipt.new("retire").envelope_schema

    json = Hive::Commands::Receipt.new("prune", json: true, pruner: pruner)
    out, = capture_io { assert_equal({ "route" => "prune" }, json.call) }
    assert_equal({ "route" => "prune" }, JSON.parse(out))
    pretty = Hive::Commands::Receipt.new("prune", pruner: pruner)
    out, = capture_io { pretty.call }
    assert_equal JSON.pretty_generate("route" => "prune") + "\n", out
    assert_includes out, "  \"route\""
  end

  def test_receipt_command_validates_keys_projects_namespaces_enrollment_and_evidence
    command = Hive::Commands::Receipt.new("retire", idempotency_key: "key")
    assert_raises(Hive::UsageError) { command.send(:reject_forbidden_key!) }
    assert_raises(Hive::UsageError) do
      Hive::Commands::Receipt.new("prune", idempotency_key: "key").send(:reject_forbidden_key!)
    end
    Hive::Commands::Receipt.new(
      "prune", idempotency_key: "key", confirm: true
    ).send(:reject_forbidden_key!)
    Hive::Commands::Receipt.new("retire").send(:reject_forbidden_key!)
    assert_raises(Hive::UsageError) { Hive::Commands::Receipt.new("retire").send(:required_identifier!) }
    assert_equal "r", Hive::Commands::Receipt.new("retire", "r").send(:required_identifier!)

    assert_nil Hive::Commands::Receipt.new("prune").send(:project_root)
    with_replaced_singleton_method(Hive::Config, :find_project, ->(_name) { nil }) do
      assert_raises(Hive::UsageError) do
        Hive::Commands::Receipt.new("prune", project: "missing").send(:project_root)
      end
    end
    with_replaced_singleton_method(Hive::Config, :find_project, ->(_name) { { "path" => "/project" } }) do
      assert_equal "/project", Hive::Commands::Receipt.new("prune", project: "demo").send(:project_root)
    end

    owner = Object.new
    owner.define_singleton_method(:authorize_namespace_selection!) { |value| value }
    assert_equal "namespace", Hive::Commands::Receipt.new(
      "retire", "r", namespace_id: "namespace", maintenance: owner
    ).send(:selected_namespace_id)
    assert_raises(Hive::UsageError) do
      Hive::Commands::Receipt.new(
        "retire", "r", project: "demo", namespace_id: "namespace"
      ).send(:selected_namespace_id)
    end

    with_tmp_dir do |dir|
      object = File.join(dir, "object.json")
      array = File.join(dir, "array.json")
      invalid = File.join(dir, "invalid.json")
      large = File.join(dir, "large.json")
      File.write(object, "{\"ok\":true}")
      File.write(array, "[]")
      File.write(invalid, "{")
      File.write(large, "x" * (256 * 1024 + 1))
      assert_equal({ "ok" => true }, Hive::Commands::Receipt.new(
        "retire", evidence: object
      ).send(:read_evidence!))
      [ array, invalid, large, File.join(dir, "missing") ].each do |path|
        assert_raises(Hive::UsageError) do
          Hive::Commands::Receipt.new("retire", evidence: path).send(:read_evidence!)
        end
      end
    end

    store = Struct.new(:database).new(Object.new)
    command = Hive::Commands::Receipt.new(
      "enroll", project: "demo", new_identity: true,
      previous_identity: "12345678-1234-1234-1234-123456789abc",
      command_receipt_store: store,
      authority: Hive::CommandMaintenanceAuthority.new(
        principal: "owner", principal_source: "test", installation_owner: true
      )
    )
    command.instance_variable_set(:@project_root, "/project")
    test_case = self
    with_replaced_singleton_method(Hive::ProjectIdentity, :enroll_new_identity, lambda { |**kwargs|
      test_case.assert_equal "/project", kwargs.fetch(:project_root)
      { "enrolled" => true }
    }) do
      assert_equal({ "enrolled" => true }, command.send(:execute))
    end
    assert_raises(Hive::UsageError) do
      missing = Hive::Commands::Receipt.new("enroll", project: "demo")
      missing.instance_variable_set(:@project_root, "/project")
      missing.send(:execute)
    end
    assert_raises(Hive::UsageError) do
      missing = Hive::Commands::Receipt.new("enroll", project: "demo", new_identity: true)
      missing.instance_variable_set(:@project_root, "/project")
      missing.send(:execute)
    end
  end

  def test_receipt_public_boundary_rejects_options_that_the_subcommand_would_ignore
    [
      Hive::Commands::Receipt.new("retire", "receipt", cursor: "next", settle_without_result: true),
      Hive::Commands::Receipt.new("release-pin", "pin", limit: 10),
      Hive::Commands::Receipt.new("abandon-batch", "batch", cursor: "next"),
      Hive::Commands::Receipt.new("prune", confirm: true, cursor: "next")
    ].each do |command|
      assert_raises(Hive::UsageError) { command.call }
    end
  end

  def test_public_prune_preview_defers_authority_resolution_to_read_only_guard
    database = Object.new
    store = Struct.new(:database).new(database)
    command = Hive::Commands::Receipt.new(
      "prune", command_receipt_store: store,
      authority: -> { flunk "preview must not resolve write-capable authority before read_only" }
    )
    received = nil
    pruner = Object.new
    with_replaced_singleton_method(Hive::CommandReceiptPruner, :new, lambda { |**kwargs|
      received = kwargs
      pruner
    }) do
      assert_same pruner, command.send(:pruner)
    end
    assert_equal({ database: database }, received)
  end

  def test_receipt_store_is_constructed_after_injected_authority_is_resolved
    database = Object.new
    authority = Hive::CommandMaintenanceAuthority.new(
      principal: "owner", principal_source: "test", installation_owner: true
    )
    received = nil
    built = Struct.new(:database).new(database)
    command = Hive::Commands::Receipt.new("retire", authority: authority)
    command.instance_variable_set(:@receipt_database, database)
    with_replaced_singleton_method(Hive::CommandReceiptStore, :new, lambda { |**kwargs|
      received = kwargs
      built
    }) do
      assert_same built, command.send(:receipt_store)
    end
    assert_same authority, received.fetch(:maintenance_authority)
  end

  def test_receipt_public_boundary_authorizes_namespace_selection_before_lookup
    maintenance = Object.new
    maintenance.define_singleton_method(:authorize_namespace_selection!) do |_namespace_id|
      raise Hive::ConfigError, "installation-owner authority required"
    end
    maintenance.define_singleton_method(:release_pin) do |*|
      raise "foreign identifier was disclosed before namespace authorization"
    end
    command = Hive::Commands::Receipt.new(
      "release-pin", "foreign-pin", namespace_id: "foreign-namespace",
      expected_generation: 1, reason: "test", confirm: true, maintenance: maintenance
    )

    error = assert_raises(Hive::ConfigError) { command.call }
    assert_includes error.message, "installation-owner authority required"
  end

  def test_receipt_envelope_classifies_typed_failures
    command = Hive::Commands::Receipt.new("retire")
    outcome = Hive::CommandUnresolved.new(reason: "uncertain")
    capacity = Hive::CommandCapacityError.new("full", reason: :full, scope: :namespace)
    assert_equal "uncertain", command.envelope_error_kind(outcome)
    assert_equal "full", command.envelope_error_kind(capacity)
    assert_equal "usage", command.envelope_error_kind(Hive::UsageError.new("bad"))
    assert_equal "config", command.envelope_error_kind(Hive::ConfigError.new("bad"))
    assert_equal "internal", command.envelope_error_kind(StandardError.new("bad"))
  end

  def test_authority_validates_github_identity_and_state_home_errors
    assert_raises(Hive::ConfigError) do
      Hive::CommandMaintenanceAuthority.github(config: {}, login: "owner", id: "1")
    end
    auth = Object.new
    auth.define_singleton_method(:maintenance_owner?) { |login, id| login == "owner" && id == 1 }
    with_replaced_singleton_method(Hive::Web::GithubAuth, :new, ->(**) { auth }) do
      authority = Hive::CommandMaintenanceAuthority.github(
        config: {}, login: "owner", id: 1, peer_address: "127.0.0.1"
      )
      assert authority.installation_owner?
      assert_equal "github:1", authority.principal
    end
    with_replaced_singleton_method(File, :lstat, ->(*) { raise Errno::ENOENT, "gone" }) do
      error = assert_raises(Hive::ConfigError) do
        Hive::CommandMaintenanceAuthority.validate_state_home_custody!
      end
      assert_includes error.message, "cannot be verified"
    end
  end

  def test_mutation_catalog_canonicalizes_nested_semantic_values
    assert Hive::CommandMutations.supported?(command: "new")
    refute Hive::CommandMutations.supported?(command: "unknown")
    time = Time.utc(2026, 9, 27, 6, 0, 0, 123_456)
    first = Hive::CommandMutations.fingerprint(
      command: "new", namespace_id: "n", target: "t", principal: "p",
      options: { values: [ :symbol, time ] }
    )
    second = Hive::CommandMutations.fingerprint(
      command: "new", namespace_id: "n", target: "t", principal: "p",
      options: { "values" => [ "symbol", time.iso8601(6) ] }
    )
    assert_equal first, second
  end

  def test_command_operation_covers_text_json_templates_and_replay_failures
    operation = Hive::CommandOperation.allocate
    operation.instance_variable_set(:@structured, false)
    operation.instance_variable_set(:@json, true)
    assert_raises(Hive::InternalError) { operation.send(:response_payload, nil, "{") }

    operation.instance_variable_set(:@json, false)
    assert_equal({ "format" => "text", "text" => "hello" }, operation.send(:stored_response, "hello"))
    out, = capture_io { assert_nil operation.send(:emit_or_return, "hello") }
    assert_equal "hello", out

    operation.instance_variable_set(:@command, "act")
    template = operation.send(:template_payload, { "observation_token" => "secret" })
    assert_equal "observation", template.dig("observation_token", "$command_request_field")
    operation.instance_variable_set(:@request, { observation: "secret" })
    assert_equal "secret", operation.send(:expand_template, template).fetch("observation_token")
    operation.instance_variable_set(:@request, { observation: "wrong" })
    assert_raises(Hive::CommandConflict) { operation.send(:expand_template, template) }

    operation.instance_variable_set(:@structured, true)
    text_claim = FakeClaim.new("succeeded", { "format" => "text", "text" => "stored" }, {})
    assert_equal "stored", operation.send(:replay, text_claim)
    bad_claim = FakeClaim.new("succeeded", { "format" => "yaml" }, {})
    assert_raises(Hive::RuntimeControlPlane::IntegrityError) { operation.send(:replay, bad_claim) }

    operation.instance_variable_set(:@structured, false)
    out, = capture_io { assert_nil operation.send(:replay, text_claim) }
    assert_equal "stored", out
    operation.instance_variable_set(:@json, true)
    operation.instance_variable_set(:@request, {})
    corrupt = FakeClaim.new(
      "succeeded",
      { "format" => "json", "payload" => { "ok" => true }, "expanded_sha256" => "0" * 64 },
      {}
    )
    assert_raises(Hive::CommandConflict) { operation.send(:replay, corrupt) }
  end

  def test_command_operation_rejects_mismatched_process_identity
    database = Struct.new(:installation_identity).new({ installation_id: "installation" })
    with_replaced_singleton_method(Process, :uid, -> { 1000 }) do
      with_replaced_singleton_method(Process, :euid, -> { 1001 }) do
        assert_raises(Hive::ConfigError) { Hive::CommandOperation.local_principal(database) }
      end
    end
  end

  def test_schema_writer_guard_checks_pid_files_projects_and_web_service
    with_tmp_dir do |dir|
      project = File.join(dir, "project")
      explicit = File.join(dir, "explicit-state")
      FileUtils.mkdir_p(File.join(project, ".hive-state"))
      FileUtils.mkdir_p(explicit)
      assert Hive::RuntimeControlPlane::CommandSchemaWriterGuard.verify!(
        state_home: dir,
        registered_projects: [ { "path" => project }, { "hive_state_path" => explicit }, "bad" ],
        web_running: -> { false }
      )
      assert_raises(Hive::ConfigError) do
        Hive::RuntimeControlPlane::CommandSchemaWriterGuard.verify!(
          state_home: dir, registered_projects: [], web_running: -> { true }
        )
      end

      path = File.join(dir, ".daemon.pid")
      File.write(path, "not yaml: [")
      assert_raises(Hive::ConfigError) do
        Hive::RuntimeControlPlane::CommandSchemaWriterGuard.verify_pid_file!(
          path, alive: ->(*) { false }, ownership: ->(*) { :dead }
        )
      end
      File.write(path, { "pid" => 123, "process_start_time" => "start" }.to_yaml)
      assert Hive::RuntimeControlPlane::CommandSchemaWriterGuard.verify_pid_file!(
        path, alive: ->(*) { false }, ownership: ->(*) { :dead }
      )
      assert Hive::RuntimeControlPlane::CommandSchemaWriterGuard.verify_pid_file!(
        path, alive: ->(*) { true }, ownership: ->(*) { :reused }
      )
      %i[verified legacy unknown].each do |classification|
        error = assert_raises(Hive::ConfigError) do
          Hive::RuntimeControlPlane::CommandSchemaWriterGuard.verify_pid_file!(
            path, alive: ->(*) { true }, ownership: ->(*) { classification }
          )
        end
        assert_includes error.message, classification == :unknown ? "liveness-unverifiable" : "live"
      end
    end
  end

  def test_receipt_maintenance_retires_authoritatively_accounted_effects
    with_receipts do |project, database, store, authority|
      maintenance = Hive::CommandReceiptMaintenance.new(
        database: database, authority: authority, alive: ->(_) { false }
      )

      succeeded = executing_claim(store, project, "succeeded")
      effect = store.prepare_effect(succeeded, ordinal: 0, kind: "test", identity: {})
      payload = { "schema" => "hive-approve", "schema_version" => 2, "ok" => true }
      replay = {
        "format" => "json", "payload" => payload,
        "expanded_sha256" => Digest::SHA256.hexdigest(
          Hive::RuntimeControlPlane::Codec.dump_json(payload)
        )
      }
      observation = {
        "source" => "provider", "correlation_id" => "remote-1",
        "evidence" => { "remote_oid" => "a" * 40 }
      }
      store.update_effect(
        succeeded, effect_id: effect.fetch(:effect_id), from: "prepared", to: "applied",
        evidence: {
          "authoritative_result" => replay,
          "authoritative_result_sha256" => Digest::SHA256.hexdigest(
            Hive::RuntimeControlPlane::Codec.dump_json(replay)
          ),
          "authoritative_status" => 0,
          "observations" => [ observation ]
        }
      )
      store.mark_unresolved(succeeded, reason: "lost")
      row = store.receipt(succeeded.receipt_id)
      succeeded_row = row
      success_evidence = {
        "outcome" => "succeeded", "result" => replay,
        "effects" => [ {
          "effect_id" => effect.fetch(:effect_id), "ordinal" => 0,
          "identity_sha256" => Digest::SHA256.hexdigest(effect.fetch(:identity_json)),
          "observation" => observation
        } ]
      }
      retired = maintenance.retire_with_evidence(
        row.fetch(:receipt_id), expected_generation: row.fetch(:generation),
        evidence: success_evidence, reason: "verified", confirm: true
      )
      assert_equal "succeeded", retired.fetch("state")
      assert_equal "succeeded", store.receipt(row.fetch(:receipt_id)).fetch(:state)

      failed = executing_claim(store, project, "failed")
      effect = store.prepare_effect(failed, ordinal: 0, kind: "test", identity: {})
      store.update_effect(
        failed, effect_id: effect.fetch(:effect_id), from: "prepared", to: "not_applied"
      )
      store.mark_unresolved(failed, reason: "lost")
      row = store.receipt(failed.receipt_id)
      result = maintenance.retire_with_evidence(
        row.fetch(:receipt_id), expected_generation: row.fetch(:generation),
        evidence: {
          "outcome" => "not_applied", "whole_effect_non_application" => true,
          "status" => 1,
          "result" => { "format" => "text", "text" => "not applied\n" }
        }, reason: "verified", confirm: true
      )
      assert_equal "failed", result.fetch("state")
      assert_equal 1, store.receipt(row.fetch(:receipt_id)).fetch(:retry_eligible)

      assert_raises(Hive::CommandUnresolved) do
        maintenance.send(:validate_retirement_evidence!, row, { "outcome" => "unknown" })
      end
      assert_raises(Hive::CommandUnresolved) do
        maintenance.send(
          :validate_retirement_evidence!, succeeded_row,
          { "outcome" => "succeeded", "result" => replay, "effects" => [] }
        )
      end

      forged_payload = payload.merge("forged" => true)
      forged_replay = {
        "format" => "json", "payload" => forged_payload,
        "expanded_sha256" => Digest::SHA256.hexdigest(
          Hive::RuntimeControlPlane::Codec.dump_json(forged_payload)
        )
      }
      error = assert_raises(Hive::CommandUnresolved) do
        maintenance.send(
          :validate_retirement_evidence!, succeeded_row,
          success_evidence.merge("result" => forged_replay)
        )
      end
      assert_includes error.message, "authoritative original result"

      forged_observation = observation.merge("correlation_id" => "attacker-selected")
      error = assert_raises(Hive::CommandUnresolved) do
        maintenance.send(
          :validate_retirement_evidence!, succeeded_row,
          success_evidence.merge(
            "effects" => [ success_evidence.fetch("effects").first.merge(
              "observation" => forged_observation
            ) ]
          )
        )
      end
      assert_includes error.message, "stored authoritative observation"
    end
  end

  def test_receipt_maintenance_recovers_dead_owner_and_abandons_dead_batch
    with_receipts do |project, database, store, authority|
      maintenance = Hive::CommandReceiptMaintenance.new(
        database: database, authority: authority,
        alive: ->(*) { true }, ownership: ->(*) { :reused }
      )
      claim = store.reserve(
        project_root: project, key: "orphan", command: "approve", target: "task",
        request: {}, principal: "owner"
      )
      claim = store.mark_executing(
        claim, owner_host: Socket.gethostname, owner_pid: 4321,
        owner_process_start: "start"
      )
      preview = maintenance.orphaned_owner(
        claim.receipt_id, expected_generation: claim.generation,
        reason: "dead", confirm: false
      )
      assert_equal "reused", preview.dig("evidence", "ownership")
      result = maintenance.orphaned_owner(
        claim.receipt_id, expected_generation: claim.generation,
        reason: "dead", confirm: true
      )
      assert_equal "unresolved", result.fetch("state")

      administrative = store.reserve(
        project_root: project, key: "prune-batch", command: "receipt", mode: "prune",
        target: "demo", request: { "confirm" => true }, principal: "owner",
        maintenance: true, execute: true, owner_process_start: "start"
      )
      effect = store.prepare_effect(
        administrative, ordinal: 0, kind: "receipt:prune", identity: {}
      )
      now = Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc)
      database.transaction do |connection|
        connection[:command_maintenance_batches].insert(
          batch_id: "batch", namespace_id: claim.namespace_id, principal: "owner",
          administrative_receipt_id: administrative.receipt_id,
          principal_scope: "own", kind: "prune", state: "executing", generation: 1,
          owner_host: Socket.gethostname, owner_pid: 4322, owner_process_start: "start",
          fixed_cutoff: now, candidates_json: "[]", outcomes_json: "[]",
          created_at: now, updated_at: now
        )
      end
      preview = maintenance.abandon_batch(
        "batch", expected_generation: 1, reason: "dead", confirm: false
      )
      assert preview.fetch("preview")
      result = maintenance.abandon_batch(
        "batch", expected_generation: 1, reason: "dead", confirm: true
      )
      assert_equal "abandoned", result.fetch("state")
      settled = store.receipt(administrative.receipt_id)
      assert_equal "settled", settled.fetch(:state)
      assert_equal Hive::ExitCodes::COMMAND_UNRESOLVED, settled.fetch(:result_status)
      assert_equal "unknown", database.read {
        |connection| connection[:command_effects][effect_id: effect.fetch(:effect_id)].fetch(:state)
      }
      assert_equal "batch", JSON.parse(settled.fetch(:result_json)).dig("payload", "batch_id")
    end
  end

  def test_receipt_maintenance_validation_and_dead_owner_refusals
    with_receipts do |project, database, store, authority|
      maintenance = Hive::CommandReceiptMaintenance.new(
        database: database, authority: authority, alive: ->(*) { true }, ownership: ->(*) { :verified }
      )
      terminal = terminal_claim(store, project, "terminal")
      row = store.receipt(terminal.receipt_id)
      assert_raises(Hive::UsageError) do
        maintenance.settle_without_result(
          row.fetch(:receipt_id), expected_generation: row.fetch(:generation), reason: "x"
        )
      end
      assert_raises(Hive::UsageError) do
        maintenance.send(:validate_generation!, row, "invalid")
      end
      assert_raises(Hive::CommandConflict) do
        maintenance.send(:validate_generation!, row, row.fetch(:generation) + 1)
      end
      assert_raises(Hive::UsageError) do
        maintenance.send(:receipt!, row.fetch(:receipt_id), namespace_id: "other")
      end
      assert_raises(Hive::UsageError) do
        maintenance.abandon_batch("missing", expected_generation: 1, reason: "x")
      end
      assert_raises(Hive::CommandUnresolved) do
        maintenance.send(:dead_owner_proof!, owner_host: "remote", owner_pid: 1,
                         owner_process_start: "start")
      end
      assert_raises(Hive::CommandUnresolved) do
        maintenance.send(:dead_owner_proof!, owner_host: Socket.gethostname, owner_pid: 1,
                         owner_process_start: "start")
      end
      invalid = maintenance.send(
        :horizon_evidence, retry_horizon_expires_at: "not-a-time"
      )
      assert_equal "invalid", invalid.fetch("horizon_evidence")
    end
  end

  def test_pruner_previews_installation_namespaces_and_validates_boundaries
    with_receipts do |project, database, store, authority|
      terminal_claim(store, project, "old")
      pruner = Hive::CommandReceiptPruner.new(database: database, authority: authority)
      payload = pruner.preview(limit: 1, cursor: "")
      assert_equal 1, payload.fetch("namespaces").length
      assert payload.key?("next_cursor")
      assert_raises(Hive::UsageError) { pruner.preview(limit: "bad") }
      assert_raises(Hive::UsageError) do
        pruner.preview(project_root: project, namespace_id: "both")
      end
      refute pruner.send(:valid_terminal_time?, "invalid", Time.now.utc)

      own = Hive::CommandMaintenanceAuthority.new(
        principal: "owner", principal_source: "test", installation_owner: false
      )
      scoped = Hive::CommandReceiptPruner.new(database: database, authority: own)
      assert_raises(Hive::ConfigError) { scoped.preview }
      selected = scoped.preview(project_root: project)
      assert_equal "ask_installation_owner", selected.fetch("installation_pressure")
    end
  end

  def test_receipt_store_covers_successors_pins_and_replay_integrity
    with_receipts do |project, _database, store, _authority|
      claim = store.reserve(
        project_root: project, key: "retryable", command: "approve", target: "task",
        request: { nested: [ :symbol, 1 ] }, principal: "owner"
      )
      stale = claim
      claim = store.mark_executing(claim)
      assert_raises(Hive::CommandConflict) do
        store.prepare_effect(stale, ordinal: 0, kind: "stale", identity: {})
      end
      failed = store.fail_non_application(
        claim, result: { "ok" => false }, status: 1, reason: "not_applied",
        whole_effect_non_application: true
      )
      allocation = store.allocate_successor(
        namespace_id: failed.namespace_id, principal: failed.principal,
        intent_id: "intent", intent_version: 1,
        predecessor_receipt_id: failed.receipt_id, delivery_cycle_id: "cycle",
        request_fingerprint: "fingerprint", project_root: project
      )
      assert_equal 1, allocation.fetch("successor_ordinal")
      assert_equal allocation, store.allocate_successor(
        namespace_id: failed.namespace_id, principal: failed.principal,
        intent_id: "intent", intent_version: 1,
        predecessor_receipt_id: failed.receipt_id, delivery_cycle_id: "cycle",
        request_fingerprint: "fingerprint"
      )
      assert_raises(Hive::CommandConflict) do
        store.allocate_successor(
          namespace_id: failed.namespace_id, principal: failed.principal,
          intent_id: "intent", intent_version: 1,
          predecessor_receipt_id: failed.receipt_id, delivery_cycle_id: "cycle",
          request_fingerprint: "changed"
        )
      end
      assert_raises(Hive::CommandUnresolved) do
        store.allocate_successor(
          namespace_id: failed.namespace_id, principal: failed.principal,
          intent_id: "new", intent_version: 1,
          predecessor_receipt_id: "missing", delivery_cycle_id: "cycle",
          request_fingerprint: "fingerprint", project_root: project
        )
      end
      assert_raises(Hive::UsageError) do
        store.allocate_successor(
          namespace_id: failed.namespace_id, principal: failed.principal,
          intent_id: "new", intent_version: "bad",
          predecessor_receipt_id: failed.receipt_id, delivery_cycle_id: "cycle-2",
          request_fingerprint: "fingerprint"
        )
      end

      [ Time.now.utc.iso8601, "2026-09-27", "not-a-time" ].each do |horizon|
        assert_raises(Hive::UsageError) do
          store.acquire_pin(
            receipt_id: failed.receipt_id, principal: failed.principal,
            intent_id: "pin-#{horizon}", intent_generation: 1,
            retry_horizon_expires_at: horizon
          )
        end
      end
      assert_raises(Hive::UsageError) do
        store.acquire_pin(
          receipt_id: failed.receipt_id, principal: failed.principal,
          intent_id: "pin", intent_generation: "bad",
          retry_horizon_expires_at: (Time.now.utc + 60).iso8601
        )
      end

      row = store.receipt(failed.receipt_id).merge(state: "mystery")
      assert_raises(Hive::RuntimeControlPlane::IntegrityError) do
        store.send(
          :classify_existing!, row, principal: failed.principal,
          request_fingerprint: failed.request_fingerprint, project_root: project
        )
      end
      safe = store.send(:safe_request, { values: [ :symbol, 1 ], observation: "secret" })
      assert_equal [ :symbol, 1 ], safe.fetch("values")
      assert_equal 64, safe.dig("observation", "sha256").length

      large = store.reserve(
        project_root: project, key: "large", command: "approve", target: "large",
        request: {}, principal: "owner"
      )
      assert_raises(Hive::CommandUnresolved) do
        store.succeed(large, result: { "value" => "x" * (Hive::CommandReceiptStore::MAX_RESULT_BYTES + 1) })
      end
      assert_equal "unresolved", store.receipt(large.receipt_id).fetch(:state)
    end
  end

  def test_capacity_configuration_and_installation_scoped_limits
    assert_raises(Hive::ConfigError) do
      with_replaced_singleton_method(Hive::Config, :read_project_config, lambda { |_root|
        [ "config.yml", { "command_receipts" => { "installation_nonterminal_limit" => 1 } } ]
      }) { Hive::CommandReceiptCapacity.load("/project") }
    end
    assert_raises(Hive::ConfigError) do
      Hive::CommandReceiptCapacity.send(:positive_integer, 0, "limit")
    end

    with_replaced_singleton_method(Hive::Config, :global_config_path, -> { "/global.yml" }) do
      with_replaced_singleton_method(File, :exist?, ->(*) { true }) do
        [ [], { "command_receipts" => [] }, { "command_receipts" => { "unknown" => 1 } } ].each do |data|
          with_replaced_singleton_method(Hive::Config, :load_global_config, ->(*) { data }) do
            assert_raises(Hive::ConfigError) { Hive::CommandReceiptCapacity.global_receipts }
          end
        end
        valid = { "command_receipts" => { "installation_nonterminal_limit" => 10 } }
        with_replaced_singleton_method(Hive::Config, :load_global_config, ->(*) { valid }) do
          assert_equal 10,
                       Hive::CommandReceiptCapacity.global_receipts.fetch("installation_nonterminal_limit")
        end
      end
    end

    with_receipts do |project, database, store, _authority|
      claim = store.reserve(
        project_root: project, key: "capacity", command: "approve", target: "task",
        request: {}, principal: "owner"
      )
      namespace_id = claim.namespace_id
      base = Hive::CommandReceiptCapacity.load(project)
      database.transaction do |connection|
        connection[:command_capacity].where(namespace_id: namespace_id).update(
          nonterminal_count: 1, executing_count: 1, logical_bytes: 1
        )
      end
      cases = [
        [ base.with(nonterminal_limit: 1), :nonterminal, "command_nonterminal_limit", "namespace", "nonterminal_limit" ],
        [ base.with(nonterminal_limit: 10, installation_nonterminal_limit: 1), :nonterminal,
          "command_nonterminal_limit", "installation", "installation_nonterminal_limit" ],
        [ base.with(nonterminal_limit: 10, installation_nonterminal_limit: 10,
                    byte_admission_limit: Hive::CommandReceiptCapacity::NEXT_OPERATION_ALLOWANCE),
          :nonterminal, "command_capacity_exhausted", "namespace", "byte_admission_limit" ],
        [ base.with(nonterminal_limit: 10, installation_nonterminal_limit: 10,
                    byte_admission_limit: 10**9, installation_byte_admission_limit: 1),
          :nonterminal, "command_capacity_exhausted", "installation", "installation_byte_admission_limit" ],
        [ base.with(concurrency_limit: 1), :execution,
          "command_concurrency_limit", "namespace", "concurrency_limit" ],
        [ base.with(concurrency_limit: 10, installation_concurrency_limit: 1), :execution,
          "command_concurrency_limit", "installation", "installation_concurrency_limit" ]
      ]
      database.read do |connection|
        cases.each do |policy, operation, reason, scope, remedy|
          capacity = Hive::CommandReceiptCapacity.new(database: database, policy: policy)
          error = assert_raises(Hive::CommandCapacityError) do
            if operation == :execution
              capacity.admit_execution!(connection, namespace_id: namespace_id)
            else
              capacity.admit_nonterminal!(
              connection, namespace_id: namespace_id, request_bytes: 1,
              occupied_installation_bytes: 1
              )
            end
          end
          assert_equal reason, error.reason
          assert_equal scope, error.scope
          assert_includes error.message, remedy
        end
      end
    end
  end

  def test_settlement_budget_distinguishes_unspecified_zero_and_allocated_time
    measured = 4.802 / 60_000
    absent = Hive::CommandReceiptCapacity.settlement_budget(
      staffing: {}, settlement_minutes: measured
    )
    zero = Hive::CommandReceiptCapacity.settlement_budget(
      staffing: { "minutes_per_namespace_per_day" => 0 },
      settlement_minutes: measured
    )
    allocated = Hive::CommandReceiptCapacity.settlement_budget(
      staffing: { "operator_count" => 4, "minutes_per_namespace_per_day" => 30 },
      settlement_minutes: measured
    )

    assert_nil absent.fetch(:daily_ceiling)
    assert_equal 0, zero.fetch(:daily_ceiling)
    assert_equal 374_843, allocated.fetch(:daily_ceiling)
    assert_raises(Hive::ConfigError) do
      Hive::CommandReceiptCapacity.settlement_budget(
        staffing: { "minutes_per_namespace_per_day" => 30 }, settlement_minutes: 0
      )
    end
    assert_raises(Hive::ConfigError) do
      Hive::CommandReceiptCapacity.settlement_budget(
        staffing: { "minutes_per_namespace_per_day" => -1 }, settlement_minutes: measured
      )
    end
    assert_raises(Hive::ConfigError) do
      Hive::CommandReceiptCapacity.settlement_budget(
        staffing: { "minutes_per_namespace_per_day" => "many" }, settlement_minutes: measured
      )
    end
  end

  def test_installation_staffing_overrides_project_staffing
    with_receipts do |project, _database, _store, _authority|
      staffing = { "operator_count" => 9, "minutes_per_namespace_per_day" => 45 }
      with_replaced_singleton_method(
        Hive::CommandReceiptCapacity, :global_receipts, -> { { "staffing" => staffing } }
      ) do
        assert_equal staffing, Hive::CommandReceiptCapacity.load(project).staffing
      end
    end
  end

  def test_command_adapters_build_operations_and_classify_receipt_failures
    database = Struct.new(:installation_identity).new({ installation_id: "installation" })
    store = Struct.new(:database).new(database)
    outcome = Hive::CommandUnresolved.new(reason: "uncertain")
    capacity = Hive::CommandCapacityError.new("full", reason: :full, scope: :namespace)

    act = Hive::Commands::Act.new(
      "run", "task", observation: "token", project: "demo", json: true,
      idempotency_key: "key", command_receipt_store: store
    )
    act_operation = act.send(:command_operation)
    assert_equal [ "key", "act", "task" ], %i[@key @command @target].map {
      |name| act_operation.instance_variable_get(name)
    }
    assert_equal(
      { "action_id" => "run", "observation" => "token", "project" => "demo" },
      act_operation.instance_variable_get(:@request)
    )
    assert_equal "uncertain", act.envelope_error_kind(outcome)
    assert_equal "full", act.envelope_error_kind(capacity)

    approve = Hive::Commands::Approve.new(
      "task", idempotency_key: "key", command_receipt_store: store
    )
    approve_operation = approve.send(:command_operation)
    assert_equal [ "key", "approve", "task" ], %i[@key @command @target].map {
      |name| approve_operation.instance_variable_get(name)
    }
    assert_equal(
      { "to" => nil, "from" => nil, "project" => nil, "force" => false },
      approve_operation.instance_variable_get(:@request)
    )
    assert_equal "uncertain", Hive::Commands::Approve.error_kind_for(outcome)
    assert_equal "full", Hive::Commands::Approve.error_kind_for(capacity)

    stage = Hive::Commands::StageAction.new(
      "plan", "task", idempotency_key: "key", command_receipt_store: store
    )
    stage_operation = stage.send(:command_operation)
    assert_equal [ "key", "stage_action", "plan", "task" ],
                 %i[@key @command @mode @target].map {
                   |name| stage_operation.instance_variable_get(name)
                 }
    assert_equal(
      { "verb" => "plan", "from" => nil, "project" => nil },
      stage_operation.instance_variable_get(:@request)
    )

    answer = Hive::Commands::Answer.new(
      "task", binding: "binding", idempotency_key: "key", command_receipt_store: store
    )
    answer_operation = nil
    with_replaced_singleton_method(answer, :decode_binding, ->(*) { { "project" => "demo" } }) do
      answer_operation = answer.send(:command_operation, "yes")
      assert_equal [ "key", "answer", "write", "task" ],
                   %i[@key @command @mode @target].map {
                     |name| answer_operation.instance_variable_get(name)
                   }
      answer_request = answer_operation.instance_variable_get(:@request)
      assert_equal "demo", answer_request.fetch("binding").fetch("project")
      assert_equal Digest::SHA256.hexdigest("yes"), answer_request.fetch("answer_sha256")
    end
    assert_equal "uncertain", answer.send(:error_kind, outcome)
    assert_equal "full", answer.send(:error_kind, capacity)

    fresh = Hive::Commands::New.new(
      "demo", "idea", idempotency_key: "key", json: true,
      command_receipt_store: store
    )
    new_operation = fresh.send(:command_operation)
    assert_equal [ "key", "new", "demo" ], %i[@key @command @target].map {
      |name| new_operation.instance_variable_get(name)
    }
    assert_equal Digest::SHA256.hexdigest("idea"),
                 new_operation.instance_variable_get(:@request).fetch("text_sha256")
    [ act_operation, approve_operation, stage_operation, answer_operation, new_operation ].each do |operation|
      assert_equal "installation:installation:uid:#{Process.uid}",
                   operation.instance_variable_get(:@principal)
    end
    assert_equal "uncertain", fresh.envelope_error_kind(outcome)
    assert_equal "full", fresh.envelope_error_kind(capacity)
    with_tmp_dir do |dir|
      path = File.join(dir, "attachment.txt")
      File.write(path, "attachment")
      assert_equal 64, fresh.send(:attachment_identity, path).fetch("sha256").length
      assert_nil fresh.send(:attachment_identity, File.join(dir, "missing")).fetch("sha256")
    end
  end

  def test_config_and_error_envelopes_validate_receipt_specific_fields
    base = {
      "keyed_intake_enabled" => true, "nonterminal_limit" => 1,
      "concurrency_limit" => 1, "byte_admission_limit" => 1,
      "staffing" => {
        "operator_count" => 1, "response_business_days" => 1,
        "minutes_per_namespace_per_day" => nil
      }
    }
    [
      base.merge("keyed_intake_enabled" => nil),
      base.merge("staffing" => []),
      base.merge("staffing" => base.fetch("staffing").merge(
        "minutes_per_namespace_per_day" => -1
      ))
    ].each do |receipts|
      assert_raises(Hive::ConfigError) do
        Hive::Config.send(:validate_command_receipts!, { "command_receipts" => receipts }, "config.yml")
      end
    end

    config = Hive::Config.send(:deep_dup, Hive::Config::DEFAULTS)
    config["web"]["github"]["owner_id"] = 0
    assert_raises(Hive::ConfigError) do
      Hive::Config.send(:validate_web_config!, config, "config.yml")
    end

    unresolved = Hive::CommandUnresolved.new(
      reason: "uncertain", state: "unresolved",
      command_receipt: { "id" => "receipt" }
    )
    payload = Hive::Schemas::ErrorEnvelope.build(
      schema: "hive-command-receipt", error: unresolved, error_kind: "uncertain"
    )
    assert_equal "receipt", payload.dig("command_receipt", "id")
    capacity = Hive::CommandCapacityError.new("full", reason: :full, scope: :namespace)
    payload = Hive::Schemas::ErrorEnvelope.build(
      schema: "hive-command-receipt", error: capacity, error_kind: "full"
    )
    assert_equal "namespace", payload.fetch("scope")
  end

  def test_admission_transition_binds_and_rejects_command_contexts
    repository = Struct.new(:database).new(nil)
    transition = Hive::RuntimeControlPlane::AdmissionTransition.new(repository: repository)
    rows = {}
    table = Object.new
    table.define_singleton_method(:[]) { |query| rows[query.fetch(:request_id)] }
    table.define_singleton_method(:insert) { |payload| rows[payload.fetch(:request_id)] = payload }
    receipt = {
      receipt_id: "receipt", namespace_id: "namespace", state: "executing", generation: 1,
      principal: "owner", request_fingerprint: "fingerprint"
    }
    receipts = Object.new
    receipts.define_singleton_method(:[]) { |query| query[:receipt_id] == "receipt" ? receipt : nil }
    capacity_update = Object.new
    capacity_update.define_singleton_method(:update) { |**| 1 }
    capacity = Object.new
    capacity.define_singleton_method(:where) { |**| capacity_update }
    db = Object.new
    db.define_singleton_method(:table_exists?) { |name| name == :command_dispatch_contexts }
    db.define_singleton_method(:[]) do |name|
      { command_dispatch_contexts: table, command_receipts: receipts,
        command_capacity: capacity }.fetch(name)
    end
    request_id = "command-dispatch:v1:#{'a' * 64}"
    assert_raises(Hive::Attempts::RepositoryError) do
      transition.send(:bind_command_context!, db, request_id, nil)
    end
    context = Hive::CommandOperation::Context.new(
      receipt_id: "receipt", effect_id: "effect", principal: "owner",
      principal_source: "test", ordinal: 0, receipt_generation: 1,
      request_fingerprint: "fingerprint",
      transport_request_id: request_id,
      retry_horizon_expires_at: "2030-01-01T00:00:00.000000Z"
    )
    transition.send(:bind_command_context!, db, request_id, context)
    transition.send(:bind_command_context!, db, request_id, context)
    assert_equal request_id, rows.fetch(request_id).fetch(:source_identity)
    changed = context.with(effect_id: "changed")
    assert_raises(Hive::Attempts::RepositoryError) do
      transition.send(:bind_command_context!, db, request_id, changed)
    end
    assert_raises(Hive::Attempts::RepositoryError) do
      transition.send(:bind_command_context!, db, "plain", context)
    end
  end

  def test_project_identity_rejects_invalid_enrollment_and_marker_states
    database = Struct.new(:installation_identity).new({ installation_id: "installation" })
    assert_raises(Hive::UsageError) do
      Hive::ProjectIdentity.enroll_new_identity(
        project_root: "/project", database: database,
        previous_identity: "bad", expected_generation: 0, confirm: false
      )
    end
    assert_raises(Hive::UsageError) do
      Hive::ProjectIdentity.enroll_new_identity(
        project_root: "/project", database: database,
        previous_identity: "12345678-1234-1234-1234-123456789abc",
        expected_generation: "bad", confirm: false
      )
    end
    assert_raises(Hive::ConfigError) { Hive::ProjectIdentity.git_common_dir("/not-a-repository") }
    with_replaced_singleton_method(Open3, :capture3, ->(*) { raise Errno::ENOENT, "git" }) do
      assert_raises(Hive::ConfigError) { Hive::ProjectIdentity.git_common_dir("/project") }
    end

    with_tmp_dir do |dir|
      marker = File.join(dir, "marker")
      File.write(marker, "{}")
      File.chmod(0o644, marker)
      assert_raises(Hive::ConfigError) { Hive::ProjectIdentity.send(:read_marker, marker) }
      File.chmod(0o600, marker)
      File.write(marker, "{")
      assert_raises(Hive::ConfigError) { Hive::ProjectIdentity.send(:read_marker, marker) }
    end

    assert_raises(Hive::ConfigError) do
      Hive::ProjectIdentity.send(
        :verify_marker!, {}, marker: "/marker", digest: "digest",
        installation_id: "installation", database: database
      )
    end
    missing_db = Object.new
    missing_db.define_singleton_method(:read) do |&block|
      connection = Object.new
      connection.define_singleton_method(:[]) do |_name|
        Object.new.tap { |table| table.define_singleton_method(:[]) { |_query| nil } }
      end
      block.call(connection)
    end
    payload = {
      "schema" => "hive-project-identity", "schema_version" => 1,
      "installation_id" => "installation", "git_common_dir_digest" => "digest",
      "namespace_id" => "namespace"
    }
    assert_raises(Hive::ConfigError) do
      Hive::ProjectIdentity.send(
        :verify_marker!, payload, marker: "/marker", digest: "digest",
        installation_id: "installation", database: missing_db
      )
    end

    identity = Hive::ProjectIdentity::Identity.new(
      namespace_id: "namespace", installation_id: "installation",
      git_common_dir_digest: "digest", enrollment_generation: 1,
      marker_path: "/marker"
    )
    active_db = fake_identity_activation_database(
      namespace_id: "namespace", state: "active"
    )
    assert_nil Hive::ProjectIdentity.send(:activate!, database: active_db, identity: identity)
    changed_db = fake_identity_activation_database(
      namespace_id: "namespace", state: "pending"
    )
    assert_raises(Hive::ConfigError) do
      Hive::ProjectIdentity.send(:activate!, database: changed_db, identity: identity)
    end
  end

  def test_schema_installation_and_writer_service_error_paths
    assert_raises(Hive::ConfigError) do
      Hive::RuntimeControlPlane::CommandSchemaInstallation.validate_coordinates!(
        version: "1", location: "https://[", sha256: "a" * 64
      )
    end
    assert_raises(Hive::ConfigError) do
      Hive::RuntimeControlPlane::CommandSchemaInstallation.validate_coordinates!(
        version: "1", location: "https://", sha256: "a" * 64
      )
    end

    fake_installer = Object.new
    fake_installer.define_singleton_method(:service_lifecycle_state) { { "service_running" => true } }
    setup = Hive::Commands::Setup.new(environment: {})
    setup.define_singleton_method(:web_config) { {} }
    with_replaced_singleton_method(
      Hive::Commands::Web::ServiceInstaller, :new, ->(**) { fake_installer }
    ) do
      assert setup.send(:managed_web_running?)
    end
    fallback = Object.new
    fallback.define_singleton_method(:service_state) { { "service_running" => false } }
    with_replaced_singleton_method(
      Hive::Commands::Web::ServiceInstaller, :new, ->(**) { fallback }
    ) do
      refute setup.send(:managed_web_running?)
    end
    broken = Object.new
    broken.define_singleton_method(:service_lifecycle_state) { raise Hive::Error, "broken" }
    with_replaced_singleton_method(
      Hive::Commands::Web::ServiceInstaller, :new, ->(**) { broken }
    ) do
      assert_raises(Hive::ConfigError) do
        setup.send(:managed_web_running?)
      end
    end

    with_tmp_dir do |dir|
      path = File.join(dir, "pid")
      File.write(path, "pid: 1\n")
      original = File.method(:read)
      with_replaced_singleton_method(File, :read, lambda { |candidate, *args|
        raise Errno::EACCES, "blocked" if candidate == path
        original.call(candidate, *args)
      }) do
        assert_raises(Hive::ConfigError) do
          Hive::RuntimeControlPlane::CommandSchemaWriterGuard.verify_pid_file!(
            path, alive: ->(*) { false }, ownership: ->(*) { :dead }
          )
        end
      end
    end

    Dir.mktmpdir do |state_home|
      guard = Object.new
      guard.define_singleton_method(:verify!) { |web_running:, **| !web_running.call }
      result = Hive::RuntimeControlPlane::Installation.setup(
        state_home: state_home, install_command_receipts: true,
        rollback_package: TEST_PACKAGE, writer_guard: guard
      )
      assert_equal "active", result.fetch("phase")
    end
  end

  def test_command_schema_handles_database_errors
    connection = Object.new
    connection.define_singleton_method(:[]) { |_name| raise Sequel::DatabaseError, "broken" }
    refute Hive::RuntimeControlPlane::CommandSchema.exact?(connection)
  end

  def test_command_operation_project_root_callbacks_and_keyed_call_paths
    database = Struct.new(:installation_identity).new({ installation_id: "installation" })
    store = Struct.new(:database).new(database)
    task = Struct.new(:project_root).new("/project")

    resolver = Struct.new(:resolved) { def resolve = resolved }.new(task)
    with_replaced_singleton_method(Hive::TaskResolver, :new, ->(*) { resolver }) do
      act = Hive::Commands::Act.new(
        "run", "demo:task", observation: "token", project: "demo", json: true,
        idempotency_key: "key", command_receipt_store: store
      )
      operation = act.send(:command_operation)
      assert_equal "/project", operation.instance_variable_get(:@project_root).call
      with_replaced_singleton_method(
        Hive::Config, :registered_projects, -> { [ { "name" => "demo", "path" => "/project" } ] }
      ) do
        assert_equal [ "/project" ], operation.instance_variable_get(:@project_roots).call
      end
      failure = operation.instance_variable_get(:@failure_payload).call(Hive::UsageError.new("bad"))
      assert_equal false, failure.fetch("ok")
      text = operation.instance_variable_get(:@text_renderer).call(
        "result" => { "task_state" => "running", "stage" => "4-execute", "marker" => "EXECUTE" }
      )
      assert_includes text, "running"
    end

    approve = Hive::Commands::Approve.new(
      "task", idempotency_key: "key", command_receipt_store: store
    )
    with_replaced_singleton_method(approve, :resolve_task, -> { task }) do
      operation = approve.send(:command_operation)
      assert_equal "/project", operation.instance_variable_get(:@project_root).call
      with_replaced_singleton_method(
        Hive::Config, :registered_projects, -> { [ { "name" => "demo", "path" => "/project" } ] }
      ) do
        assert_equal [ "/project" ], operation.instance_variable_get(:@project_roots).call
      end
      failure = operation.instance_variable_get(:@failure_payload).call(Hive::UsageError.new("bad"))
      assert_equal false, failure.fetch("ok")
      text = operation.instance_variable_get(:@text_renderer).call(
        "noop" => true, "slug" => "task", "to_stage_dir" => "4-execute"
      )
      assert_kind_of String, text
    end
    stage = Hive::Commands::StageAction.new(
      "plan", "task", idempotency_key: "key", command_receipt_store: store
    )
    resolver = Struct.new(:resolved) { def resolve = resolved }.new(task)
    with_replaced_singleton_method(Hive::TaskResolver, :new, ->(*) { resolver }) do
      operation = stage.send(:command_operation)
      assert_equal "/project", operation.instance_variable_get(:@project_root).call
      with_replaced_singleton_method(
        Hive::Config, :registered_projects, -> { [ { "name" => "demo", "path" => "/project" } ] }
      ) do
        assert_equal [ "/project" ], operation.instance_variable_get(:@project_roots).call
      end
      failure = operation.instance_variable_get(:@failure_payload).call(Hive::UsageError.new("bad"))
      assert_equal false, failure.fetch("ok")
      text = operation.instance_variable_get(:@text_renderer).call(
        "noop" => true, "slug" => "task", "to_stage_dir" => "3-plan"
      )
      assert_kind_of String, text
    end
    answer = Hive::Commands::Answer.new(
      "task", binding: "binding", idempotency_key: "key", command_receipt_store: store
    )
    with_replaced_singleton_method(answer, :decode_binding, ->(*) { { "project" => "demo" } }) do
      with_replaced_singleton_method(answer, :resolve_task, ->(*) { task }) do
        operation = answer.send(:command_operation, "yes")
        assert_equal "/project", operation.instance_variable_get(:@project_root).call
        with_replaced_singleton_method(
          Hive::Config, :registered_projects, -> { [ { "name" => "demo", "path" => "/project" } ] }
        ) do
          assert_equal [ "/project" ], operation.instance_variable_get(:@project_roots).call
        end
        failure = operation.instance_variable_get(:@failure_payload).call(Hive::UsageError.new("bad"))
        assert_equal false, failure.fetch("ok")
      end
    end

    fresh = Hive::Commands::New.new(
      "demo", "idea", attachments: [ "/missing" ], idempotency_key: "key", json: true,
      command_receipt_store: store
    )
    operation = fresh.send(:command_operation)
    with_replaced_singleton_method(Hive::Config, :find_project, ->(*) { { "path" => "/project" } }) do
      assert_equal "/project", operation.instance_variable_get(:@project_root).call
    end
    with_replaced_singleton_method(Hive::Config, :find_project, ->(*) { nil }) do
      assert_raises(Hive::Commands::New::ProjectNotFound) do
        operation.instance_variable_get(:@project_root).call
      end
    end
    failure = operation.instance_variable_get(:@failure_payload).call(Hive::UsageError.new("bad"))
    assert_equal false, failure.fetch("ok")
    created = { "created" => true, "task_folder" => "/project/.hive-state/stages/1-inbox/task" }
    existing = created.merge(
      "created" => false, "next_action" => { "command" => "hive brainstorm task" }
    )
    task = Struct.new(:state_file).new("/project/.hive-state/stages/1-inbox/task/task.md")
    with_replaced_singleton_method(Hive::Task, :new, ->(*) { task }) do
      assert_includes operation.instance_variable_get(:@text_renderer).call(created), "captured"
    end
    existing_text = operation.instance_variable_get(:@text_renderer).call(existing)
    assert_includes existing_text, "already exists"
    assert_includes existing_text, "next: hive brainstorm task"

    yielding = Object.new
    yielding.define_singleton_method(:call) { |&block| block.call }
    answer = Hive::Commands::Answer.new(
      "task", binding: "binding", idempotency_key: "key", json: true,
      input: StringIO.new("yes\n"), output: StringIO.new
    )
    with_replaced_singleton_method(answer, :command_operation, ->(*) { yielding }) do
      with_replaced_singleton_method(answer, :mutation_payload, ->(**) { { "ok" => true } }) do
        assert_equal true, answer.call.fetch("ok")
      end
    end
    approve = Hive::Commands::Approve.new("task", idempotency_key: "key")
    with_replaced_singleton_method(approve, :command_operation, -> { yielding }) do
      with_replaced_singleton_method(approve, :do_call, -> { "approved" }) do
        assert_equal "approved", approve.call
      end
    end
  end

  def test_receipt_keyed_prune_namespace_resolution_and_usage_contract
    with_receipts do |project, database, store, _authority|
      pruner = Recorder.new("ok" => true)
      with_replaced_singleton_method(
        Hive::Config, :find_project, ->(*) { { "path" => project } }
      ) do
        command = Hive::Commands::Receipt.new(
          "prune", project: "demo", idempotency_key: "key", json: true,
          pruner: pruner, command_receipt_store: store
        )
        out, = capture_io do
          assert_raises(Hive::UsageError) { command.call }
        end
        assert_equal "usage", JSON.parse(out).fetch("error_kind")
        assert_equal 0, database.read { |db| db[:command_receipts].count }
        Hive::ProjectIdentity.resolve(project_root: project, database: database, create: true)

        confirmed = Hive::Commands::Receipt.new(
          "prune", project: "demo", idempotency_key: "confirmed-key", json: true,
          confirm: true, pruner: pruner, command_receipt_store: store
        )
        confirmed_out, = capture_io { assert_equal true, confirmed.call.fetch("ok") }
        assert JSON.parse(confirmed_out).fetch("command_receipt")
      end

      command = Hive::Commands::Receipt.new(
        "retire", "r", project: "demo", command_receipt_store: store
      )
      command.instance_variable_set(:@project_root, project)
      with_replaced_singleton_method(Hive::ProjectIdentity, :resolve, ->(**) { nil }) do
        assert_raises(Hive::ConfigError) { command.send(:selected_namespace_id) }
      end
      identity = Struct.new(:namespace_id).new("namespace")
      with_replaced_singleton_method(Hive::ProjectIdentity, :resolve, ->(**) { identity }) do
        assert_equal "namespace", command.send(:selected_namespace_id)
      end
      assert_equal "hive-receipt-prune",
                   Hive::CliUsageContracts.contract(%w[receipt prune --json]).fetch(:schema)
      assert_equal "hive-command-receipt",
                   Hive::CliUsageContracts.contract(%w[receipt retire id --json]).fetch(:schema)
      assert database
    end
  end

  def test_default_guards_and_missing_schema_fail_closed
    assert_nil Hive::CommandOwnerProof.dead({})

    with_tmp_dir do |state_home|
      assert Hive::RuntimeControlPlane::CommandSchemaWriterGuard.verify!(
        state_home: state_home, registered_projects: [],
        alive: ->(*) { false }, ownership: ->(*) { :dead }
      )
      status = Hive::RuntimeControlPlane::Installation.setup(state_home: state_home)
      assert_equal "active", status.fetch("phase")
    end

    transition = Hive::RuntimeControlPlane::AdmissionTransition.new(
      repository: Struct.new(:database).new(nil)
    )
    db = Object.new
    db.define_singleton_method(:table_exists?) { |_name| false }
    context = Hive::CommandOperation::Context.new(
      receipt_id: "receipt", effect_id: "effect", principal: "owner",
      principal_source: "test", ordinal: 0, receipt_generation: 1,
      request_fingerprint: "fingerprint",
      transport_request_id: "command-dispatch:v1:#{'a' * 64}",
      retry_horizon_expires_at: "2030-01-01T00:00:00Z"
    )
    assert_raises(Hive::ConfigError) do
      transition.send(:bind_command_context!, db, context.transport_request_id, context)
    end
  end

  def test_dead_owner_proof_independently_requires_local_host_pid_and_start_time
    base = {
      owner_host: Socket.gethostname, owner_pid: 42,
      owner_process_start: "recorded-start"
    }
    options = { host: Socket.gethostname, alive: ->(*) { false },
                ownership: ->(*) { :reused }, clock: -> { Time.utc(2030) } }

    assert_nil Hive::CommandOwnerProof.dead(base.merge(owner_host: "remote-host"), **options)
    assert_nil Hive::CommandOwnerProof.dead(base.merge(owner_pid: 0), **options)
    assert_nil Hive::CommandOwnerProof.dead(base.merge(owner_process_start: nil), **options)
    assert_nil Hive::CommandOwnerProof.dead(
      base, **options.merge(alive: ->(*) { true }, ownership: ->(*) { :verified })
    )
    proof = Hive::CommandOwnerProof.dead(base, **options)
    assert_equal "dead", proof.last.fetch("ownership")
  end

  def test_receipt_command_defensive_option_and_failure_callbacks
    maintenance = Recorder.new
    command = Hive::Commands::Receipt.new("retire", "receipt", maintenance: maintenance)
    assert_raises(Hive::UsageError) { command.send(:execute_retire) }
    assert_raises(Hive::UsageError) do
      Hive::Commands::Receipt.new("prune", force: true).send(:validate_subcommand_options!)
    end

    database = Struct.new(:installation_identity).new({ installation_id: "installation" })
    store = Struct.new(:database).new(database)
    keyed = Hive::Commands::Receipt.new(
      "prune", project: "demo", confirm: true, idempotency_key: "key",
      command_receipt_store: store
    )
    with_replaced_singleton_method(Hive::Config, :find_project, ->(*) { { "path" => "/project" } }) do
      operation = keyed.send(:command_operation)
      failure = operation.instance_variable_get(:@failure_payload).call(Hive::UsageError.new("bad"))
      assert_equal false, failure.fetch("ok")
    end
  end

  def test_cli_rejects_mixed_plan_policy_and_emits_keyed_archive_receipt
    cli = Hive::CLI.allocate
    with_replaced_singleton_method(
      cli, :options, -> { { review_level: "mandatory", idempotency_key: "key" } }
    ) do
      assert_raises(Hive::UsageError) { cli.plan("task") }
    end

    receipt = {
      "reason" => "complete", "receipt_digest" => "digest", "task_slug" => "task",
      "command_receipt" => { "id" => "id", "generation" => 2, "state" => "succeeded" }
    }
    options = {
      idempotency_key: "key", json: false, from: "8-finalize", project: "demo",
      reason: "complete", evidence: [ "proof" ], successor: nil, attestation: "signed",
      retry_horizon_expires_at: "2030-01-01T00:00:00Z"
    }
    operation = Object.new
    operation.define_singleton_method(:call) { |&block| block.call }
    operation_args = nil
    with_replaced_singleton_method(cli, :options, -> { options }) do
      with_replaced_singleton_method(cli, :close_task_interactively_unwrapped, ->(*) { receipt }) do
        with_replaced_singleton_method(Hive::CommandOperation, :new, lambda { |**kwargs|
          operation_args = kwargs
          operation
        }) do
          out, = capture_io { assert_equal receipt, cli.send(:close_task_interactively, "task") }
          assert_includes out, "command receipt: id generation 2 (succeeded)"
        end
      end
    end
    task = Struct.new(:project_root).new("/project")
    with_replaced_singleton_method(cli, :resolve_closure_task, ->(*) { task }) do
      assert_equal "/project", operation_args.fetch(:project_root).call
    end
    assert_equal "2030-01-01T00:00:00Z", operation_args.fetch(:retry_horizon_expires_at)
  end

  def test_remaining_validation_and_fault_translation_paths
    invalid = Hive::Commands::New::InvalidBaseError.new("bad")
    assert_equal "usage", Hive::Commands::New.new("demo", "idea").envelope_error_kind(invalid)

    with_receipts do |project, database, store, authority|
      terminal = terminal_claim(store, project, "terminal")
      row = store.receipt(terminal.receipt_id)
      maintenance = Hive::CommandReceiptMaintenance.new(database: database, authority: authority)
      assert_raises(Hive::UsageError) do
        maintenance.retire_with_evidence(
          row.fetch(:receipt_id), expected_generation: row.fetch(:generation),
          evidence: {}, reason: "x"
        )
      end

      now = Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc)
      database.transaction do |connection|
        connection[:command_maintenance_batches].insert(
          batch_id: "completed", namespace_id: row.fetch(:namespace_id), principal: "owner",
          principal_scope: "own", kind: "prune", state: "completed", generation: 1,
          owner_host: Socket.gethostname, owner_pid: 1, owner_process_start: "start",
          fixed_cutoff: now, candidates_json: "[]", outcomes_json: "[]",
          created_at: now, updated_at: now, completed_at: now
        )
      end
      assert_raises(Hive::UsageError) do
        maintenance.abandon_batch(
          "completed", expected_generation: 1, reason: "x", namespace_id: "other"
        )
      end
      assert_raises(Hive::UsageError) do
        maintenance.abandon_batch("completed", expected_generation: 1, reason: "x")
      end

      assert_raises(Hive::UsageError) do
        store.send(:parse_retry_horizon!, "2026-09-27T00:00:00")
      end
      assert_raises(Hive::UsageError) do
        store.send(:parse_retry_horizon!, "2026-99-99T00:00:00Z")
      end
    end

    fake_database = Struct.new(:path) do
      def read
        connection = Object.new
        connection.define_singleton_method(:fetch) do |sql|
          [ { value: sql.include?("page_size") ? 4096 : 1 } ]
        end
        yield connection
      end
    end.new("/database")
    policy = Hive::CommandReceiptCapacity::Policy.new(
      keyed_intake_enabled: true, nonterminal_limit: 1, concurrency_limit: 1,
      byte_admission_limit: 1, installation_nonterminal_limit: 1,
      installation_concurrency_limit: 1, installation_byte_admission_limit: 1,
      revision: "r", staffing: {}
    )
    capacity = Hive::CommandReceiptCapacity.new(database: fake_database, policy: policy)
    connection = Object.new
    connection.define_singleton_method(:fetch) do |sql|
      [ { value: sql.include?("page_size") ? 4096 : (sql.include?("page_count") ? 2 : 1) } ]
    end
    with_replaced_singleton_method(File, :stat, ->(*) { raise Errno::ENOENT }) do
      assert_equal 4096, capacity.occupied_installation_bytes(connection: connection)
    end
    with_replaced_singleton_method(File, :stat, ->(*) { raise Errno::EIO, "broken" }) do
        assert_raises(Hive::CommandCapacityError) do
          capacity.occupied_installation_bytes
        end
    end
  end

  def test_pruner_translates_preview_prune_and_capacity_failures
    authority = Hive::CommandMaintenanceAuthority.new(
      principal: "owner", principal_source: "test", installation_owner: true
    )
    database = Object.new
    database.define_singleton_method(:read_only) { raise Sequel::DatabaseError, "broken" }
    pruner = Hive::CommandReceiptPruner.new(database: database, authority: authority)
    error = assert_raises(Hive::CommandCapacityError) { pruner.preview }
    assert_equal "command_prune_preview_unavailable", error.reason

    database = Object.new
    database.define_singleton_method(:transaction) { raise Errno::ENOSPC, "full" }
    pruner = Hive::CommandReceiptPruner.new(database: database, authority: authority)
    with_replaced_singleton_method(pruner, :resolve_namespace, ->(**) { "namespace" }) do
      error = assert_raises(Hive::CommandCapacityError) { pruner.prune(namespace_id: "namespace") }
      assert_equal "command_prune_storage_unavailable", error.reason
    end
    original = Hive::CommandCapacityError.new(
      "busy", reason: :command_prune_busy, scope: :installation
    )
    assert_raises(Hive::CommandCapacityError) do
      pruner.send(:maintenance_failure!, :command_prune_busy, "retry", original)
    end
    translated = assert_raises(Hive::CommandCapacityError) do
      pruner.send(:maintenance_failure!, :command_prune_busy, "retry", IOError.new("broken"))
    end
    assert_includes translated.message, "retry"
  end

  def test_dispatch_repository_command_context_guards_and_comparison
    repository = Hive::RuntimeControlPlane::DispatchRepository.new(database: Object.new)
    db = Object.new
    db.define_singleton_method(:table_exists?) { |_name| false }
    context = {
      receipt_id: "receipt", effect_id: "effect", principal: "owner",
      principal_source: "test", ordinal: 0, receipt_generation: 1,
      request_fingerprint: "fingerprint",
      transport_request_id: "command-dispatch:v1:#{'a' * 64}"
    }
    assert_raises(Hive::ConfigError) do
      repository.send(:bind_command_context!, db, context.fetch(:transport_request_id), context)
    end

    table = Object.new
    table.define_singleton_method(:[]) { |_query| nil }
    table.define_singleton_method(:insert) { |_payload| true }
    db.define_singleton_method(:table_exists?) { |_name| true }
    db.define_singleton_method(:[]) { |_name| table }
    assert_raises(Hive::RuntimeControlPlane::IntegrityError) do
      repository.send(:bind_command_context!, db, "plain", context)
    end

    with_replaced_singleton_method(repository, :command_context, ->(*) { nil }) do
      assert repository.send(:same_command_context?, "id", nil)
      refute repository.send(:same_command_context?, "id", context)
    end
    existing = context.transform_keys(&:to_s).except("transport_request_id")
      .merge("source_identity" => context.fetch(:transport_request_id))
    with_replaced_singleton_method(repository, :command_context, ->(*) { existing }) do
      assert repository.send(:same_command_context?, "id", context)
    end
  end

  def test_github_auth_rejects_non_numeric_identity
    auth = Hive::Web::GithubAuth.new(config: {})
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.instance_variable_set(:@read, true)
    response.instance_variable_set(:@body, JSON.generate("login" => "owner", "id" => "1"))
    with_replaced_singleton_method(auth, :request, ->(*) { response }) do
      assert_raises(Hive::Error) { auth.send(:identity_for_token, "token") }
    end
  end

  private

  def executing_claim(store, project, key)
    claim = store.reserve(
      project_root: project, key: key, command: "approve", target: "task",
      request: {}, principal: "owner"
    )
    store.mark_executing(claim)
  end

  def terminal_claim(store, project, key)
    claim = store.reserve(
      project_root: project, key: key, command: "approve", target: "task",
      request: {}, principal: "owner"
    )
    store.succeed(claim, result: { "ok" => true }, status: 0)
  end

  def with_receipts
    Dir.mktmpdir do |dir|
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
        database: database, package_coordinates: TEST_PACKAGE
      )
      store = Hive::CommandReceiptStore.new(database: database)
      authority = Hive::CommandMaintenanceAuthority.new(
        principal: "owner", principal_source: "test", installation_owner: true
      )
      yield project, database, store, authority
    ensure
      database&.disconnect
    end
  end

  def fake_identity_activation_database(namespace_id:, state:)
    database = Object.new
    database.define_singleton_method(:transaction) do |&block|
      connection = Object.new
      connection.define_singleton_method(:[]) do |_name|
        Object.new.tap do |table|
          table.define_singleton_method(:where) { |**| table }
          table.define_singleton_method(:update) { |**| 0 }
        end
      end
      block.call(connection)
    end
    database.define_singleton_method(:read) do |&block|
      connection = Object.new
      connection.define_singleton_method(:[]) do |_name|
        Object.new.tap do |table|
          table.define_singleton_method(:[]) do |_query|
            { namespace_id: namespace_id, enrollment_state: state }
          end
        end
      end
      block.call(connection)
    end
    database
  end
end
