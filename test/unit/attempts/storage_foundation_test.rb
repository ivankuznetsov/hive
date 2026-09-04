require "test_helper"
require "hive/attempts/repository"

class AttemptsStorageFoundationTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 8, 10, 12)
  CLAIM_CAPABILITY = "c" * 64

  def test_final_attempt_remains_in_the_attempt_table_without_a_proof_store
    with_repository do |repository|
      terminal = terminal_attempt(repository)
      assert_equal 1, repository.database.read { |db| db[:attempts].count }
      assert_equal terminal.to_h, repository.fetch(terminal.attempt_id).to_h
      assert_equal terminal.attempt_id,
                   repository.successful_attempt_id(
                     task_generation: terminal.task_generation, subject: terminal.subject
                   )
      refute_respond_to repository, :permanent_proofs
      refute_respond_to repository, :decision_index
    end
  end

  def test_terminal_pending_receipt_digest_and_consumer_acknowledgements_survive_restart
    with_tmp_dir do |root|
      repository = Hive::Attempts::Repository.new(root: root, migrate: true)
      terminal = terminal_attempt(repository)
      receipt_json = Hive::RuntimeControlPlane::Codec.dump_json(terminal.receipt)
      pending = repository.database.read do |db|
        db[:terminal_pending_publications].where(attempt_id: terminal.attempt_id).first
      end
      assert_equal Digest::SHA256.hexdigest(receipt_json), pending.fetch(:expected_receipt_digest)

      repository.prepare_publication(
        attempt_id: terminal.attempt_id, consumers: %w[journal provider_health]
      )
      repository.acknowledge_publication(terminal.attempt_id, consumer: "journal")
      restarted = Hive::Attempts::Repository.new(root: root, migrate: true)
      refute restarted.publication_complete?(terminal.attempt_id)
      restarted.acknowledge_publication(terminal.attempt_id, consumer: "provider_health")
      assert restarted.publication_complete?(terminal.attempt_id)
      assert restarted.finish_publication(terminal.attempt_id)
      assert_nil restarted.publication(terminal.attempt_id)
    end
  end

  def test_publication_rejects_conflicting_or_unknown_consumers
    with_repository do |repository|
      terminal = terminal_attempt(repository)
      repository.prepare_publication(attempt_id: terminal.attempt_id, consumers: %w[journal])

      assert_raises(Hive::Attempts::RepositoryError) do
        repository.prepare_publication(
          attempt_id: terminal.attempt_id, consumers: %w[journal provider_health]
        )
      end
      assert_raises(Hive::Attempts::RepositoryError) do
        repository.acknowledge_publication(terminal.attempt_id, consumer: "unknown")
      end
      assert_raises(Hive::Attempts::RepositoryError) do
        repository.finish_publication(terminal.attempt_id)
      end
    end
  end

  def test_open_payload_bytes_use_the_nonretired_root_and_seal_by_digest
    with_repository do |repository|
      path = repository.payload_store.write_open(
        attempt_id: "attempt-1", name: "result.bin", bytes: "payload"
      )
      assert path.start_with?(File.join(repository.root, "open"))
      reference = repository.payload_store.seal(path)

      assert_equal "payload", repository.payload_store.read_sealed(reference)
      assert_equal Digest::SHA256.hexdigest("payload"), reference.fetch("sha256")
      assert reference.fetch("path").start_with?("sealed/")
    end
  end

  def test_output_paths_reject_traversal_and_symlink_escape
    with_repository do |repository|
      assert_raises(Hive::Attempts::RepositoryError) do
        repository.output_path("attempt-1", "../escape")
      end
      directory = repository.output_directory("attempt-1", create: true)
      File.symlink("/tmp", File.join(directory, "result"))
      assert_raises(Hive::Attempts::RepositoryError) do
        repository.output_path("attempt-1", "result")
      end
    end
  end

  def test_publication_inputs_fail_closed
    with_repository do |repository|
      terminal = terminal_attempt(repository)
      assert_raises(Hive::Attempts::RepositoryError) do
        repository.seal_terminal_payloads(Object.new)
      end
      assert_raises(Hive::Attempts::RepositoryError) do
        repository.prepare_publication(attempt_id: terminal.attempt_id, consumers: [])
      end
      assert_raises(Hive::Attempts::RepositoryError) do
        repository.prepare_publication(attempt_id: terminal.attempt_id, consumers: [ "Bad Name" ])
      end
    end
  end

  def test_sealed_payload_identity_conflict_is_rejected
    with_repository do |repository|
      terminal = terminal_attempt(repository)
      reference = {
        "path" => "sealed/sha256/aa/#{'a' * 64}",
        "sha256" => "a" * 64, "size" => 1
      }
      repository.database.transaction do |db|
        db[:payload_references].insert(
          payload_id: "payload", attempt_id: terminal.attempt_id,
          kind: "attempt_log", relative_path: reference.fetch("path"),
          sha256: reference.fetch("sha256"), bytes: 1,
          state: "releasable", created_at: NOW.iso8601(6)
        )
      end
      spec = { payload_id: "payload", kind: "attempt_log", reference: reference }
      assert_raises(Hive::Attempts::RepositoryError) do
        repository.database.transaction do |db|
          repository.send(:persist_sealed_reference, db, terminal, spec)
        end
      end
    end
  end

  private

  def with_repository
    with_tmp_dir do |root|
      yield Hive::Attempts::Repository.new(root: root, migrate: true)
    end
  end

  def terminal_attempt(repository)
    launching = repository.create_launching(
      attempt_id: "attempt-1", request_id: "request-1", predecessor_attempt_id: nil,
      task_id: "42", project: "demo", task_slug: "task",
      intended_stage: "4-execute", task_generation: "generation-1",
      ownership_generation: "owner-1", task_input_epoch: 1,
      progress_token: "progress-1", provider: "codex",
      worker_argv: [ "hive", "run", "task" ],
      claim_capability_digest: Hive::Attempts::Capability.digest(CLAIM_CAPABILITY),
      starting_revision: nil, retry_charge: 0, inherited_outputs: [],
      launch_timeout_sec: 30, now: NOW
    )
    claimed = repository.claim(
      launching, owner: owner, claim_capability: CLAIM_CAPABILITY,
      first_heartbeat_timeout_sec: 30, now: NOW + 1
    )
    running = repository.first_heartbeat(claimed, stale_sec: 30, now: NOW + 2)
    repository.terminalize(
      running, outcome: "succeeded", exit_status: 0,
      final_checkpoint: { "revision" => "a" * 40 }, output_references: [],
      log_reference: { "path" => "open/attempt-1.frames", "size" => 0, "sha256" => "0" * 64 },
      now: NOW + 3
    )
  end

  def owner
    {
      "pid" => Process.pid, "start_fingerprint" => "pid-start",
      "session_id" => Process.getsid(0), "process_group_id" => Process.getpgrp
    }
  end
end
