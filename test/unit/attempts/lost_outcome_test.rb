require "test_helper"
require "hive/attempts/lost_outcome"
require "hive/attempts/store"

class AttemptsLostOutcomeTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 16, 12, 0, 0)
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
      progress_token: "progress", provider: "codex", starting_revision: nil,
      retry_charge: 0, inherited_outputs: [], launch_timeout_sec: 30, now: NOW
    )
    claimed = store.claim(
      launching, owner: OWNER, first_heartbeat_timeout_sec: 30, now: NOW + 1
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
end
