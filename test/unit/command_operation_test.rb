# frozen_string_literal: true

require "test_helper"
require "hive/command_operation"
require "hive/runtime_control_plane/command_schema_installation"

class CommandOperationTest < Minitest::Test
  include HiveTestHelper

  TEST_PACKAGE = {
    version: "0.0.0-test", location: "https://example.invalid/compat.gem", sha256: "d" * 64
  }.freeze

  def test_success_is_durable_before_output_and_identical_retry_does_not_execute
    with_operation do |operation, store|
      effects = 0
      first = capture_io do
        operation.call do
          effects += 1
          context = Hive::CommandOperation.current_context
          refute_nil context
          assert_match(/\Acommand-dispatch:v1:[0-9a-f]{64}\z/, context.transport_request_id)
          Hive::CommandOperation.record_effect_submission(
            kind: "attempt_dispatch",
            identity: { "request_id" => context.transport_request_id }
          )
          puts JSON.generate("schema" => "example", "ok" => true, "value" => 7)
        end
      end.first
      payload = JSON.parse(first)
      receipt = store.receipt(payload.dig("command_receipt", "id"))
      assert_equal "succeeded", receipt.fetch(:state)
      refute_nil receipt.fetch(:owner_process_start)
      effect = store.database.read do |db|
        db[:command_effects][receipt_id: receipt.fetch(:receipt_id)]
      end
      assert_equal "applied", effect.fetch(:state)
      evidence = Hive::RuntimeControlPlane::Codec.load_json(effect.fetch(:evidence_json))
      assert_equal "attempt_dispatch", evidence.fetch("submissions").first.fetch("kind")
      assert_equal true, evidence.fetch("boundary_completed")
      assert_nil Hive::CommandOperation.current_context

      second = capture_io do
        operation.call { flunk "replay must not execute the command body" }
      end.first

      assert_equal payload, JSON.parse(second)
      assert_equal 1, effects
    end
  end

  def test_exception_after_ownership_withholds_success_and_leaves_unresolved
    with_operation(key: "ambiguous") do |operation, store|
      assert_raises(Hive::Error) do
        capture_io do
          operation.call do
            puts JSON.generate("ok" => true)
            raise Hive::Error, "lost acknowledgement"
          end
        end
      end

      row = store.database.read { |db| db[:command_receipts].first(key_digest: Digest::SHA256.hexdigest("ambiguous")) }
      assert_equal "unresolved", row.fetch(:state)
    end
  end

  def test_retry_finalizes_the_authoritative_boundary_result_after_lost_receipt_commit
    with_operation(key: "lost-finalization") do |_operation, store, project|
      effects = 0
      original_succeed = store.method(:succeed)
      fail_once = true
      store.define_singleton_method(:succeed) do |claim, result:, status: 0|
        if fail_once
          fail_once = false
          raise Sequel::DatabaseError, "simulated lost finalization acknowledgement"
        end
        original_succeed.call(claim, result: result, status: status)
      end
      operation = Hive::CommandOperation.new(
        key: "lost-finalization", command: "approve", target: "task",
        request: { from: "3-plan" }, project_root: project, principal: "owner",
        json: true, structured: true, store: store
      )

      assert_raises(Sequel::DatabaseError) do
        operation.call do
          effects += 1
          { "schema" => "hive-approve", "ok" => true, "slug" => "task" }
        end
      end
      row = store.database.read do |db|
        db[:command_receipts].first(key_digest: Digest::SHA256.hexdigest("lost-finalization"))
      end
      assert_equal "executing", row.fetch(:state)

      replayed = operation.call { flunk "authoritative-result recovery must not repeat the effect" }
      assert_equal "task", replayed.fetch("slug")
      assert_equal "succeeded", replayed.dig("command_receipt", "state")
      assert_equal 1, effects
    end
  end

  def test_interrupted_reconcilable_provider_effect_resumes_without_resubmitting_applied_push
    with_operation(key: "provider-reconcile") do |_operation, store, project|
      provider_applied = false
      push_calls = 0
      attempts = 0
      operation = Hive::CommandOperation.new(
        key: "provider-reconcile", command: "stage_action", mode: "open-pr",
        target: "task", request: { from: "4-execute" }, project_root: project,
        principal: "owner", json: true, structured: true, store: store
      )
      body = lambda do
        attempts += 1
        Hive::CommandOperation.record_effect_submission(
          kind: "github_push", identity: { "publication_id" => "publication-1", "head_oid" => "a" * 40 }
        )
        unless provider_applied
          push_calls += 1
          provider_applied = true
          Hive::CommandOperation.record_effect_observation(
            source: "github_push", correlation_id: "publication-1",
            evidence: { "after_oid" => "a" * 40 }
          )
          raise Hive::Error, "provider acknowledgement was lost"
        end
        Hive::CommandOperation.record_effect_observation(
          source: "github_push", correlation_id: "publication-1",
          evidence: { "after_oid" => "a" * 40 }
        )
        { "schema" => "hive-stage-action", "ok" => true, "phase" => "published" }
      end

      assert_raises(Hive::Error) { operation.call(&body) }
      result = operation.call(&body)

      assert_equal "published", result.fetch("phase")
      assert_equal 2, attempts
      assert_equal 1, push_calls
    end
  end

  def test_interrupted_unknown_effect_remains_unresolved
    with_operation(key: "unknown-reconcile") do |_operation, store, project|
      operation = Hive::CommandOperation.new(
        key: "unknown-reconcile", command: "approve", target: "task", request: {},
        project_root: project, principal: "owner", json: true, structured: true, store: store
      )
      assert_raises(Hive::Error) { operation.call { raise Hive::Error, "unknown effect" } }

      assert_raises(Hive::CommandUnresolved) do
        operation.call { flunk "unknown effects must not be resumed" }
      end
    end
  end

  def test_structured_failed_replay_emits_saved_payload_and_exits_with_saved_status
    with_operation do |_operation, store, project|
      structured = Hive::CommandOperation.new(
        key: "failed", command: "approve", target: "task", request: { from: "3-plan" },
        project_root: project, principal: "owner", json: true, structured: true, store: store
      )
      assert_raises(Hive::UsageError) do
        structured.call { raise Hive::UsageError, "invalid transition" }
      end

      output, = capture_io do
        exit_error = assert_raises(SystemExit) { structured.call { flunk "failed replay executed" } }
        assert_equal Hive::ExitCodes::USAGE, exit_error.status
      end
      payload = JSON.parse(output)
      assert_equal false, payload.fetch("ok")
      assert_equal "UsageError", payload.fetch("error_class")
      assert_equal "usage", payload.fetch("error_kind")
      assert_equal Hive::ExitCodes::USAGE, payload.fetch("exit_code")
    end
  end

  def test_answer_replay_reconstructs_response_binding_not_request_binding
    with_operation do |_operation, store, project|
      request_binding = { "project" => "demo", "ordinal" => 1 }
      response_binding = Base64.urlsafe_encode64(
        JSON.generate(request_binding.merge("task_generation" => "next")), padding: false
      )
      operation = Hive::CommandOperation.new(
        key: "answer", command: "answer", mode: "write", target: "task",
        request: { "binding" => request_binding }, project_root: project,
        principal: "owner", json: true, structured: true, store: store
      )
      expected = operation.call do
        { "schema" => "hive-answer", "ok" => true,
          "slot" => { "binding" => response_binding } }
      end
      replayed = operation.call { flunk "answer replay executed" }

      assert_equal expected, replayed
      assert_equal response_binding, replayed.dig("slot", "binding")
    end
  end

  def test_display_format_can_change_without_reexecuting_the_effect
    with_operation do |_operation, store, project|
      effects = 0
      json_operation = Hive::CommandOperation.new(
        key: "display", command: "approve", target: "task", request: {},
        project_root: project, principal: "owner", json: true, store: store,
        text_renderer: ->(payload) { "approved #{payload.fetch('slug')}\n" }
      )
      capture_io do
        json_operation.call do
          effects += 1
          payload = { "schema" => "hive-approve", "ok" => true, "slug" => "task" }
          puts JSON.generate(payload)
          payload
        end
      end
      text_operation = Hive::CommandOperation.new(
        key: "display", command: "approve", target: "task", request: {},
        project_root: project, principal: "owner", json: false, store: store,
        text_renderer: ->(payload) { "approved #{payload.fetch('slug')}\n" }
      )
      output, = capture_io { text_operation.call { flunk "display replay executed" } }

      assert_equal "approved task\n", output
      assert_equal 1, effects
    end
  end

  def test_text_first_replay_can_render_json_without_reexecuting_the_effect
    with_operation do |_operation, store, project|
      effects = 0
      text_operation = Hive::CommandOperation.new(
        key: "text-display", command: "approve", target: "task", request: {},
        project_root: project, principal: "owner", json: false, store: store,
        text_renderer: ->(payload) { "approved #{payload.fetch('slug')}\n" }
      )
      capture_io do
        text_operation.call do
          effects += 1
          payload = { "schema" => "hive-approve", "ok" => true, "slug" => "task" }
          puts "approved task"
          payload
        end
      end
      json_operation = Hive::CommandOperation.new(
        key: "text-display", command: "approve", target: "task", request: {},
        project_root: project, principal: "owner", json: true, store: store
      )
      output, = capture_io { json_operation.call { flunk "display replay executed" } }

      assert_equal "task", JSON.parse(output).fetch("slug")
      assert_equal 1, effects
    end
  end

  def test_capture_never_reopens_process_stdout
    with_operation do |operation, _store|
      with_replaced_singleton_method(STDOUT, :reopen, ->(*) { flunk "STDOUT was reopened" }) do
        capture_io do
          operation.call { puts JSON.generate("schema" => "example", "ok" => true) }
        end
      end
      refute STDOUT.closed?
    end
  end

  def test_interrupted_keyed_prune_resumes_before_replay
    with_operation do |_operation, store, project|
      identity = Hive::ProjectIdentity.resolve(project_root: project, database: store.database, create: true)
      claim = store.reserve(
        project_root: project, key: "prune-resume", command: "receipt", mode: "prune",
        target: "demo", request: { "confirm" => true }, principal: "owner",
        maintenance: true, execute: true
      )
      now = Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc)
      store.database.transaction do |db|
        db[:command_maintenance_batches].insert(
          batch_id: "resume-batch", namespace_id: identity.namespace_id,
          administrative_receipt_id: claim.receipt_id, principal: "owner",
          principal_scope: "own", kind: "prune", state: "executing", generation: 1,
          owner_host: Socket.gethostname, owner_pid: Process.pid,
          owner_process_start: Hive::Lock.process_start_time(Process.pid),
          fixed_cutoff: now, candidates_json: "[]", outcomes_json: "[]",
          created_at: now, updated_at: now
        )
      end
      store.mark_unresolved(claim, reason: "interrupted")
      operation = Hive::CommandOperation.new(
        key: "prune-resume", command: "receipt", mode: "prune", target: "demo",
        request: { "confirm" => true }, project_root: project, principal: "owner",
        json: true, structured: true, maintenance: true, store: store
      )

      result = operation.call { { "schema" => "hive-receipt-prune", "ok" => true } }
      assert_equal true, result.fetch("ok")
      assert_equal "succeeded", store.receipt(claim.receipt_id).fetch(:state)
    end
  end

  def test_registered_project_receipt_replays_before_mutable_target_resolution
    with_operation(key: "moved-target") do |_operation, store, project|
      original = File.join(project, ".hive-state", "stages", "3-plan", "task")
      moved = File.join(project, ".hive-state", "stages", "4-execute", "task")
      FileUtils.mkdir_p(original)
      first = Hive::CommandOperation.new(
        key: "moved-target", command: "approve", target: original,
        request: { from: "3-plan", project: "demo" }, project_root: project,
        principal: "owner", json: true, structured: true, store: store
      )
      expected = first.call { { "schema" => "hive-approve", "ok" => true, "slug" => "task" } }
      FileUtils.mkdir_p(File.dirname(moved))
      FileUtils.mv(original, moved)
      resolutions = 0
      replay = Hive::CommandOperation.new(
        key: "moved-target", command: "approve", target: original,
        request: { from: "3-plan", project: "demo" },
        project_roots: -> { [ project ] },
        project_root: lambda {
          resolutions += 1
          raise Hive::InvalidTaskPath, "the original folder was moved or deleted"
        },
        principal: "owner", json: true, structured: true, store: store
      )

      assert_equal expected, replay.call { flunk "replay must not execute the command body" }
      FileUtils.rm_rf(moved)
      assert_equal expected, replay.call { flunk "deleted-task replay must not execute the command body" }
      assert_equal 0, resolutions
    end
  end

  private

  def with_operation(key: "stable")
    Dir.mktmpdir do |dir|
      project = File.join(dir, "project")
      FileUtils.mkdir_p(File.join(project, ".hive-state"))
      system("git", "init", "--quiet", project, exception: true)
      File.write(
        File.join(project, ".hive-state", "config.yml"),
        { "command_receipts" => { "keyed_intake_enabled" => true } }.to_yaml
      )
      state = File.join(dir, "state")
      FileUtils.mkdir_p(state, mode: 0o700)
      database = Hive::RuntimeControlPlane::Database.new(
        path: Hive::Paths.runtime_control_plane_path(state)
      ).migrate!
      Hive::RuntimeControlPlane::CommandSchemaInstallation.install!(
        database: database, package_coordinates: TEST_PACKAGE
      )
      store = Hive::CommandReceiptStore.new(database: database)
      operation = Hive::CommandOperation.new(
        key: key, command: "approve", target: "task", request: { from: "3-plan" },
        project_root: project, principal: "owner", json: true, store: store
      )
      yield operation, store, project
    ensure
      database&.disconnect
    end
  end
end
