require "test_helper"
require "hive/attempts/lost_outcome"
require "hive/attempts/repository"

class AttemptsLostOutcomeTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 16, 12, 0, 0)
  CLAIM_CAPABILITY = "c" * 64
  OWNER = {
    "pid" => 123, "start_fingerprint" => "wrapper-start",
    "session_id" => 123, "process_group_id" => 123
  }.freeze

  FakeIdentity = Struct.new(:result, :calls) do
    def terminate_orphan_group(**args)
      calls << args
      result
    end
  end

  def test_processes_loss_once_and_captures_worktree_without_projecting_a_marker
    with_task do |task, worktree|
      File.write(File.join(worktree, "partial.txt"), "partial\n")
      with_tmp_dir do |root|
        store = Hive::Attempts::Repository.new(root: root, migrate: true)
        lost = lost_attempt(store)
        outcomes = Hive::Attempts::LostOutcomeTransition.new(store: store)
        identity = FakeIdentity.new(:terminated, [])
        processor = Hive::Attempts::LostOutcomeProcessor.new(
          store: store, outcome_store: outcomes, process_identity: identity,
          task_resolver: ->(_attempt) { task }
        )

        first = processor.process(lost, now: NOW + 3)
        version = store.fetch(lost.attempt_id).lease_version
        second = processor.process(store.fetch(lost.attempt_id), now: NOW + 4)

        assert_equal "ready", first.fetch("phase")
        assert_equal first, second
        assert_equal version, store.fetch(lost.attempt_id).lease_version
        assert_equal 1, identity.calls.size
        assert first.fetch("capture_references").all? do |reference|
          Hive::OutputReference.verify(reference, root: root)
        end
        assert Hive::Markers.current(task.state_file).none?,
               "the attempt ledger owns loss recovery; it must not create a second marker lifecycle"
      end
    end
  end

  def test_unverified_orphan_remains_pending_until_identity_becomes_safe
    with_task do |task, _worktree|
      with_tmp_dir do |root|
        store = Hive::Attempts::Repository.new(root: root, migrate: true)
        lost = lost_attempt(store)
        outcomes = Hive::Attempts::LostOutcomeTransition.new(store: store)
        identity = FakeIdentity.new(:identity_mismatch, [])
        processor = Hive::Attempts::LostOutcomeProcessor.new(
          store: store, outcome_store: outcomes, process_identity: identity,
          task_resolver: ->(_attempt) { task }
        )

        pending = processor.process(lost, now: NOW + 3)
        pending_again = processor.process(lost, now: NOW + 3.5)

        assert_equal "pending", pending.fetch("phase")
        assert_equal pending, pending_again,
                     "an unchanged unsafe identity must wait for the shared cleanup cooldown"
        assert_empty pending.fetch("capture_references")
        assert_equal 1, identity.calls.size
        assert Hive::Markers.current(task.state_file).none?

        identity.result = :absent
        still_pending = processor.process(
          lost, now: NOW + Hive::AgentLimit.retry_cooldown_sec
        )
        ready = processor.process(
          lost, now: NOW + Hive::AgentLimit.retry_cooldown_sec + 4
        )

        assert_equal "pending", still_pending.fetch("phase")
        assert_equal "ready", ready.fetch("phase")
        assert_equal 2, identity.calls.size
      end
    end
  end

  def test_transition_rejects_corrupt_or_identity_mismatched_rows
    with_tmp_dir do |root|
      store = Hive::Attempts::Repository.new(root: root, migrate: true)
      lost = lost_without_worker(store)
      outcomes = Hive::Attempts::LostOutcomeTransition.new(store: store)
      outcomes.ensure_for(lost, now: NOW)
      store.database.transaction do |db|
        db[:attempts].where(attempt_id: lost.attempt_id).update(record_digest: "0" * 64)
      end
      assert_raises(Hive::Attempts::RepositoryError) { outcomes.fetch(lost.attempt_id) }
    end
  end

  def test_workerless_loss_without_a_worktree_becomes_ready
    with_tmp_dir do |root|
      store = Hive::Attempts::Repository.new(root: root, migrate: true)
      lost = lost_without_worker(store)
      outcomes = Hive::Attempts::LostOutcomeTransition.new(store: store)
      processor = Hive::Attempts::LostOutcomeProcessor.new(
        store: store, outcome_store: outcomes,
        process_identity: FakeIdentity.new(:absent, []), task_resolver: ->(_attempt) { nil }
      )

      outcome = processor.process(lost, now: NOW + 1)
      assert_equal "ready", outcome.fetch("phase")
      assert_equal "no_worker", outcome.fetch("cleanup")
      assert_empty outcome.fetch("capture_references")
    end
  end

  def test_competing_annotation_is_idempotent
    with_tmp_dir do |root|
      store = Hive::Attempts::Repository.new(root: root, migrate: true)
      lost = lost_without_worker(store)
      outcomes = Hive::Attempts::LostOutcomeTransition.new(store: store)
      processor = Hive::Attempts::LostOutcomeProcessor.new(
        store: store, outcome_store: outcomes,
        process_identity: FakeIdentity.new(:absent, []), task_resolver: ->(_attempt) { nil }
      )
      first = processor.process(lost, now: NOW + 1)
      second = processor.process(store.fetch(lost.attempt_id), now: NOW + 2)
      assert_equal "ready", first.fetch("phase")
      assert_equal first, second
      assert_equal 1, first.fetch("revision")
    end
  end

  def test_default_task_resolution_uses_id_and_contains_lookup_errors
    with_tmp_dir do |root|
      store = Hive::Attempts::Repository.new(root: root, migrate: true)
      lost = lost_without_worker(store)
      outcomes = Hive::Attempts::LostOutcomeTransition.new(store: store)
      processor = Hive::Attempts::LostOutcomeProcessor.new(
        store: store, outcome_store: outcomes, process_identity: FakeIdentity.new(:absent, [])
      )
      resolved = Object.new
      resolver = Struct.new(:result) { def resolve = result }.new(resolved)
      captured = nil
      with_replaced_singleton_method(Hive::TaskResolver, :new, lambda { |target, **kwargs|
        captured = [ target, kwargs ]
        resolver
      }) do
        assert_equal resolved, processor.send(:resolve_task, lost)
      end
      assert_equal [ "42", { project_filter: "demo" } ], captured

      with_replaced_singleton_method(Hive::TaskResolver, :new, ->(*_args, **_kwargs) { raise Hive::InvalidTaskPath }) do
        assert_nil processor.send(:resolve_task, lost)
      end
    end
  end

  def test_transition_persistence_and_attempt_identity_errors_are_typed
    with_tmp_dir do |root|
      store = Hive::Attempts::Repository.new(root: root, migrate: true)
      lost = lost_without_worker(store)
      outcomes = Hive::Attempts::LostOutcomeTransition.new(store: store)
      outcomes.ensure_for(lost, now: NOW)
      assert_raises(Hive::Attempts::RepositoryError) do
        outcomes.update(lost, phase: "ready", request_id: "not-deterministic")
      end

      store.database.define_singleton_method(:transaction) do |**|
        raise Hive::RuntimeControlPlane::IntegrityError.new("bad", code: :database_corrupt)
      end
      assert_raises(Hive::Attempts::RepositoryError) do
        outcomes.ensure_for(lost, now: NOW)
      end
      assert_raises(Hive::Attempts::RepositoryError) do
        outcomes.update(lost, status: "ready")
      end
    end
  end

  private

  def with_task
    with_tmp_git_repo do |project_root|
      folder = File.join(project_root, ".hive-state", "stages", "4-execute", "durable-task")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "meta.yml"), { "id" => 42 }.to_yaml)
      File.write(File.join(folder, "worktree.yml"), { "path" => project_root }.to_yaml)
      task = Hive::Task.new(folder)
      yield task, project_root
    end
  end

  def lost_attempt(store)
    launching = store.create_launching(
      attempt_id: "lost-1", request_id: "request-1",
      task_id: "42", project: "demo", task_slug: "durable-task",
      intended_stage: "4-execute", task_generation: "generation-1",
      progress_token: "progress", provider: "codex",
      worker_argv: [ "hive", "run", "durable-task" ],
      claim_capability_digest: Hive::Attempts::Capability.digest(CLAIM_CAPABILITY), starting_revision: nil,
      retry_charge: 0, inherited_outputs: [], launch_timeout_sec: 30, now: NOW
    )
    claimed = store.claim(
      launching, owner: OWNER, claim_capability: CLAIM_CAPABILITY,
      first_heartbeat_timeout_sec: 30, now: NOW + 1
    )
    running = store.first_heartbeat(claimed, stale_sec: 30, now: NOW + 2)
    with_worker = store.checkpoint(
      running, checkpoint: running.checkpoint, now: NOW + 2,
      worker: OWNER.merge(
        "pid" => 456, "start_fingerprint" => "worker-start",
        "process_group_id" => 456
      )
    )
    store.mark_lost(with_worker, reason: "owner_gone", now: NOW + 3)
  end

  def lost_without_worker(store)
    launching = store.create_launching(
      attempt_id: "lost-no-worker", request_id: "request-no-worker",
      task_id: "42", project: "demo", task_slug: "durable-task",
      intended_stage: "4-execute", task_generation: "generation-no-worker",
      progress_token: "progress", provider: "codex",
      worker_argv: [ "hive", "run", "durable-task" ],
      claim_capability_digest: Hive::Attempts::Capability.digest(CLAIM_CAPABILITY), starting_revision: nil,
      retry_charge: 0, inherited_outputs: [], launch_timeout_sec: 30, now: NOW
    )
    store.mark_lost(launching, reason: "launch_timeout", now: NOW + 31)
  end
end
