require "test_helper"
require "hive/remote/command_service"
require "hive/commands/init"
require "hive/runtime_control_plane/command_schema_installation"
require "hive/attempts/api"
require "hive/remote/read_service"
require "hive/daemon/dispatcher"

class RemoteCommandServiceTest < Minitest::Test
  include HiveTestHelper

  PACKAGE = { version: "0.0.0-test", location: "https://example.invalid/compat.gem", sha256: "a" * 64 }.freeze
  PRINCIPAL = "installation:test:token:public-token".freeze
  FAKE_AGENT = File.expand_path("../../fixtures/fake-claude", __dir__)

  def test_advance_is_durably_queued_without_running_the_stage_and_replays_original_admission
    with_server do |service, store, repository, project, task|
      descriptor = Hive::OperationalAction.descriptor_for_task(task, project: project.fetch("name"))
      before = File.binread(task.state_file)
      result = nil
      stdout, stderr = capture_io do
        result = service.action(
          project: project, task: task, action_id: descriptor.fetch("action_id"),
          observation: descriptor.fetch("observation_token"),
          idempotency_key: "remote-action", principal: PRINCIPAL, scopes: [ "act" ]
        )
      end
      assert_empty stdout
      assert_empty stderr
      assert_equal true, result.fetch("queued")
      assert_equal before, File.binread(task.state_file)
      request = repository.fetch(result.fetch("request_id"))
      assert_equal PRINCIPAL, request.remote_authority.fetch("principal")
      assert_equal "stage_action", request.remote_authority.dig("effect", "kind")
      assert_equal "plan", request.remote_authority.dig("effect", "verb")
      assert_equal "api_token", store.receipt(result.dig("command_receipt", "id")).fetch(:principal_source)
      File.write(task.state_file, "# Changed after admission\n<!-- WAITING -->\n")
      replay = service.action(
        project: project, task: task, action_id: descriptor.fetch("action_id"),
        observation: descriptor.fetch("observation_token"),
        idempotency_key: "remote-action", principal: PRINCIPAL, scopes: [ "act" ]
      )
      assert_equal result, replay
      assert_equal 1, repository.pending.length
    end
  end

  def test_approval_effect_requires_answer_scope_and_force_is_never_admitted
    with_server do |service, _store, repository, project, task|
      row = Hive::OperationalAction.observed_row(task, project: project.fetch("name"))
      row["action"] = "ready_to_advance"
      row["marker"] = "complete"
      effect = Hive::WorkflowAdmission.effect_for(task: task, row: row, action_id: "workflow.advance", project: project)
      assert_equal "approve", effect.fetch("kind")
      assert_raises(Hive::Remote::Error) do
        service.authorize_effect!(effect, scopes: [ "act" ], action: true)
      end
      service.authorize_effect!(effect, scopes: %w[act answer], action: true)
      row["marker"] = "none"
      error = assert_raises(Hive::OperationalActionUsageError) do
        Hive::WorkflowAdmission.effect_for(task: task, row: row, action_id: "workflow.advance", project: project)
      end
      assert_match(/locally/, error.message)
      assert_empty repository.pending
    end
  end

  def test_create_is_nonprinting_principal_bound_and_replays_after_the_task_moves
    with_server do |service, store, _repository, project, _task|
      result = nil
      stdout, stderr = capture_io do
        result = service.create(project: project, text: "A remote idea", slug: "remote-idea-260923-abcd",
          idempotency_key: "remote-create", principal: PRINCIPAL, scopes: [ "create" ])
      end
      assert_empty stdout
      assert_empty stderr
      folder = result.fetch("task_folder")
      destination = folder.sub("/1-inbox/", "/2-brainstorm/")
      FileUtils.mv(folder, destination)
      replay = service.create(project: project, text: "A remote idea", slug: "remote-idea-260923-abcd",
        idempotency_key: "remote-create", principal: PRINCIPAL, scopes: [ "create" ])
      assert_equal result, replay
      receipt = store.receipt(result.dig("command_receipt", "id"))
      assert_equal PRINCIPAL, receipt.fetch(:principal)
      assert_raises(Hive::CommandConflict) do
        service.create(project: project, text: "A remote idea", slug: "remote-idea-260923-abcd",
          idempotency_key: "remote-create", principal: "installation:test:token:other", scopes: [ "create" ])
      end
    end
  end

  def test_answer_forwards_the_key_and_replays_the_original_receipt_after_advancement
    with_server do |service, store, _repository, project, task|
      File.write(task.state_file, "# Brainstorm\n### Q1. Which version?\n### A1.\n<!-- WAITING -->\n")
      inventory = Hive::Commands::Answer.inventory(task.slug, project: project.fetch("name"))
      binding = inventory.fetch("slots").first.fetch("binding")
      first = service.answer(project: project, task: task, binding: binding, answer: "One",
        idempotency_key: "remote-answer", principal: PRINCIPAL, scopes: [ "answer" ])
      assert_equal "written", first.fetch("outcome")
      assert_equal PRINCIPAL, store.receipt(first.dig("command_receipt", "id")).fetch(:principal)
      destination = task.folder.sub("/2-brainstorm/", "/3-plan/")
      FileUtils.mv(task.folder, destination)
      replay = service.answer(project: project, task: Hive::Task.new(destination), binding: binding, answer: "One",
        idempotency_key: "remote-answer", principal: PRINCIPAL, scopes: [ "answer" ])
      assert_equal first, replay
      assert_includes File.read(File.join(destination, "brainstorm.md")), "One"
    end
  end

  def test_semantic_reads_are_nonprinting_and_artifacts_only_use_workflow_owned_references
    with_server do |_service, _store, _repository, project, task|
      reader = Hive::Remote::ReadService.new
      document = nil
      stdout, stderr = capture_io { document = reader.task(project: project, task: task) }
      assert_empty stdout
      assert_empty stderr
      assert_equal task.slug, document.dig("task", "slug")
      assert_equal task.slug, reader.status(projects: [ project ]).fetch("projects").first.fetch("tasks").first.fetch("slug")
      assert_equal "brainstorm.md", reader.artifacts(project: project, task: task).fetch("records").first.fetch("name")
      assert_includes reader.artifact(project: project, task: task, reference: "brainstorm.md", max_bytes: 8).content, "Brain"
      assert_raises(Hive::InvalidTaskPath) { reader.artifact(project: project, task: task, reference: "../config.yml") }
      assert_equal "unavailable", reader.logs(project: project, task: task).fetch("state")
      assert_equal "unavailable", reader.diff(project: project, task: task).state
    end
  end

  def test_stale_observation_and_unknown_actions_leave_no_dispatch
    with_server do |service, _store, repository, project, task|
      assert_raises(Hive::StaleOperationalObservation) do
        service.action(project: project, task: task, action_id: "workflow.advance", observation: "0" * 64,
          idempotency_key: "stale-action", principal: PRINCIPAL, scopes: [ "act" ])
      end
      assert_raises(Hive::OperationalActionUsageError) do
        service.action(project: project, task: task, action_id: "release", observation: "0" * 64,
          idempotency_key: "bad-action", principal: PRINCIPAL, scopes: [ "act" ])
      end
      assert_empty repository.pending
    end
  end

  def test_queued_approval_is_executed_by_a_detached_worker_with_the_bound_principal
    with_server do |service, _store, repository, project, task|
      result = service.approve(project: project, task: task, stage: "2-brainstorm",
        generation: Hive::WorkflowAdmission.generation_for(task, project: project.fetch("name")),
        idempotency_key: "remote-approval", principal: PRINCIPAL, scopes: [ "answer" ])
      assert File.directory?(task.folder)
      request = repository.fetch(result.fetch("request_id"))
      admitted = Hive::Attempts::API.new.dispatch_request(request)
      assert_equal :accepted, admitted.status
      attempts = Hive::Attempts::Repository.open_default
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
      loop do
        record = attempts.fetch(admitted.attempt.attempt_id)
        break if record.final?
        flunk "detached approval did not finish" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.05
      end
      record = attempts.fetch(admitted.attempt.attempt_id)
      log = Hive::Attempts::API.new.correlated_log_reader.read(record.receipt.fetch("log_reference"))
      assert_equal "succeeded", record.receipt.fetch("outcome"), log.inspect
      assert File.directory?(File.join(project.fetch("hive_state_path"), "stages", "3-plan", task.slug))
      refute File.exist?(task.folder)
      assert_equal PRINCIPAL, repository.command_context(request.request_id).fetch("principal")
      daemon = daemon_for(repository)
      daemon.send(:write_attempt_dispatch_result, request, record, record.receipt, now: Time.now.utc)
      assert_equal "closed", store_pin(repository, result).fetch(:lifecycle_status)
      original_receipt = repository.database.read { |db| db[:command_receipts][receipt_id: result.dig("command_receipt", "id")] }
      assert_equal result.dig("command_receipt", "generation"), original_receipt.fetch(:generation)
      assert_equal "succeeded", original_receipt.fetch(:state)
    end
  end

  def test_queued_action_runs_the_guarded_shared_executor_in_a_detached_worker
    with_server do |service, _store, repository, project, task|
      descriptor = Hive::OperationalAction.descriptor_for_task(task, project: project.fetch("name"))
      result = service.action(project: project, task: task, action_id: descriptor.fetch("action_id"),
        observation: descriptor.fetch("observation_token"), idempotency_key: "remote-real-action",
        principal: PRINCIPAL, scopes: [ "act" ])
      plan = File.join(project.fetch("hive_state_path"), "stages", "3-plan", task.slug, "plan.md")
      with_env("HIVE_CLAUDE_BIN" => FAKE_AGENT, "HIVE_CODEX_BIN" => FAKE_AGENT,
               "HIVE_FAKE_CLAUDE_WRITE_FILE" => plan,
               "HIVE_FAKE_CLAUDE_WRITE_CONTENT" => "# Plan\n<!-- WAITING -->\n") do
        admitted = Hive::Attempts::API.new.dispatch_request(repository.fetch(result.fetch("request_id")))
        assert_equal :accepted, admitted.status
        record = await_attempt(admitted.attempt.attempt_id)
        log = Hive::Attempts::API.new.correlated_log_reader.read(record.receipt.fetch("log_reference"))
        assert_equal "succeeded", record.receipt.fetch("outcome"), log.inspect
      end
      assert File.file?(plan)
      refute File.exist?(task.folder)
    end
  end

  def test_queued_action_rejects_real_input_changes_before_the_worker_can_advance
    with_server do |service, _store, repository, project, task|
      descriptor = Hive::OperationalAction.descriptor_for_task(task, project: project.fetch("name"))
      result = service.action(project: project, task: task, action_id: descriptor.fetch("action_id"),
        observation: descriptor.fetch("observation_token"), idempotency_key: "changed-remote-action",
        principal: PRINCIPAL, scopes: [ "act" ])
      File.write(task.state_file, "# Changed input\n<!-- WAITING -->\n")
      admitted = Hive::Attempts::API.new.dispatch_request(repository.fetch(result.fetch("request_id")))
      assert_equal :accepted, admitted.status
      record = await_attempt(admitted.attempt.attempt_id)
      assert_equal "failed", record.receipt.fetch("outcome")
      assert_equal "# Changed input\n<!-- WAITING -->\n", File.read(task.state_file)
      refute File.exist?(task.folder.sub("/2-brainstorm/", "/3-plan/"))
    end
  end

  def test_retry_only_admits_a_canonical_workflow_command_with_the_original_receipt_identity
    with_server do |service, store, repository, project, task|
      File.write(task.state_file, "# Brainstorm\n<!-- ERROR reason=timeout marker_id=retry-marker -->\n")
      descriptor = Hive::OperationalAction.descriptor_for_task(task, project: project.fetch("name"))
      assert_equal "workflow.retry", descriptor.fetch("action_id")
      before = File.binread(task.state_file)
      result = service.action(project: project, task: task, action_id: descriptor.fetch("action_id"),
        observation: descriptor.fetch("observation_token"), idempotency_key: "remote-retry",
        principal: PRINCIPAL, scopes: [ "act" ])
      assert_equal true, result.fetch("queued"), result.inspect
      request = repository.fetch(result.fetch("request_id"))
      assert_equal "brainstorm", request.argv[1]
      assert_equal PRINCIPAL, request.remote_authority.fetch("principal")
      assert_equal result.dig("command_receipt", "id"), repository.command_context(request.request_id).fetch("receipt_id")
      assert_equal before, File.binread(task.state_file)
      assert_equal "succeeded", store.receipt(result.dig("command_receipt", "id")).fetch(:state)
    end
  end

  def test_daemon_defers_an_unfinished_admission_and_closes_the_pin_for_rejected_work
    with_server do |service, _store, repository, project, task|
      result = service.approve(project: project, task: task, stage: "2-brainstorm",
        generation: Hive::WorkflowAdmission.generation_for(task, project: project.fetch("name")),
        idempotency_key: "remote-admission-lifecycle", principal: PRINCIPAL, scopes: [ "answer" ])
      request = repository.fetch(result.fetch("request_id"))
      daemon = daemon_for(repository)
      assert daemon.send(:remote_admission_ready?, request)
      assert_equal "active", store_pin(repository, result).fetch(:lifecycle_status)
      refute repository.expired?(request, now: Time.now.utc + 3600)
      repository.database.transaction do |db|
        db[:command_receipts].where(receipt_id: result.dig("command_receipt", "id")).update(state: "executing")
      end
      refute daemon.send(:remote_admission_ready?, request)
      repository.database.transaction do |db|
        db[:command_receipts].where(receipt_id: result.dig("command_receipt", "id")).update(state: "succeeded")
      end
      daemon.send(:reject_request, request, reason: "stale_task_generation")
      assert_equal "closed", store_pin(repository, result).fetch(:lifecycle_status)
      assert_equal "completed", repository.fetch(request.request_id).state
      row = repository.database.read { |db| db[:dispatch_requests][request_id: request.request_id] }
      assert_equal "delivered", row.fetch(:result_state)
      result_payload = Hive::RuntimeControlPlane::Codec.load_json(row.fetch(:result_json))
      assert_equal "failed", result_payload.dig("receipt", "outcome")
    end
  end

  def test_worker_retains_authenticated_authority_without_reopening_completed_admission
    with_server do |service, store, repository, project, task|
      result = queue_approval(service, project, task, key: "retained-worker-authority")
      record = worker_record(project, task, result)
      origin = Hive::Attempts::Context.send(:load_command_context, repository, record)
      authority = Hive::Attempts::Context.send(:load_remote_authority, repository, record, origin)
      assert_equal PRINCIPAL, authority.fetch("principal")
      before = store.receipt(origin.receipt_id)
      assert_nil Hive::Attempts::Context.send(:writable_command_context, repository, origin, authority)
      assert_equal before, store.receipt(origin.receipt_id)

      [ nil, origin.with(principal: "installation:test:token:foreign"), origin.with(principal_source: "local_cli") ].each do |untrusted|
        error = assert_raises(Hive::Attempts::RepositoryError) do
          Hive::Attempts::Context.send(:load_remote_authority, repository, record, untrusted)
        end
        assert_includes error.message, "authority does not match"
      end
      [ { "project" => "foreign" }, { "task_id" => "foreign" }, { "task_slug" => "foreign" } ].each do |identity|
        assert_raises(Hive::Attempts::RepositoryError) do
          Hive::Attempts::Context.send(:load_remote_authority, repository, record.merge(identity), origin)
        end
      end

      [ { state: "executing" }, { state: "unresolved" }, { mode: "local" },
        { principal: "installation:test:token:foreign" }, { request_fingerprint: "0" * 64 } ].each do |changes|
        repository.database.transaction { |db| db[:command_receipts].where(receipt_id: origin.receipt_id).update(changes) }
        error = assert_raises(Hive::Attempts::RepositoryError) do
          Hive::Attempts::Context.send(:writable_command_context, repository, origin, authority)
        end
        assert_includes error.message, "admission receipt is not complete"
        repository.database.transaction do |db|
          db[:command_receipts].where(receipt_id: origin.receipt_id).update(before.slice(*changes.keys))
        end
      end
      assert_equal before, store.receipt(origin.receipt_id)
    end
  end

  def test_daemon_rejects_a_changed_admission_principal_or_receipt_before_dispatch
    with_server do |service, _store, repository, project, task|
      result = queue_approval(service, project, task, key: "changed-admission-binding")
      request = repository.fetch(result.fetch("request_id"))
      daemon = daemon_for(repository)
      repository.database.transaction do |db|
        db[:command_dispatch_contexts].where(request_id: request.request_id).update(principal: "foreign")
      end
      error = assert_raises(Hive::CommandConflict) { daemon.send(:remote_admission_ready?, request) }
      assert_includes error.message, "admission identity changed"
      repository.database.transaction do |db|
        db[:command_dispatch_contexts].where(request_id: request.request_id).update(principal: PRINCIPAL)
        db[:command_receipts].where(receipt_id: result.dig("command_receipt", "id")).update(request_fingerprint: "0" * 64)
      end
      error = assert_raises(Hive::CommandConflict) { daemon.send(:remote_admission_ready?, request) }
      assert_includes error.message, "receipt identity changed"
      assert File.directory?(task.folder)
      assert_equal "queued", repository.fetch(request.request_id).state
    end
  end

  def test_approval_worker_installs_its_retained_guard_and_refuses_force_or_destination_overrides
    with_server do |service, store, repository, project, task|
      result = queue_approval(service, project, task, key: "guarded-approval-worker")
      authority = repository.fetch(result.fetch("request_id")).remote_authority
      generation = Hive::Attempts::Generation.resolve(task: task, project: project.fetch("name"), intended_stage: "2-brainstorm")
      context = Hive::Attempts::Context.send(:new, attempt_id: "approval-worker", project: project.fetch("name"),
        task_generation: generation.task_input_epoch, ownership_generation: generation.ownership_generation,
        intended_stage: "2-brainstorm", remote_authority: authority)
      with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) do
        [ { force: true }, { to: "3-plan" }, { force: true, observation_guard: ->(_) { } }, { to: "3-plan", observation_guard: ->(_) { } } ].each do |options|
          error = assert_raises(Hive::OperationalActionUsageError) do
            Hive::Commands::Approve.new(task.slug, project: project.fetch("name"), from: "2-brainstorm", **options).call
          end
          assert_includes error.message, "advance locally"
          assert File.directory?(task.folder)
        end
        # A composing command already supplies its locked observation guard.
        guard_called = false
        composed = Hive::Commands::Approve.new(task.slug, project: project.fetch("name"), observation_guard: ->(_) { guard_called = true })
        composed.send(:install_remote_guard!)
        composed.instance_variable_get(:@observation_guard).call(task)
        assert guard_called
        before_marker = File.binread(task.state_file)
        File.write(task.state_file, "# Changed\n<!-- WAITING -->\n")
        assert_raises(Hive::OperationalActionUsageError, Hive::StaleOperationalObservation) { composed.instance_variable_get(:@observation_guard).call(task) }
        File.binwrite(task.state_file, before_marker)
        before = store.receipt(result.dig("command_receipt", "id"))
        payload = nil
        stdout, stderr = capture_io do
          payload = Hive::Commands::Approve.new(task.slug, project: project.fetch("name"),
            from: "2-brainstorm", quiet: true).call
        end
        assert_empty stdout
        assert_empty stderr
        assert payload.fetch("ok")
        assert_equal before, store.receipt(result.dig("command_receipt", "id"))
      end
      refute File.exist?(task.folder)
    end
  end

  def test_retained_action_authority_is_checked_by_the_shared_executor
    with_server do |service, store, repository, project, task|
      descriptor = Hive::OperationalAction.descriptor_for_task(task, project: project.fetch("name"))
      accepted = service.action(project: project, task: task, action_id: descriptor.fetch("action_id"),
        observation: descriptor.fetch("observation_token"), idempotency_key: "retained-executor-authority",
        principal: PRINCIPAL, scopes: [ "act" ])
      executor = Hive::OperationalAction::Executor.new(remote_authority: repository.fetch(accepted.fetch("request_id")).remote_authority)
      plan = File.join(project.fetch("hive_state_path"), "stages", "3-plan", task.slug, "plan.md")
      before = store.receipt(accepted.dig("command_receipt", "id"))
      original_cwd = Dir.pwd
      with_env("HIVE_CLAUDE_BIN" => FAKE_AGENT, "HIVE_CODEX_BIN" => FAKE_AGENT,
               "HIVE_FAKE_CLAUDE_WRITE_FILE" => plan,
               "HIVE_FAKE_CLAUDE_WRITE_CONTENT" => "# Plan\n<!-- WAITING -->\n") do
        with_attempt_context(attempt_id: "retained-action-worker", task_generation: 0) do
          result = nil
          stdout, stderr = capture_io do
            result = executor.execute(action_id: descriptor.fetch("action_id"), target: descriptor.fetch("target"),
              observation_token: descriptor.fetch("observation_token"))
          end
          assert_empty stdout
          assert_empty stderr
          assert_equal "3-plan", result.fetch("stage")
        end
      end
      assert_equal original_cwd, Dir.pwd
      assert_equal before, store.receipt(accepted.dig("command_receipt", "id"))
      assert File.file?(plan)
    end
  end

  def test_act_only_cannot_admit_an_approval_effect_under_the_task_lock
    with_server do |service, store, repository, project, task|
      task = Hive::Task.new(File.join(project.fetch("hive_state_path"), "stages", "1-inbox", "approval-260923-abcd")).tap do |current|
        FileUtils.mkdir_p(current.folder)
        Hive::TaskMeta.write(current.folder, id: 43, slug: current.slug, display_name: "Approval", workflow: "content")
        File.write(current.state_file, "# Idea\n<!-- COMPLETE -->\n")
      end
      task = Hive::Task.new(task.folder)
      descriptor = Hive::OperationalAction.descriptor_for_task(task, project: project.fetch("name"))
      error = assert_raises(Hive::Remote::Error) do
        service.action(project: project, task: task, action_id: descriptor.fetch("action_id"),
          observation: descriptor.fetch("observation_token"), idempotency_key: "deny-approval-effect",
          principal: PRINCIPAL, scopes: [ "act" ])
      end
      assert_equal "insufficient_scope", error.code
      assert_empty repository.pending
      assert_includes File.read(task.state_file), "COMPLETE"
    end
  end

  def test_act_and_answer_approval_executes_with_both_retained_and_composing_guards
    with_server do |service, store, repository, project, _task|
      folder = File.join(project.fetch("hive_state_path"), "stages", "1-inbox", "allowed-approval-260923-abcd")
      FileUtils.mkdir_p(folder)
      Hive::TaskMeta.write(folder, id: 43, slug: File.basename(folder), display_name: "Approval", workflow: "content")
      task = Hive::Task.new(folder)
      File.write(task.state_file, "# Idea\n<!-- COMPLETE -->\n")
      descriptor = Hive::OperationalAction.descriptor_for_task(task, project: project.fetch("name"))
      result = service.action(project: project, task: task, action_id: descriptor.fetch("action_id"),
        observation: descriptor.fetch("observation_token"), idempotency_key: "allowed-approval-effect",
        principal: PRINCIPAL, scopes: %w[act answer])
      authority = repository.fetch(result.fetch("request_id")).remote_authority
      assert_equal "approve", authority.dig("effect", "kind")
      generation = Hive::Attempts::Generation.resolve(task: task, project: project.fetch("name"), intended_stage: "1-inbox")
      context = Hive::Attempts::Context.send(:new, attempt_id: "action-approval-worker", project: project.fetch("name"),
        task_generation: generation.task_input_epoch, ownership_generation: generation.ownership_generation,
        intended_stage: "1-inbox", remote_authority: authority)
      with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) do
        executor = Hive::OperationalAction::Executor.new(remote_authority: authority)
        payload = executor.execute(action_id: descriptor.fetch("action_id"), target: descriptor.fetch("target"),
          observation_token: descriptor.fetch("observation_token"))
        assert_equal "2-research", payload.fetch("stage")
      end
      refute File.exist?(folder)
      assert_equal "succeeded", store.receipt(result.dig("command_receipt", "id")).fetch(:state)
    end
  end

  def test_refused_retry_records_failure_without_dispatch
    with_server do |service, store, repository, project, task|
      File.write(task.state_file, "# Brainstorm\n<!-- ERROR reason=timeout marker_id=retry-marker -->\n")
      descriptor = Hive::OperationalAction.descriptor_for_task(task, project: project.fetch("name"))
      refused = Struct.new(:to_h).new({ "state" => "safety_blocked", "request_id" => nil })
      with_replaced_singleton_method(Hive::Recovery::API, :recover!, ->(**) { refused }) do
        [ Hive::Remote::AdmissionRefused, Hive::CommandReplayFailure ].each do |error_class|
          assert_raises(error_class) do
            service.action(project: project, task: task, action_id: descriptor.fetch("action_id"),
              observation: descriptor.fetch("observation_token"), idempotency_key: "refused-retry",
              principal: PRINCIPAL, scopes: [ "act" ])
          end
        end
      end
      assert_empty repository.pending
      receipt = repository.database.read { |db| db[:command_receipts].where(command: "act").first }
      assert_equal "failed", receipt.fetch(:state)
      require "hive/remote/operation_projection"
      result = Hive::Remote::OperationProjection.new(store: store).call(project: project,
        id: receipt.fetch(:receipt_id), principal: PRINCIPAL, scopes: [ "act" ])
      assert_equal "failed", result.fetch("state")
    end
  end

  def test_workflow_identifiers_reject_paths_before_lookup
    with_server do |service, _store, _repository, project, _task|
      [ "../config", "/tmp/config", "coding/../../config", "..", "coding.yml" ].each do |workflow|
        assert_raises(Hive::UsageError) do
          service.create(project: project, text: "unsafe workflow", workflow: workflow,
            idempotency_key: "workflow-path", principal: PRINCIPAL, scopes: [ "create" ])
        end
      end
    end
  end

  private

  def queue_approval(service, project, task, key:)
    service.approve(project: project, task: task, stage: "2-brainstorm",
      generation: Hive::WorkflowAdmission.generation_for(task, project: project.fetch("name")),
      idempotency_key: key, principal: PRINCIPAL, scopes: [ "answer" ])
  end

  def worker_record(project, task, result)
    { "request_id" => result.fetch("request_id"), "project" => project.fetch("name"),
      "task_id" => task.id, "task_slug" => task.slug }
  end

  def daemon_for(repository)
    daemon = Hive::Daemon::Dispatcher.allocate
    daemon.instance_variable_set(:@dispatch_repository, repository)
    daemon.instance_variable_set(:@dispatch_state_home, Hive::Paths.state_home)
    logger = Object.new
    logger.define_singleton_method(:event) { |*| }
    daemon.instance_variable_set(:@logger, logger)
    daemon
  end

  def store_pin(repository, result)
    repository.database.read do |db|
      db[:command_receipt_pins][receipt_id: result.dig("command_receipt", "id")]
    end
  end

  def await_attempt(attempt_id)
    attempts = Hive::Attempts::Repository.open_default
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
    loop do
      record = attempts.fetch(attempt_id)
      return record if record.final?
      flunk "detached work did not finish" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
  end

  def with_server
    with_tmp_global_config do
      with_tmp_git_repo do |root|
        capture_io { Hive::Commands::Init.new(root).call }
        project = Hive::Config.registered_projects.find { |row| row.fetch("path") == root }
        config_path = File.join(project.fetch("hive_state_path"), "config.yml")
        config = YAML.safe_load(File.read(config_path))
        config["command_receipts"] = { "keyed_intake_enabled" => true }
        File.write(config_path, config.to_yaml)
        database = Hive::RuntimeControlPlane.database.open!
        Hive::RuntimeControlPlane::CommandSchemaInstallation.install!(database: database, package_coordinates: PACKAGE)
        store = Hive::CommandReceiptStore.new(database: database)
        repository = Hive::RuntimeControlPlane::DispatchRepository.new(database: database)
        folder = File.join(project.fetch("hive_state_path"), "stages", "2-brainstorm", "remote-task-260923-abcd")
        FileUtils.mkdir_p(folder)
        Hive::TaskMeta.write(folder, id: 42, slug: "remote-task-260923-abcd", display_name: "Remote task", workflow: "coding")
        File.write(File.join(folder, "brainstorm.md"), "# Brainstorm\n<!-- COMPLETE -->\n")
        service = Hive::Remote::CommandService.new(store: store, repository: repository)
        yield service, store, repository, project, Hive::Task.new(folder)
      end
    end
  end
end
