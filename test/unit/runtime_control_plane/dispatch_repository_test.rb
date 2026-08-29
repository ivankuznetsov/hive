require "test_helper"
require "hive/runtime_control_plane/dispatch_repository"

class RuntimeControlPlaneDispatchRepositoryTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 8, 29, 12)

  def test_request_claim_sequence_and_outbox_are_transactional_and_idempotent
    with_repository do |repository|
      id = repository.write_request!(
        project: "hive", slug: "sqlite-cutover", argv: %w[hive run sqlite-cutover],
        request_id: "request-1", task_generation: "generation-1", now: NOW
      )
      assert_equal "request-1", id
      assert_equal id, repository.write_request!(
        project: "hive", slug: "sqlite-cutover", argv: %w[hive run sqlite-cutover],
        request_id: id, task_generation: "generation-1", now: NOW
      )
      assert_equal [ id ], repository.pending.map(&:request_id)

      assert_equal id, repository.claim(id, pid: 123, process_start_time: "start", now: NOW)
      assert_nil repository.claim(id, pid: 456, now: NOW)
      delivery = repository.claimed.fetch(0)
      assert_equal 123, delivery.claim.fetch("pid")

      assert repository.release_claim(id)
      assert repository.write_sequence!(id, remaining_argvs: [ %w[hive review sqlite-cutover] ])
      promoted = repository.promote_sequence(
        id, project: "hive", slug: "sqlite-cutover", now: NOW + 1
      )
      assert_equal %w[hive review sqlite-cutover], promoted.argv

      repository.claim(id, pid: 123, now: NOW)
      repository.database.transaction do |db|
        db[:dispatch_requests].where(request_id: id).update(state: "admitted")
      end
      result_id = repository.write_result!(
        chat_id: 42, project: "hive", slug: "sqlite-cutover",
        request_id: id, exit_code: 0, command: "hive run sqlite-cutover", now: NOW
      )
      assert_equal result_id, repository.write_result!(
        chat_id: 42, project: "hive", slug: "sqlite-cutover",
        request_id: id, exit_code: 0, command: "hive run sqlite-cutover", now: NOW
      )
      assert_equal [ result_id ], repository.pending_results.map(&:result_id)
      assert repository.remove_result(result_id)
      assert_empty repository.pending_results
    end
  end

  def test_corrupt_payload_fails_closed_without_filesystem_fallback
    with_repository do |repository|
      repository.write_request!(
        project: "hive", slug: "sqlite-cutover", argv: %w[hive run sqlite-cutover],
        request_id: "request-2", now: NOW
      )
      repository.database.transaction do |db|
        db[:dispatch_requests].where(request_id: "request-2").update(payload_json: "{")
      end

      assert_raises(Hive::RuntimeControlPlane::IntegrityError) { repository.pending }
    end
  end

  def test_active_subject_conflict_does_not_report_a_different_request_as_written
    with_repository do |repository|
      register_task(repository.database, task_id: "task-1")
      attributes = {
        project: "hive", slug: "sqlite-cutover", argv: %w[hive run sqlite-cutover],
        task_id: "task-1", task_generation: "generation-1", now: NOW
      }
      assert_equal "request-1", repository.write_request!(**attributes, request_id: "request-1")

      error = assert_raises(Hive::RuntimeControlPlane::IntegrityError) do
        repository.write_request!(**attributes, request_id: "request-2")
      end
      assert_match(/already queued as request-1/, error.message)
      assert_nil repository.fetch("request-2")
      assert_equal [ "request-1" ], repository.pending.map(&:request_id)
    end
  end

  private

  def with_repository
    with_tmp_dir do |root|
      database = Hive::RuntimeControlPlane::Database.new(path: File.join(root, "runtime.sqlite3"))
      database.migrate!
      timestamp = NOW.iso8601(6)
      database.transaction do |db|
        installation = db[:installations].first.fetch(:installation_id)
        db[:projects].insert(
          project_id: "project-1", installation_id: installation,
          registration_id: "registration-1", name: "hive", observed_path: root,
          state_root_path: File.join(root, ".hive-state"), active: 1,
          registered_at: timestamp, last_observed_at: timestamp
        )
      end
      yield Hive::RuntimeControlPlane::DispatchRepository.new(
        database: database, clock: -> { NOW }
      )
    end
  end

  def register_task(database, task_id:)
    timestamp = NOW.iso8601(6)
    database.transaction do |db|
      db[:task_subjects].insert(
        task_id: task_id, project_id: "project-1", workflow_id: "coding",
        task_slug: "sqlite-cutover", observed_path: task_id,
        source_fingerprint: "source", generation: 1,
        created_at: timestamp, last_observed_at: timestamp
      )
    end
  end
end
