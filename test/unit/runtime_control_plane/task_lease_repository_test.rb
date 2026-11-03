require "test_helper"
require "hive/runtime_control_plane/task_lease_repository"

class CaptureTaskLeaseRepositoryTest < Minitest::Test
  include HiveTestHelper

  def with_capture
    with_tmp_dir do |root|
      prepare_test_runtime_project(root)
      database = Hive::Lock.task_lease_repository.database
      folder = File.join(root, ".hive-state/stages/1-inbox/capture-task")
      id = Hive::TaskCounter.next_or_nil
      Hive::TaskMeta.write(folder, id: id, slug: "capture-task", display_name: nil)
      observation = Hive::TaskMeta.observe(folder)
      repository = Hive::Lock.task_lease_repository
      yield repository, folder, observation, database, id.to_s
    ensure
      observation&.close
    end
  end

  def test_never_dispatched_released_registration_can_be_rolled_back_exactly_once
    with_capture do |repository, folder, observation, database, id|
      ticket = repository.prepare_capture_rollback(folder, observation: observation)
      Hive::Lock.with_task_lock(folder) { assert Hive::Lock.read_task_lock(folder) }
      assert repository.discard_uncommitted_capture!(ticket)
      assert_nil database.read { |db| db[:task_subjects].where(task_id: id).first }
      assert_nil database.read { |db| db[:task_leases].where(task_id: id).first }
      assert_raises(Hive::RuntimeControlPlane::IdentityError) { repository.discard_uncommitted_capture!(ticket) }
    end
  end

  def test_preexisting_or_held_subject_is_never_deleted
    with_capture do |repository, folder, observation, database, id|
      ticket = repository.prepare_capture_rollback(folder, observation: observation)
      Hive::Lock.with_task_lock(folder) do
        assert_raises(Hive::RuntimeControlPlane::IdentityError) { repository.discard_uncommitted_capture!(ticket) }
        assert database.read { |db| db[:task_subjects].where(task_id: id).first }
      end
      assert_raises(Hive::RuntimeControlPlane::IdentityError) { repository.prepare_capture_rollback(folder, observation: observation) }
      assert repository.discard_uncommitted_capture!(ticket)
    end
  end

  def test_referenced_or_changed_subject_and_same_path_replacement_are_preserved
    with_capture do |repository, folder, observation, database, id|
      ticket = repository.prepare_capture_rollback(folder, observation: observation)
      Hive::Lock.with_task_lock(folder) { true }
      database.transaction do |db|
        db[:payload_references].insert(payload_id: "reference", task_id: id, kind: "capture", relative_path: "state.json", state: "open", created_at: Time.now.utc.iso8601)
      end
      assert_raises(Hive::RuntimeControlPlane::IdentityError) { repository.discard_uncommitted_capture!(ticket) }
      assert database.read { |db| db[:payload_references].where(task_id: id).first }
      database.transaction do |db|
        db[:payload_references].where(task_id: id).delete
        db[:task_subjects].where(task_id: id).update(generation: 1)
      end
      assert_raises(Hive::RuntimeControlPlane::IdentityError) { repository.discard_uncommitted_capture!(ticket) }
      File.rename(folder, "#{folder}-old")
      FileUtils.cp_r("#{folder}-old", folder)
      assert_raises(Hive::TaskMeta::StaleTask) { repository.discard_uncommitted_capture!(ticket) }
      assert database.read { |db| db[:task_subjects].where(task_id: id).first }
    end
  end

  def test_failure_before_registration_and_successful_capture_retire_only_the_ticket
    with_capture do |repository, folder, observation, _database, _id|
      ticket = repository.prepare_capture_rollback(folder, observation: observation)
      assert repository.discard_uncommitted_capture!(ticket)
      ticket = repository.prepare_capture_rollback(folder, observation: observation)
      assert repository.finish_capture_rollback(ticket)
      assert_raises(Hive::RuntimeControlPlane::IdentityError) { repository.discard_uncommitted_capture!(ticket) }
    end
  end
end

class CaptureTaskLeaseRepositoryTest
  def test_unregistered_capture_identity_cannot_mint_a_rollback_ticket
    with_capture do |repository, folder, observation, _database, _id|
      Hive::TaskMeta.rewrite(folder, id: nil)
      fresh = Hive::TaskMeta.observe(folder)
      assert_raises(Hive::RuntimeControlPlane::IdentityError) { repository.prepare_capture_rollback(folder, observation: fresh) }
    ensure
      fresh&.close
    end
  end
end
