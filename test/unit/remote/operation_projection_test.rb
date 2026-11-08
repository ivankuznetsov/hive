# frozen_string_literal: true

require "test_helper"
require "hive/remote/operation_projection"
require "hive/remote/command_service"
require "hive/remote/read_service"
require "hive/commands/init"
require "hive/runtime_control_plane/command_schema_installation"
require "hive/attempts/api"

class RemoteOperationProjectionTest < Minitest::Test
  include HiveTestHelper

  PACKAGE = { version: "0.0.0-test", location: "https://example.invalid/compat.gem", sha256: "a" * 64 }.freeze
  PRINCIPAL = "installation:test:token:original".freeze

  def test_durable_lookup_exposes_only_admission_and_hides_other_principals_without_read
    with_server do |service, projection, store, project, task|
      native = service.create(project: project, text: "Private task content", slug: "private-260923-abcd",
        idempotency_key: "create", principal: PRINCIPAL, scopes: [ "create" ])
      id = native.dig("command_receipt", "id")
      own = projection.call(project: project, id: id, principal: PRINCIPAL, scopes: [ "create" ])
      assert_equal "succeeded", own.fetch("state")
      assert_equal true, own.fetch("result_available")
      assert_equal native.fetch("task_id"), own.dig("acknowledgement", "task_id")
      json = JSON.generate(own)
      refute_includes json, project.fetch("path")
      refute_includes json, "Private task content"
      refute_includes json, "command\":\"hive"
      error = assert_raises(Hive::Remote::Error) do
        projection.call(project: project, id: id, principal: "installation:test:token:other", scopes: [ "create" ])
      end
      assert_equal 404, error.status
      assert_equal own, projection.call(project: project, id: id, principal: "installation:test:token:other", scopes: [ "read" ])
      assert_equal id, projection.existing(project: project, key: "create", principal: PRINCIPAL).fetch(:receipt_id)
      assert_raises(Hive::CommandConflict) do
        projection.existing(project: project, key: "create", principal: "installation:test:token:other")
      end
      assert_nil projection.existing(project: project, key: "unknown", principal: PRINCIPAL)
      %w[unknown 00000000-0000-0000-0000-000000000000].each do |unknown|
        assert_equal 404, assert_raises(Hive::Remote::Error) {
          projection.call(project: project, id: unknown, principal: PRINCIPAL, scopes: [ "read" ])
        }.status
      end
      store.database.transaction { |db| db[:command_receipts].where(receipt_id: id).update(principal_source: "local_cli") }
      assert_equal 404, assert_raises(Hive::Remote::Error) {
        projection.call(project: project, id: id, principal: PRINCIPAL, scopes: [ "read" ])
      }.status
      assert File.directory?(task.folder)
    end
  end

  def test_project_lookup_never_enrolls_an_unseen_namespace
    with_server do |_service, projection, _store, _project, _task|
      with_tmp_git_repo do |other_root|
        project = { "path" => other_root }
        refute File.exist?(Hive::ProjectIdentity.marker_path(other_root))
        assert_nil projection.existing(project: project, key: "unknown", principal: PRINCIPAL)
        assert_equal 404, assert_raises(Hive::Remote::Error) {
          projection.call(project: project, id: "00000000-0000-0000-0000-000000000000", principal: PRINCIPAL, scopes: [ "read" ])
        }.status
        refute File.exist?(Hive::ProjectIdentity.marker_path(other_root))
      end
    end
  end

  def test_original_admission_is_preserved_separately_from_a_detached_attempt_after_transport_cleanup
    with_server do |service, projection, store, project, task|
      native = approval(service, project, task)
      id = native.dig("command_receipt", "id")
      initial = projection.call(project: project, id: id, principal: PRINCIPAL, scopes: [ "answer" ])
      assert_equal "queued", initial.fetch("state")
      assert_equal "2-brainstorm", initial.dig("progress", "stage")
      assert_equal "succeeded", initial.fetch("command_outcome")
      request_id = native.fetch("request_id")
      repository = Hive::RuntimeControlPlane::DispatchRepository.new(database: store.database)
      admitted = Hive::Attempts::API.new.dispatch_request(repository.fetch(request_id))
      assert_equal :accepted, admitted.status
      attempts = Hive::Attempts::Repository.open_default
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
      until (record = attempts.fetch(admitted.attempt.attempt_id)).final?
        running = projection.call(project: project, id: id, principal: PRINCIPAL, scopes: [ "answer" ])
        assert_includes %w[running succeeded], running.fetch("state")
        flunk "detached worker did not finish" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.05
      end
      assert_equal "succeeded", record.receipt.fetch("outcome"), record.receipt.inspect
      store.database.transaction { |db| db[:dispatch_requests].where(request_id: request_id).delete }
      restarted = Hive::Remote::OperationProjection.new(store: Hive::CommandReceiptStore.new(database: store.database))
      complete = restarted.call(project: project, id: id, principal: PRINCIPAL, scopes: [ "answer" ])
      assert_equal "succeeded", complete.fetch("state")
      assert_equal initial.fetch("acknowledgement"), complete.fetch("acknowledgement")
      assert_equal record.attempt_id, complete.dig("progress", "attempt_id")
      assert_equal "2-brainstorm", complete.dig("progress", "stage")
      refute_includes JSON.generate(complete), project.fetch("path")
      store.database.transaction do |db|
        db[:attempts].where(attempt_id: record.attempt_id).update(state: "lost", outcome: nil)
      end
      lost = restarted.call(project: project, id: id, principal: PRINCIPAL, scopes: [])
      assert_equal "unresolved", lost.fetch("state")
      assert_equal initial.fetch("acknowledgement"), lost.fetch("acknowledgement")
    end
  end

  def test_settled_and_pruned_progress_are_explicit_without_claiming_the_operation_never_existed
    with_server do |service, projection, store, project, task|
      native = approval(service, project, task)
      id = native.dig("command_receipt", "id")
      store.database.transaction { |db| db[:dispatch_requests].where(request_id: native.fetch("request_id")).delete }
      expired = projection.call(project: project, id: id, principal: PRINCIPAL, scopes: [])
      assert_equal "result_expired", expired.fetch("state")
      assert expired.fetch("result_available")
      assert expired.fetch("result_expired")
      store.database.transaction do |db|
        db[:command_receipts].where(receipt_id: id).update(state: "settled", result_json: nil, result_digest: nil)
      end
      settled = projection.call(project: project, id: id, principal: PRINCIPAL, scopes: [])
      assert_equal "settled", settled.fetch("state")
      refute settled.fetch("result_available")
      assert settled.fetch("result_expired")
      assert_nil settled.fetch("acknowledgement")
      assert_equal native.fetch("request_id"), settled.dig("progress", "request_id")
    end
  end

  def test_command_lifecycle_and_failed_dispatch_outcomes_have_static_public_states
    with_server do |service, projection, store, project, task|
      native = approval(service, project, task)
      id = native.dig("command_receipt", "id")
      { "prepared" => "accepted", "executing" => "running", "unresolved" => "unresolved", "aborted" => "unresolved", "failed" => "failed" }.each do |stored, public_state|
        store.database.transaction { |db| db[:command_receipts].where(receipt_id: id).update(state: stored) }
        assert_equal public_state, projection.call(project: project, id: id, principal: PRINCIPAL, scopes: []).fetch("state")
      end
      store.database.transaction { |db| db[:command_receipts].where(receipt_id: id).update(state: "succeeded") }
      repository = Hive::RuntimeControlPlane::DispatchRepository.new(database: store.database)
      repository.write_result!(chat_id: nil, project: project.fetch("name"), slug: task.slug,
        request_id: native.fetch("request_id"), exit_code: 1, command: "private server command",
        receipt: { "outcome" => "failed", "reason" => "/private/server/path" })
      failed = projection.call(project: project, id: id, principal: PRINCIPAL, scopes: [])
      assert_equal "failed", failed.fetch("state")
      refute_includes JSON.generate(failed), "/private/server/path"
      refute_includes JSON.generate(failed), "private server command"
      store.database.transaction do |db|
        row = db[:dispatch_requests][request_id: native.fetch("request_id")]
        result = Hive::RuntimeControlPlane::Codec.load_json(row.fetch(:result_json)).reject { |key, _| key == "receipt" }
        bytes = Hive::RuntimeControlPlane::Codec.dump_json(result)
        db[:dispatch_requests].where(request_id: native.fetch("request_id")).update(result_json: bytes, result_digest: Digest::SHA256.hexdigest(bytes))
      end
      assert_equal "failed", projection.call(project: project, id: id, principal: PRINCIPAL, scopes: []).fetch("state")
      store.database.transaction do |db|
        db[:dispatch_requests].where(request_id: native.fetch("request_id")).update(
          state: "completed", result_state: nil, result_json: nil, result_digest: nil,
          result_available_at: nil, result_delivered_at: nil, retain_until: nil
        )
      end
      assert_equal "unresolved", projection.call(project: project, id: id, principal: PRINCIPAL, scopes: []).fetch("state")
      store.database.transaction { |db| db[:command_receipts].where(receipt_id: id).update(result_digest: "0" * 64) }
      assert_raises(Hive::ConfigError) { projection.call(project: project, id: id, principal: PRINCIPAL, scopes: []) }
    end
  end

  def test_answer_acknowledgement_exposes_counts_and_identity_without_question_or_answer_content
    with_server do |service, projection, _store, project, task|
      File.write(task.state_file, "# Brainstorm\n### Q1. Private question?\n### A1.\n<!-- WAITING -->\n")
      inventory = Hive::Commands::Answer.inventory(task.slug, project: project.fetch("name"))
      binding = inventory.fetch("slots").first.fetch("binding")
      handle = "private-remote-answer-handle"
      native = service.answer(project: project, task: task, binding: binding, answer: "Private answer",
        idempotency_key: "answer", principal: PRINCIPAL, scopes: [ "answer" ], remote_handle: handle,
        state_reader: ->(current) { Hive::Remote::ReadService.validate_state!(current, allow_missing: false, strict_text: true) })
      row = projection.existing(project: project, key: "answer", principal: PRINCIPAL)
      assert_equal binding, projection.answer_binding(row, handle: handle)
      assert_raises(Hive::CommandConflict) { projection.answer_binding(row, handle: "different-handle") }
      { command: "approve", mode: "read", principal_source: "local_cli" }.each do |field, value|
        assert_raises(Hive::CommandConflict) { projection.answer_binding(row.merge(field => value), handle: handle) }
      end
      request = Hive::RuntimeControlPlane::Codec.load_json(row.fetch(:frozen_request_json))
      request.delete("remote_binding")
      legacy = row.merge(frozen_request_json: Hive::RuntimeControlPlane::Codec.dump_json(request))
      assert_nil projection.answer_binding(legacy, handle: handle)
      result = projection.call(project: project, id: native.dig("command_receipt", "id"), principal: PRINCIPAL, scopes: [ "answer" ])
      assert_equal "written", result.dig("acknowledgement", "outcome")
      assert_equal task.id, result.dig("acknowledgement", "task_id")
      assert_equal 0, result.dig("acknowledgement", "unanswered_count")
      assert_equal true, result.dig("acknowledgement", "complete")
      refute_includes JSON.generate(result), "Private"
      refute_includes JSON.generate(result), "binding"
      refute_includes JSON.generate(result), project.fetch("path")
    end
  end

  private

  def approval(service, project, task)
    service.approve(project: project, task: task, stage: "2-brainstorm",
      generation: Hive::WorkflowAdmission.generation_for(task, project: project.fetch("name")),
      idempotency_key: "approval", principal: PRINCIPAL, scopes: [ "answer" ])
  end

  def with_server
    with_tmp_global_config do
      with_tmp_git_repo do |root|
        capture_io { Hive::Commands::Init.new(root).call }
        project = Hive::Config.registered_projects.find { |row| row.fetch("path") == root }
        path = File.join(project.fetch("hive_state_path"), "config.yml")
        config = YAML.safe_load_file(path)
        config["command_receipts"] = { "keyed_intake_enabled" => true }
        File.write(path, config.to_yaml)
        store = Hive::CommandReceiptStore.new
        Hive::RuntimeControlPlane::CommandSchemaInstallation.install!(database: store.database, package_coordinates: PACKAGE)
        folder = File.join(project.fetch("hive_state_path"), "stages", "2-brainstorm", "operation-260923-abcd")
        FileUtils.mkdir_p(folder)
        Hive::TaskMeta.write(folder, id: 42, slug: "operation-260923-abcd", display_name: "Private task content", workflow: "coding")
        File.write(File.join(folder, "brainstorm.md"), "# Brainstorm\n<!-- COMPLETE -->\n")
        yield Hive::Remote::CommandService.new(store: store), Hive::Remote::OperationProjection.new(store: store), store, project, Hive::Task.new(folder)
      end
    end
  end
end
