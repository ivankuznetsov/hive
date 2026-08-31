require "test_helper"
require "hive/runtime_control_plane/dispatch_repository"

class RuntimeControlPlaneDispatchRepositoryTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 8, 29, 12)

  def test_only_the_evidence_rework_subcommand_is_dispatchable
    assert Hive::RuntimeControlPlane::DispatchRepository.valid_argv?(
      %w[hive evidence rework task-260831-abcd --stage 7-artifacts]
    )
    refute Hive::RuntimeControlPlane::DispatchRepository.valid_argv?(
      %w[hive evidence terminal task-260831-abcd]
    )
  end

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
      assert_nil repository.promote_sequence(
        id, project: "hive", slug: "sqlite-cutover", now: NOW + 1
      )

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

      repository.database.transaction do |db|
        db[:dispatch_requests].where(request_id: "request-1").update(state: "admitted")
      end
      error = assert_raises(Hive::RuntimeControlPlane::IntegrityError) do
        repository.write_request!(**attributes, request_id: "request-3")
      end
      assert_equal :dispatch_subject_conflict, error.code
      assert_nil repository.fetch("request-3")
    end
  end

  def test_claim_attempt_binding_is_typed_rebindable_and_cleared_on_release
    with_repository do |repository|
      id = repository.write_request!(
        project: "hive", slug: "sqlite-cutover", argv: %w[hive run sqlite-cutover],
        request_id: "request-binding", now: NOW
      )

      repository.claim(id, pid: 123, attempt_id: "attempt-1", now: NOW)
      assert_equal "attempt-1", repository.claimed.fetch(0).claim.fetch("attempt_id")

      repository.update_claim(id, pid: 456, attempt_id: "attempt-2", now: NOW + 1)
      assert_equal "attempt-2", repository.claimed.fetch(0).claim.fetch("attempt_id")

      assert repository.release_claim(id)
      row = repository.database.read do |db|
        db[:dispatch_requests].where(request_id: id).first
      end
      assert_nil row.fetch(:claim_attempt_id)
    end
  end

  def test_delivery_pending_is_an_indexed_attempt_lookup_that_does_not_decode_other_rows
    with_repository do |repository|
      %w[target unrelated].each do |suffix|
        id = repository.write_request!(
          project: "hive", slug: "#{suffix}-task", argv: [ "hive", "run", "#{suffix}-task" ],
          request_id: "request-#{suffix}", now: NOW
        )
        repository.claim(id, pid: 123, attempt_id: "attempt-#{suffix}", now: NOW)
      end
      repository.database.transaction do |db|
        db[:dispatch_requests].where(request_id: "request-unrelated").update(payload_json: "{")
      end

      assert repository.delivery_pending_for_attempt?("attempt-target")
      refute repository.delivery_pending_for_attempt?("attempt-missing")
    end
  end

  def test_terminal_recovery_leaves_active_claims_but_remains_replayable
    with_repository do |repository|
      id = repository.write_request!(
        project: "hive", slug: "sqlite-cutover", argv: %w[hive run sqlite-cutover],
        request_id: "request-recovery", recovery: { "phase" => "admitted" }, now: NOW
      )
      repository.claim(id, pid: 123, attempt_id: "attempt-1", now: NOW)

      assert repository.update_recovery!(
        id, expected_phase: "admitted", changes: { phase: "terminal" }
      )

      assert repository.complete_delivery(id, now: NOW + 1)
      assert_equal "completed", repository.fetch(id).state
      assert_empty repository.claimed
      assert_equal id, repository.recovery_requests.fetch(0).request_id
    end
  end

  def test_sequence_promotion_has_one_deterministic_winner
    with_repository do |repository|
      id = repository.write_request!(
        project: "hive", slug: "sqlite-cutover", argv: %w[hive run sqlite-cutover],
        request_id: "request-sequence", now: NOW
      )
      repository.write_sequence!(id, remaining_argvs: [ %w[hive review sqlite-cutover] ])
      gate = Queue.new
      workers = 2.times.map do
        Thread.new do
          gate.pop
          repository.promote_sequence(
            id, project: "hive", slug: "sqlite-cutover", now: NOW + 1
          )
        end
      end
      2.times { gate << true }

      results = workers.map(&:value).compact
      assert_equal 1, results.length
      assert_equal "seq-#{Digest::SHA256.hexdigest(id)[0, 32]}", results.fetch(0).request_id
      assert_equal 2, repository.database.read { |db| db[:dispatch_requests].count }
    end
  end

  def test_recovery_projection_uses_its_typed_leading_index
    with_repository do |repository|
      columns = repository.database.read do |db|
        db.fetch("PRAGMA index_info(dispatch_requests_recovery_projection_idx)")
          .all.sort_by { |row| row.fetch(:seqno) }.map { |row| row.fetch(:name) }
      end
      assert_equal %w[recovery_request updated_at request_id], columns
    end
  end

  def test_recovery_lookup_does_not_decode_unrelated_dispatch_history
    with_repository do |repository|
      repository.write_request!(
        project: "hive", slug: "other-task", argv: %w[hive run other-task],
        request_id: "unrelated", now: NOW
      )
      repository.database.transaction do |db|
        db[:dispatch_requests].where(request_id: "unrelated").update(payload_json: "{")
      end
      repository.write_request!(
        project: "hive", slug: "sqlite-cutover", argv: %w[hive run sqlite-cutover],
        request_id: "recovery", recovery: { "phase" => "admitted", "retry_count" => 3 }, now: NOW
      )

      assert_equal 3, repository.recovery_retry_count(project: "hive", slug: "sqlite-cutover")
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
