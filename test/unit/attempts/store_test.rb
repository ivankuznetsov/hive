require "test_helper"
require "hive/attempts/capacity_snapshot"
require "hive/attempts/repository"

class AttemptsRepositoryTest < Minitest::Test
  include HiveTestHelper

  class GuardedDataset
    TERMINALS = %i[all any? count delete each first get insert select_map update].freeze

    def initialize(dataset, active)
      @dataset = dataset
      @active = active
    end

    def method_missing(name, *arguments, **keywords, &block)
      raise "dataset executed outside Database#read" if TERMINALS.include?(name) && !@active.call

      result = @dataset.public_send(name, *arguments, **keywords, &block)
      result.is_a?(Sequel::Dataset) ? self.class.new(result, @active) : result
    end

    def respond_to_missing?(name, include_private = false) =
      @dataset.respond_to?(name, include_private) || super
  end

  GuardedDatabase = Data.define(:connection, :active) do
    def [](table) = GuardedDataset.new(connection[table], active)
  end

  NOW = Time.utc(2026, 7, 16, 12)
  CLAIM_CAPABILITY = "c" * 64

  def test_public_record_lifecycle_and_terminal_publication_survive_restart
    with_tmp_dir do |root|
      repository = Hive::Attempts::Repository.new(root: root, migrate: true)
      launching = repository.create_launching(**identity, launch_timeout_sec: 30, now: NOW)
      claimed = repository.claim(
        launching, owner: owner, claim_capability: CLAIM_CAPABILITY,
        first_heartbeat_timeout_sec: 30, now: NOW + 1
      )
      running = repository.first_heartbeat(claimed, stale_sec: 30, now: NOW + 2)
      checkpointed = repository.checkpoint(
        running, checkpoint: checkpoint, now: NOW + 3
      )
      terminal = repository.terminalize(
        checkpointed, outcome: "succeeded", exit_status: 0,
        final_checkpoint: checkpoint, output_references: [ output_reference ],
        log_reference: log_reference, now: NOW + 4
      )

      assert_equal [ 0, 1, 2, 3, 4 ],
                   [ launching, claimed, running, checkpointed, terminal ].map(&:lease_version)
      assert_equal terminal.to_h, repository.fetch(terminal.attempt_id).to_h
      assert_equal terminal.attempt_id,
                   repository.terminal_attempt_id(request_id: terminal["request_id"])
      assert repository.publication(terminal.attempt_id).nil?
      repository.prepare_publication(attempt_id: terminal.attempt_id, consumers: %w[journal])
      repository.acknowledge_publication(terminal.attempt_id, consumer: "journal")

      restarted = Hive::Attempts::Repository.new(root: root, migrate: true)
      assert_equal terminal.to_h, restarted.fetch(terminal.attempt_id).to_h
      assert restarted.publication_complete?(terminal.attempt_id)
      assert restarted.finish_publication(terminal.attempt_id)
      assert_nil restarted.fetch_hot(terminal.attempt_id)
      assert_equal terminal.to_h, restarted.fetch(terminal.attempt_id).to_h
    end
  end

  def test_coordination_queries_execute_before_the_process_guard_checkout_ends
    with_repository do |repository|
      launching = repository.create_launching(**identity, launch_timeout_sec: 30, now: NOW)
      claimed = repository.claim(
        launching, owner: owner, claim_capability: CLAIM_CAPABILITY,
        first_heartbeat_timeout_sec: 30, now: NOW + 1
      )
      running = repository.first_heartbeat(claimed, stale_sec: 30, now: NOW + 2)
      terminal = repository.terminalize(
        running,
        outcome: "succeeded", exit_status: 0, final_checkpoint: checkpoint,
        output_references: [ output_reference ], log_reference: log_reference, now: NOW + 3
      )
      database = repository.database
      original_read = database.method(:read)
      active = false
      database.define_singleton_method(:read) do |&block|
        original_read.call do |connection|
          active = true
          block.call(GuardedDatabase.new(connection, -> { active }))
        ensure
          active = false
        end
      end

      assert_equal terminal.attempt_id,
                   repository.terminal_attempt_id(request_id: terminal["request_id"])
      assert_equal terminal.attempt_id,
                   repository.successful_attempt_id(
                     task_generation: terminal.task_generation, subject: terminal.subject
                   )
    end
  end

  def test_conditional_lifecycle_updates_reject_stale_observations
    with_repository do |repository|
      launching = repository.create_launching(**identity, launch_timeout_sec: 30, now: NOW)
      stale = launching.with("lease_version" => 99)

      assert_raises(Hive::Attempts::CompareAndSwapFailed) do
        repository.claim(
          stale, owner: owner, claim_capability: CLAIM_CAPABILITY,
          first_heartbeat_timeout_sec: 30, now: NOW + 1
        )
      end
      assert_equal launching.to_h, repository.fetch(launching.attempt_id).to_h
    end
  end

  def test_unique_index_allows_only_one_live_attempt_for_a_subject_generation
    with_repository do |repository|
      gate = Queue.new
      results = 6.times.map do |index|
        Thread.new do
          gate.pop
          repository.create_launching(
            **identity(attempt_id: "attempt-#{index}", request_id: "request-#{index}"),
            launch_timeout_sec: 30, now: NOW
          )
        rescue Hive::Attempts::RepositoryError => error
          error
        end
      end
      6.times { gate << true }

      values = results.map(&:value)
      assert_equal 1, values.count { |value| value.is_a?(Hive::Attempts::Record) }
      assert_equal 5, values.count { |value| value.is_a?(Hive::Attempts::RepositoryError) }
      assert_equal 1, repository.scan.records.length
    end
  end

  def test_immediate_transaction_does_not_over_reserve_the_final_global_slot
    with_repository do |repository|
      limits = { max_global: 1, max_per_project: 2, max_daily: 10 }
      gate = Queue.new
      results = 2.times.map do |index|
        Thread.new do
          gate.pop
          repository.create_launching(
            **identity(
              attempt_id: "attempt-#{index}", request_id: "request-#{index}",
              task_slug: "task-#{index}", task_id: (index + 1).to_s,
              task_generation: "generation-#{index}"
            ),
            limits: limits, launch_timeout_sec: 30, now: NOW
          )
        rescue Hive::Attempts::CapacityExceeded => error
          error
        end
      end
      2.times { gate << true }

      values = results.map(&:value)
      assert_equal 1, values.count { |value| value.is_a?(Hive::Attempts::Record) }
      assert_equal 1, values.count { |value| value.is_a?(Hive::Attempts::CapacityExceeded) }
      assert_equal 1, Hive::Attempts::CapacitySnapshot.build(store: repository, now: NOW).global_count
    end
  end

  def test_malformed_database_record_fails_the_authoritative_scan_closed
    with_repository do |repository|
      record = repository.create_launching(**identity, launch_timeout_sec: 30, now: NOW)
      repository.database.transaction do |db|
        db[:attempts].where(attempt_id: record.attempt_id).update(record_json: "{")
      end

      error = assert_raises(Hive::Attempts::RepositoryError) { repository.scan }
      assert_match(/record digest is invalid/, error.message)
    end
  end

  def test_source_fingerprint_and_record_digest_are_bound_to_the_row
    with_repository do |repository|
      record = repository.create_launching(
        **identity, source_fingerprint: "source-v1", launch_timeout_sec: 30, now: NOW
      )
      row = repository.database.read do |db|
        db[:attempts].where(attempt_id: record.attempt_id).first
      end

      assert_equal "source-v1", row.fetch(:source_fingerprint)
      assert_equal Digest::SHA256.hexdigest(row.fetch(:record_json)), row.fetch(:record_digest)
      assert_equal record.subject, Hive::RuntimeControlPlane::Codec.load_json(row.fetch(:subject_json))
      binding = repository.fetch_projection_binding(record.attempt_id)
      assert_equal record["task_id"], binding.fetch("task_id")
      assert_equal record["task_slug"], binding.fetch("task_slug")
      assert_equal record["intended_stage"], binding.fetch("intended_stage")
      assert_equal record.task_input_epoch, binding.fetch("task_input_epoch")
      assert_equal record.ownership_generation, binding.fetch("ownership_generation")
    end
  end

  def test_missing_database_never_creates_payload_state_or_honors_legacy_root_override
    with_tmp_dir do |root|
      state_home = File.join(root, "state")
      payload_root = Hive::Paths.runtime_payload_root(state_home)
      legacy_root = File.join(root, "legacy-attempts")
      FileUtils.mkdir_p(legacy_root)

      with_env("HIVE_ATTEMPT_STORE_ROOT" => legacy_root) do
        assert_raises(Hive::Attempts::RepositoryError) do
          Hive::Attempts::Repository.runtime(state_home: state_home)
        end
      end

      refute_path_exists payload_root
      refute_path_exists File.join(legacy_root, ".runtime-control-plane.sqlite3")
    end
  end

  def test_lost_transition_releases_capacity_once_in_the_same_transaction
    with_repository do |repository|
      launching = repository.create_launching(**identity, launch_timeout_sec: 30, now: NOW)
      lost = repository.mark_lost(launching, reason: "stale_generation", now: NOW + 1)

      reservation, request = repository.database.read do |db|
        [
          db[:capacity_reservations].where(attempt_id: lost.attempt_id).first,
          db[:dispatch_requests].where(request_id: lost["request_id"]).first
        ]
      end
      assert_equal "released", reservation.fetch(:state)
      assert_equal Hive::Attempts::Record.iso8601(NOW + 1), reservation.fetch(:released_at)
      assert_equal "awaiting_delivery", request.fetch(:state)
      assert_equal lost.attempt_id, request.fetch(:claim_attempt_id)
      assert_raises(Hive::Attempts::CompareAndSwapFailed) do
        repository.mark_lost(launching, reason: "stale_generation", now: NOW + 2)
      end
      assert_equal 0, Hive::Attempts::CapacitySnapshot.build(store: repository, now: NOW).global_count
    end
  end

  def test_existing_dispatch_request_must_match_the_attempt_identity
    with_repository do |repository|
      first = repository.create_launching(**identity, launch_timeout_sec: 30, now: NOW)
      repository.mark_lost(first, reason: "stale_generation", now: NOW + 1)

      assert_raises(Hive::Attempts::RepositoryError) do
        repository.create_launching(
          **identity(
            attempt_id: "attempt-2", request_id: "request-1",
            task_id: "43", task_slug: "other-task", task_generation: "generation-2"
          ),
          launch_timeout_sec: 30, now: NOW + 2
        )
      end
      assert_equal 1, repository.database.read { |db| db[:attempts].count }
    end
  end

  def test_projection_reader_caches_live_and_terminal_bindings
    with_repository do |repository|
      launching = repository.create_launching(**identity, launch_timeout_sec: 30, now: NOW)
      reader = repository.projection_reader
      first = reader.fetch_projection_binding(launching.attempt_id)
      assert_same first, reader.fetch_projection_binding(launching.attempt_id)
      assert_nil reader.fetch_terminal_diagnostic_binding(launching.attempt_id)

      terminal = terminal_attempt(repository, launching)
      terminal_reader = repository.projection_reader
      diagnostic = terminal_reader.fetch_terminal_diagnostic_binding(terminal.attempt_id)
      assert_equal terminal.receipt, diagnostic.fetch("receipt")
      assert_same diagnostic, terminal_reader.fetch_terminal_diagnostic_binding(terminal.attempt_id)
    end
  end

  def test_payload_paths_fail_closed_for_io_non_files_missing_paths_and_escapes
    with_repository do |repository|
      with_replaced_singleton_method(FileUtils, :mkdir_p, ->(*) { raise Errno::EACCES, "denied" }) do
        assert_raises(Hive::Attempts::RepositoryError) do
          repository.output_directory("attempt", "segment", create: true)
        end
      end

      directory = repository.output_directory("attempt", create: true)
      FileUtils.mkdir_p(File.join(directory, "not-a-file"))
      assert_raises(Hive::Attempts::RepositoryError) do
        repository.output_path("attempt", "not-a-file")
      end
      assert_raises(Hive::Attempts::RepositoryError) do
        repository.send(:validate_directory!, File.join(repository.root, "missing"), "missing")
      end

      with_tmp_dir do |outside|
        assert_raises(Hive::Attempts::RepositoryError) do
          repository.send(:ensure_contained!, outside, repository.root)
        end
      end
    end
  end

  def test_transition_and_record_corruption_errors_remain_typed
    with_repository do |repository|
      launching = repository.create_launching(**identity, launch_timeout_sec: 30, now: NOW)
      claimed = repository.claim(
        launching, owner: owner, claim_capability: CLAIM_CAPABILITY,
        first_heartbeat_timeout_sec: 30, now: NOW + 1
      )
      running = repository.first_heartbeat(claimed, stale_sec: 30, now: NOW + 2)
      assert_raises(Hive::Attempts::RepositoryError) do
        repository.checkpoint(
          running, checkpoint: checkpoint, now: NOW + 3,
          output_references: [ { "path" => "../escape" } ]
        )
      end

      repository.database.transaction do |db|
        db[:attempts].where(attempt_id: running.attempt_id).update(task_generation: "different")
      end
      assert_raises(Hive::Attempts::RepositoryError) { repository.fetch(running.attempt_id) }

      invalid = "{"
      repository.database.transaction do |db|
        db[:attempts].where(attempt_id: running.attempt_id).update(
          record_json: invalid, record_digest: Digest::SHA256.hexdigest(invalid)
        )
      end
      assert_raises(Hive::Attempts::RepositoryError) { repository.fetch(running.attempt_id) }
    end

    with_repository do |repository|
      repository.database.define_singleton_method(:read) do |**|
        raise Hive::RuntimeControlPlane::IntegrityError.new("boom", code: :database_corrupt)
      end
      error = assert_raises(Hive::Attempts::RepositoryError) { repository.fetch("attempt") }
      assert_match(/lookup failed/, error.message)
    end
  end

  def test_projection_cutover_boundary_accepts_only_pre_activation_history
    with_repository do |repository|
      activated_at = "2026-07-16T12:00:00.000000Z"
      repository.database.transaction do |db|
        db[:installations].update(activated_at: activated_at)
      end

      assert repository.pre_activation_projection?("2026-07-16T11:59:59.999999Z")
      refute repository.pre_activation_projection?(activated_at)
      refute repository.pre_activation_projection?("2026-07-16T12:00:00.000001Z")
      refute repository.pre_activation_projection?("invalid")
    end
  end

  private

  def with_repository
    with_tmp_dir { |root| yield Hive::Attempts::Repository.new(root: root, migrate: true) }
  end

  def identity(attempt_id: "attempt-1", request_id: "request-1", task_id: "42",
               task_slug: "durable-task", task_generation: "generation-1")
    {
      attempt_id: attempt_id, request_id: request_id,
      predecessor_attempt_id: nil, task_id: task_id, project: "demo",
      task_slug: task_slug, intended_stage: "4-execute",
      task_generation: task_generation, ownership_generation: "owner-1",
      task_input_epoch: 1, progress_token: "progress-1", provider: "codex",
      worker_argv: [ "hive", "run", task_slug ],
      claim_capability_digest: Hive::Attempts::Capability.digest(CLAIM_CAPABILITY),
      starting_revision: "a" * 40, retry_charge: 0, inherited_outputs: []
    }
  end

  def owner
    {
      "pid" => Process.pid, "start_fingerprint" => "pid-start",
      "session_id" => Process.getsid(0), "process_group_id" => Process.getpgrp
    }
  end

  def checkpoint = { "revision" => "b" * 40, "progress_token" => "progress-1" }
  def output_reference = { "path" => "open/attempt-1/result.json", "size" => 2, "sha256" => "0" * 64 }
  def log_reference = { "path" => "open/attempt-1.frames", "size" => 4, "sha256" => "1" * 64 }

  def terminal_attempt(repository, launching)
    claimed = repository.claim(
      launching, owner: owner, claim_capability: CLAIM_CAPABILITY,
      first_heartbeat_timeout_sec: 30, now: NOW + 1
    )
    running = repository.first_heartbeat(claimed, stale_sec: 30, now: NOW + 2)
    repository.terminalize(
      running, outcome: "succeeded", exit_status: 0,
      final_checkpoint: checkpoint, output_references: [],
      log_reference: log_reference, now: NOW + 3
    )
  end
end
