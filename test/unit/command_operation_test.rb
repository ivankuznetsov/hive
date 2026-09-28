# frozen_string_literal: true

require "test_helper"
require "shellwords"
require "hive/attempts/context"
require "hive/command_operation"
require "hive/runtime_control_plane/command_schema_installation"

class CommandOperationTest < Minitest::Test
  include HiveTestHelper

  TEST_PACKAGE = {
    version: "0.0.0-test", location: "https://example.invalid/compat.gem", sha256: "d" * 64
  }.freeze

  def test_worker_context_records_effect_evidence_without_an_outer_operation
    context = Hive::CommandOperation::Context.new(
      receipt_id: "receipt", effect_id: "effect", principal: "owner",
      principal_source: "test", ordinal: 0, receipt_generation: 3,
      request_fingerprint: "fingerprint",
      transport_request_id: "command-dispatch:v1:#{'a' * 64}",
      retry_horizon_expires_at: "2030-01-01T00:00:00Z"
    )
    installed = Struct.new(:command_context).new(context)
    submissions = []
    observations = []
    store = Object.new
    store.define_singleton_method(:record_effect_submission) { |**attributes| submissions << attributes }
    store.define_singleton_method(:record_effect_observation) { |**attributes| observations << attributes }

    with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { installed }) do
      with_replaced_singleton_method(Hive::CommandReceiptStore, :new, -> { store }) do
        Hive::CommandOperation.record_effect_submission(
          kind: "attempt_dispatch", identity: { "request_id" => "request-1" }
        )
        Hive::CommandOperation.record_effect_observation(
          source: "attempt_dispatch", correlation_id: "request-1",
          evidence: { "state" => "queued" }
        )
      end
    end

    assert_equal "receipt", submissions.first.fetch(:receipt_id)
    assert_equal 3, submissions.first.fetch(:generation)
    assert_equal "request-1", observations.first.fetch(:correlation_id)
  end

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

      assert_equal first, second
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

      persistence_error = assert_raises(Hive::CommandUnresolved) do
        operation.call do
          effects += 1
          { "schema" => "hive-approve", "ok" => true, "slug" => "task" }
        end
      end
      assert_equal "command_unresolved_pending", persistence_error.reason
      refute_nil persistence_error.command_receipt
      row = store.database.read do |db|
        db[:command_receipts].first(key_digest: Digest::SHA256.hexdigest("lost-finalization"))
      end
      assert_equal "unresolved", row.fetch(:state)
      assert_equal row.fetch(:receipt_id), persistence_error.command_receipt.fetch("id")
      assert_equal row.fetch(:generation), persistence_error.command_receipt.fetch("generation")
      assert_equal "unresolved", persistence_error.command_receipt.fetch("state")

      replayed = operation.call { flunk "authoritative-result recovery must not repeat the effect" }
      assert_equal "task", replayed.fetch("slug")
      assert_equal "succeeded", replayed.dig("command_receipt", "state")
      assert_equal 1, effects
    end
  end

  def test_interrupted_reconcilable_provider_effect_resumes_without_resubmitting_applied_push
    with_operation(key: "provider-reconcile") do |_operation, store, project|
      remote = File.join(File.dirname(project), "remote.git")
      system("git", "init", "--bare", "--quiet", remote, exception: true)
      File.write(File.join(project, "result.txt"), "published\n")
      system("git", "-C", project, "add", "result.txt", exception: true)
      system("git", "-C", project, "-c", "user.name=Hive Test", "-c",
             "user.email=hive@example.invalid", "commit", "--quiet", "-m", "publish",
             exception: true)
      head_oid = `git -C #{Shellwords.escape(project)} rev-parse HEAD`.strip
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
          kind: "github_push", identity: { "publication_id" => "publication-1", "head_oid" => head_oid }
        )
        observed = `git ls-remote #{Shellwords.escape(remote)} refs/heads/main`.split.first
        unless observed == head_oid
          push_calls += 1
          system("git", "-C", project, "push", "--quiet", remote, "HEAD:refs/heads/main",
                 exception: true)
          Hive::CommandOperation.record_effect_observation(
            source: "github_push", correlation_id: "publication-1",
            evidence: { "after_oid" => head_oid }
          )
          raise Hive::Error, "provider acknowledgement was lost"
        end
        Hive::CommandOperation.record_effect_observation(
          source: "github_push", correlation_id: "publication-1",
          evidence: { "after_oid" => observed }
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

  def test_interrupted_task_activity_does_not_resume_without_authoritative_domain_reconciliation
    with_operation(key: "task-activity-uncertain") do |_operation, store, project|
      operation = Hive::CommandOperation.new(
        key: "task-activity-uncertain", command: "approve", target: "task",
        request: {}, project_root: project, principal: "owner",
        json: true, structured: true, store: store
      )
      assert_raises(Hive::Error) do
        operation.call do
          Hive::CommandOperation.record_effect_submission(
            kind: "task_activity", identity: { "request_id" => "activity-1" }
          )
          Hive::CommandOperation.record_effect_observation(
            source: "task_activity", correlation_id: "activity-1",
            evidence: { "task_stage" => "4-execute" }
          )
          raise Hive::Error, "failed after moving the task"
        end
      end

      assert_raises(Hive::CommandUnresolved) do
        operation.call { flunk "task mutation must not be repeated as whole-command resume" }
      end
    end
  end

  def test_interrupted_durable_dispatch_request_can_resume_from_persisted_request_state
    with_operation(key: "dispatch-request-reconcile") do |_operation, store, project|
      register_runtime_project(database: store.database, name: "demo", path: project)
      repository = Hive::RuntimeControlPlane::DispatchRepository.new(database: store.database)
      attempts = 0
      writes = 0
      operation = Hive::CommandOperation.new(
        key: "dispatch-request-reconcile", command: "stage_action", mode: "develop",
        target: "task", request: {}, project_root: project, principal: "owner",
        json: true, structured: true, store: store
      )
      body = lambda do
        attempts += 1
        context = Hive::CommandOperation.current_context
        Hive::CommandOperation.record_effect_submission(
          kind: "dispatch_request", identity: { "request_id" => context.transport_request_id }
        )
        unless repository.fetch(context.transport_request_id)
          writes += 1
          repository.write_request!(
            project: "demo", slug: "task", argv: %w[hive run task],
            request_id: context.transport_request_id, command_context: context
          )
        end
        raise Hive::Error, "lost dispatch acknowledgement" if attempts == 1

        { "schema" => "hive-stage-action", "ok" => true }
      end

      error = assert_raises(Hive::Error) { operation.call(&body) }
      assert_equal "lost dispatch acknowledgement", error.message
      receipt = store.database.read do |database|
        database[:command_receipts].first(
          key_digest: Digest::SHA256.hexdigest("dispatch-request-reconcile")
        )
      end
      reconciliation_state = store.database.read do |database|
        {
          effect: database[:command_effects][receipt_id: receipt.fetch(:receipt_id)],
          request: database[:dispatch_requests].first
        }
      end
      assert store.send(:reconcilable_effect?, receipt), reconciliation_state.inspect
      result = operation.call(&body)

      assert_equal true, result.fetch("ok")
      assert_equal 2, attempts
      assert_equal 1, writes
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

  def test_invalid_task_path_after_effect_preparation_is_not_retry_eligible
    with_operation(key: "applied-path-error") do |_operation, store, project|
      operation = Hive::CommandOperation.new(
        key: "applied-path-error", command: "stage_action", mode: "develop",
        target: "task", request: {}, project_root: project, principal: "owner",
        json: true, structured: true, store: store
      )
      assert_raises(Hive::InvalidTaskPath) do
        operation.call { raise Hive::InvalidTaskPath, "task moved after mutation" }
      end
      row = store.database.read do |db|
        db[:command_receipts].first(
          key_digest: Digest::SHA256.hexdigest("applied-path-error")
        )
      end
      assert_equal "unresolved", row.fetch(:state)
      assert_equal 0, row.fetch(:retry_eligible)
    end
  end

  def test_retryable_contention_before_submission_reacquires_the_same_key
    with_operation(key: "busy-retry") do |_operation, store, project|
      operation = Hive::CommandOperation.new(
        key: "busy-retry", command: "approve", target: "task", request: {},
        project_root: project, principal: "owner", json: true, structured: true, store: store
      )
      assert_raises(Hive::ConcurrentRunError) do
        operation.call { raise Hive::ConcurrentRunError, "task lock held" }
      end
      row = store.database.read do |database|
        database[:command_receipts].first(key_digest: Digest::SHA256.hexdigest("busy-retry"))
      end
      assert_equal "aborted", row.fetch(:state)

      result = operation.call { { "schema" => "hive-approve", "ok" => true } }
      assert_equal true, result.fetch("ok")
      assert_equal "succeeded", store.receipt(row.fetch(:receipt_id)).fetch(:state)
    end
  end

  def test_quiet_json_uses_the_returned_payload_instead_of_empty_stdout
    with_operation(key: "quiet-json") do |_operation, store, project|
      operation = Hive::CommandOperation.new(
        key: "quiet-json", command: "approve", target: "task", request: {},
        project_root: project, principal: "owner", json: true, store: store
      )
      output, = capture_io do
        operation.call { { "schema" => "hive-approve", "ok" => true, "slug" => "task" } }
      end
      assert_equal "task", JSON.parse(output).fetch("slug")
    end
  end

  def test_usage_error_before_effect_submission_is_failed_and_retry_eligible
    with_operation do |_operation, store, project|
      structured = Hive::CommandOperation.new(
        key: "failed", command: "approve", target: "task", request: { from: "3-plan" },
        project_root: project, principal: "owner", json: true, structured: true, store: store
      )
      assert_raises(Hive::UsageError) do
        structured.call { raise Hive::UsageError, "invalid transition" }
      end

      row = store.database.read do |database|
        database[:command_receipts].first(key_digest: Digest::SHA256.hexdigest("failed"))
      end
      assert_equal "failed", row.fetch(:state)
      assert_equal 1, row.fetch(:retry_eligible)
      successor = store.allocate_successor(
        namespace_id: row.fetch(:namespace_id), principal: "owner",
        intent_id: "test-intent", intent_version: 1,
        predecessor_receipt_id: row.fetch(:receipt_id), delivery_cycle_id: "cycle-1",
        request_fingerprint: row.fetch(:request_fingerprint), project_root: project
      )
      assert_equal row.fetch(:receipt_id), successor.fetch("predecessor_receipt_id")
      assert_equal 1, successor.fetch("successor_ordinal")

      store.define_singleton_method(:fail_non_application) do |*_, **|
        flunk "terminal replay must not persist failure again"
      end
      store.define_singleton_method(:mark_unresolved) do |*_, **|
        flunk "terminal replay must not persist uncertainty again"
      end

      output, = capture_io do
        replay_exit = assert_raises(SystemExit) do
          structured.call { flunk "failed receipt replay must not execute" }
        end
        assert_equal Hive::ExitCodes::USAGE, replay_exit.status
      end
      assert_equal false, JSON.parse(output).fetch("ok")
    end
  end

  def test_text_mode_structured_failure_replay_does_not_emit_a_json_envelope
    with_operation do |_operation, store, project|
      json_operation = Hive::CommandOperation.new(
        key: "failed-text", command: "approve", target: "task", request: {},
        project_root: project, principal: "owner", json: true, structured: true, store: store
      )
      assert_raises(Hive::UsageError) do
        json_operation.call { raise Hive::UsageError, "invalid transition" }
      end
      text_operation = Hive::CommandOperation.new(
        key: "failed-text", command: "approve", target: "task", request: {},
        project_root: project, principal: "owner", json: true, structured: true,
        display_json: false, store: store
      )

      output, = capture_io do
        error = assert_raises(Hive::CommandReplayFailure) do
          text_operation.call { flunk "failed receipt replay must not execute" }
        end
        assert_equal Hive::ExitCodes::USAGE, error.exit_code
      end
      assert_empty output
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
      persisted = store.database.read do |database|
        database[:command_receipts].first(key_digest: Digest::SHA256.hexdigest("answer"))
      end
      refute_includes persisted.fetch(:result_json), response_binding,
                      "the literal response binding must be reconstructed, not stored"
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

  def test_json_only_replay_renders_text_without_reexecuting_the_effect
    with_operation do |_operation, store, project|
      effects = 0
      json_operation = Hive::CommandOperation.new(
        key: "json-display", command: "stage_action", mode: "develop", target: "task",
        request: {}, project_root: project, principal: "owner", json: true, store: store,
        text_renderer: ->(payload) { "developed #{payload.fetch('slug')}\n" }
      )
      capture_io do
        json_operation.call do
          effects += 1
          puts JSON.generate("schema" => "hive-stage-action", "ok" => true, "slug" => "task")
        end
      end
      text_operation = Hive::CommandOperation.new(
        key: "json-display", command: "stage_action", mode: "develop", target: "task",
        request: {}, project_root: project, principal: "owner", json: false, store: store,
        text_renderer: ->(payload) { "developed #{payload.fetch('slug')}\n" }
      )

      output, = capture_io { text_operation.call { flunk "JSON replay executed" } }
      assert_equal "developed task\n", output
      assert_equal 1, effects
    end
  end

  def test_observation_token_template_reconstructs_byte_identical_success
    with_operation do |_operation, store, project|
      token = "a" * 64
      operation = Hive::CommandOperation.new(
        key: "token-template", command: "act", target: "demo:task",
        request: { observation: token }, project_root: project,
        principal: "owner", json: true, structured: true, store: store
      )
      expected = operation.call do
        { "schema" => "hive-act", "ok" => true, "observation_token" => token }
      end

      replayed = operation.call { flunk "token replay executed" }
      assert_equal expected, replayed
      assert_equal Hive::RuntimeControlPlane::Codec.dump_json(expected),
                   Hive::RuntimeControlPlane::Codec.dump_json(replayed)
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

  def test_thread_routed_output_delegates_only_supported_io_methods
    captured = StringIO.new
    passthrough = StringIO.new
    output = Hive::CommandOperation::ThreadRoutedOutput.new(
      capture_thread: Thread.current, captured: captured, passthrough: passthrough
    )

    output.sync = true
    assert output.sync
    output.write("captured")
    assert_equal "captured", output.string
    assert output.respond_to?(:string)
    refute output.respond_to?(:not_an_io_method)
    assert_raises(NoMethodError) { output.not_an_io_method }
  end

  def test_registered_project_roots_are_bounded_by_name_and_addressable_paths
    projects = [
      { "name" => "one", "path" => "/srv/one", "hive_state_path" => "/state/one" },
      { "name" => "two", "path" => "/srv/two" }
    ]
    with_replaced_singleton_method(Hive::Config, :registered_projects, -> { projects }) do
      assert_equal [ "/srv/one" ],
                   Hive::CommandOperation.registered_project_roots(target: "task", project: "one")
      assert_empty Hive::CommandOperation.registered_project_roots(target: "task", project: "missing")
      assert_equal %w[/srv/one /srv/two],
                   Hive::CommandOperation.registered_project_roots(target: "task")
      assert_equal [ "/srv/one" ],
                   Hive::CommandOperation.registered_project_roots(target: "/state/one/stages/task")
    end
  end

  def test_cross_project_lookup_can_resume_an_interrupted_maintenance_operation
    claim = Hive::CommandReceiptStore::Claim.new(
      disposition: :resume, receipt_id: "receipt", namespace_id: "namespace",
      generation: 3, state: "unresolved", principal: "owner",
      request_fingerprint: "fingerprint", result: nil, status: nil, reason: nil,
      public_receipt: nil, project_root: "/project"
    )
    executing = claim.with(disposition: :new, generation: 4, state: "executing")
    store = Object.new
    store.define_singleton_method(:lookup_existing_in_projects) { |**| claim }
    store.define_singleton_method(:resume_maintenance) { |_claim| executing }
    store.define_singleton_method(:prepare_effect) do |_claim, **|
      { effect_id: "effect", ordinal: 0 }
    end
    store.define_singleton_method(:complete_effect) { |*_, **| true }
    store.define_singleton_method(:succeed) { |*_, **| true }
    operation = Hive::CommandOperation.new(
      key: "resume", command: "receipt", mode: "prune", target: "demo",
      request: { confirm: true }, project_roots: [ "/project" ],
      project_root: -> { flunk "resumed lookup must retain its stored project root" },
      principal: "owner", json: true, structured: true, maintenance: true, store: store
    )

    result = operation.call { { "schema" => "hive-receipt-prune", "ok" => true } }
    assert_equal "succeeded", result.dig("command_receipt", "state")
  end

  def test_failure_persistence_and_replay_templates_fail_closed
    store = Object.new
    store.define_singleton_method(:update_effect) { |*_, **| raise Hive::CommandConflict }
    store.define_singleton_method(:authoritative_result_recorded?) { |**| false }
    unresolved = []
    store.define_singleton_method(:mark_unresolved) { |claim, **| unresolved << claim.receipt_id }
    operation = Hive::CommandOperation.new(
      key: nil, command: "approve", target: "task", request: {}, project_root: "/project",
      principal: "owner", store: store
    )
    claim = Struct.new(:receipt_id).new("receipt")
    operation.send(:persist_uncertainty, claim, { effect_id: "effect" })
    assert_equal [ "receipt" ], unresolved

    store.define_singleton_method(:abort_before_effect) do |*_args, **_kwargs|
      raise Hive::CommandConflict, "abort raced"
    end
    operation.send(:persist_uncertainty, claim, nil)
    assert_equal [ "receipt", "receipt" ], unresolved

    operation.send(
      :persist_failure, claim, { effect_id: "effect" },
      Hive::UsageError.new("invalid transition")
    )
    assert_equal [ "receipt", "receipt", "receipt" ], unresolved
    assert_equal({ "format" => "text", "text" => "invalid\n" },
                 operation.send(:stored_failure, Hive::UsageError.new("invalid")))

    operation.instance_variable_set(:@command, "answer")
    malformed = { "slot" => { "binding" => Base64.urlsafe_encode64("{") } }
    assert_equal malformed, operation.send(:template_payload, malformed)
    conflicting = {
      "slot" => { "binding" => {
        "$command_response_fields" => { "project" => "demo" },
        "$command_response_field_order" => [ "project" ],
        "encoding" => "base64url-json", "template_version" => 1, "sha256" => "wrong"
      } }
    }
    assert_raises(Hive::CommandConflict) { operation.send(:expand_template, conflicting) }
    conflicting["slot"]["binding"]["$command_response_field_order"] = [ "project", "project" ]
    assert_raises(Hive::CommandConflict) { operation.send(:expand_template, conflicting) }
    conflicting["slot"]["binding"]["encoding"] = "unknown"
    assert_raises(Hive::CommandConflict) { operation.send(:expand_template, conflicting) }

    assert_equal "config", operation.send(:failure_error_kind, Hive::ConfigError.new("bad"))
    assert_equal "usage", operation.send(
      :failure_error_kind, Hive::OperationalActionUsageError.new("bad")
    )
    assert_equal "internal", operation.send(:failure_error_kind, Hive::Error.new("bad"))

    unavailable_database = Object.new
    unavailable_database.define_singleton_method(:read) { |_block = nil, &block| block&.call }
    unavailable_store = Struct.new(:database).new(unavailable_database)
    unavailable = Hive::CommandOperation.new(
      key: nil, command: "approve", target: "task", request: {}, project_root: "/project",
      principal: "owner", store: unavailable_store
    )
    with_replaced_singleton_method(
      Hive::RuntimeControlPlane::CommandSchema, :installed?, ->(*) { false }
    ) do
      assert_raises(Hive::ConfigError) { unavailable.send(:verify_receipt_extension!) }
    end

    replay = Hive::CommandOperation.new(
      key: nil, command: "approve", target: "task", request: {}, project_root: "/project",
      principal: "owner", json: true, store: store
    )
    payload = { "ok" => true }
    stored = {
      "format" => "json", "payload" => payload,
      "expanded_sha256" => Digest::SHA256.hexdigest(
        Hive::RuntimeControlPlane::Codec.dump_json(payload)
      )
    }
    replay_claim = Struct.new(:state, :result, :status, :public_receipt)
      .new("succeeded", stored, 0, {})
    output, = capture_io { assert_nil replay.send(:replay, replay_claim) }
    assert_equal "#{JSON.generate(payload)}\n", output

    assert_raises(Hive::RuntimeControlPlane::IntegrityError) do
      replay.send(:exact_json_payload, { "json_bytes" => "{}\n" }, payload)
    end
    assert_raises(Hive::RuntimeControlPlane::IntegrityError) do
      replay.send(:exact_json_payload, { "json_bytes" => "{\n" }, payload)
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
