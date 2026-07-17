require "test_helper"
require "hive/attempts/lost_outcome"
require "hive/attempts/store"

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

  def test_processes_loss_once_captures_worktree_and_projects_error_marker
    with_task do |task, worktree|
      File.write(File.join(worktree, "partial.txt"), "partial\n")
      with_tmp_dir do |root|
        store = Hive::Attempts::Store.new(root: root)
        lost = lost_attempt(store)
        outcomes = Hive::Attempts::LostOutcomeStore.new(store: store)
        identity = FakeIdentity.new(:terminated, [])
        processor = Hive::Attempts::LostOutcomeProcessor.new(
          store: store, outcome_store: outcomes, process_identity: identity,
          task_resolver: ->(_attempt) { task }
        )

        first = processor.process(lost, now: NOW + 3)
        version = store.fetch(lost.attempt_id).lease_version
        second = processor.process(store.fetch(lost.attempt_id), now: NOW + 4)

        assert_equal "ready", first.fetch("status")
        assert_equal first, second
        assert_equal version, store.fetch(lost.attempt_id).lease_version
        assert_equal 1, identity.calls.size
        assert first.fetch("capture_references").all? do |reference|
          Hive::Attempts::OutputReference.verify(reference, root: root)
        end
        marker = Hive::Markers.current(task.state_file)
        assert_equal :error, marker.name
        assert_equal "attempt_lost", marker.attrs.fetch("reason")
        assert_equal lost.attempt_id, marker.attrs.fetch("attempt_id")
      end
    end
  end

  def test_unverified_orphan_is_manual_and_is_never_captured
    with_task do |task, _worktree|
      with_tmp_dir do |root|
        store = Hive::Attempts::Store.new(root: root)
        lost = lost_attempt(store)
        outcomes = Hive::Attempts::LostOutcomeStore.new(store: store)
        identity = FakeIdentity.new(:identity_mismatch, [])
        processor = Hive::Attempts::LostOutcomeProcessor.new(
          store: store, outcome_store: outcomes, process_identity: identity,
          task_resolver: ->(_attempt) { task }
        )

        outcome = processor.process(lost, now: NOW + 3)

        assert_equal "manual", outcome.fetch("status")
        assert_empty outcome.fetch("capture_references")
        assert_equal 1, identity.calls.size
        assert Hive::Markers.current(task.state_file).none?
        assert_equal outcome, processor.process(lost, now: NOW + 4)
      end
    end
  end

  def test_outcome_store_rejects_corruption_identity_changes_and_write_failures
    with_tmp_dir do |root|
      store = Hive::Attempts::Store.new(root: root)
      lost = lost_without_worker(store)
      outcomes = Hive::Attempts::LostOutcomeStore.new(store: store)
      outcome = outcomes.ensure_for(lost, now: NOW)
      path = outcomes.send(:path, lost.attempt_id)

      File.write(path, "{")
      assert_raises(Hive::Attempts::StoreError) { outcomes.fetch(lost.attempt_id) }
      changed = outcome.merge("idempotency_key" => "wrong")
      File.write(path, JSON.generate(changed))
      assert_raises(Hive::Attempts::StoreError) { outcomes.update(lost, status: "ready") }

      FileUtils.rm_f(path)
      with_replaced_singleton_method(Hive::AtomicFile, :write, ->(*_args, **_kwargs) { raise Errno::ENOSPC }) do
        assert_raises(Hive::Attempts::StoreError) { outcomes.ensure_for(lost, now: NOW) }
      end
    end
  end

  def test_workerless_loss_without_a_worktree_becomes_ready
    with_tmp_dir do |root|
      store = Hive::Attempts::Store.new(root: root)
      lost = lost_without_worker(store)
      outcomes = Hive::Attempts::LostOutcomeStore.new(store: store)
      processor = Hive::Attempts::LostOutcomeProcessor.new(
        store: store, outcome_store: outcomes,
        process_identity: FakeIdentity.new(:absent, []), task_resolver: ->(_attempt) { nil }
      )

      outcome = processor.process(lost, now: NOW + 1)
      assert_equal "ready", outcome.fetch("status")
      assert_equal "no_worker", outcome.fetch("cleanup")
      assert_empty outcome.fetch("capture_references")
    end
  end

  def test_competing_annotation_and_marker_projection_failures_are_idempotent
    with_tmp_dir do |root|
      store = Hive::Attempts::Store.new(root: root)
      lost = lost_without_worker(store)
      outcomes = Hive::Attempts::LostOutcomeStore.new(store: store)
      processor = Hive::Attempts::LostOutcomeProcessor.new(
        store: store, outcome_store: outcomes,
        process_identity: FakeIdentity.new(:absent, []), task_resolver: ->(_attempt) { nil }
      )
      store.define_singleton_method(:annotate_lost) do |*_args, **_kwargs|
        raise Hive::Attempts::CompareAndSwapFailed
      end
      pending = processor.process(lost, now: NOW + 1)
      assert_equal "pending", pending.fetch("status")

      task = Struct.new(:state_file).new("/unwritable/task.md")
      with_replaced_singleton_method(Hive::Markers, :set, ->(*_args, **_kwargs) { raise Errno::EACCES }) do
        assert_nil processor.send(:project_marker, task, lost)
      end
    end
  end

  def test_default_task_resolution_uses_id_and_contains_lookup_errors
    with_tmp_dir do |root|
      store = Hive::Attempts::Store.new(root: root)
      lost = lost_without_worker(store)
      outcomes = Hive::Attempts::LostOutcomeStore.new(store: store)
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
      attempt_id: "lost-1", request_id: "request-1", predecessor_attempt_id: nil,
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
      attempt_id: "lost-no-worker", request_id: "request-no-worker", predecessor_attempt_id: nil,
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
