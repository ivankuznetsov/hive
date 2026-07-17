require "test_helper"
require "hive/task_projection/store"

class TaskProjectionStoreTest < Minitest::Test
  include HiveTestHelper

  def test_missing_corrupt_and_stale_snapshots_replay_to_canonical_state_without_writing
    with_tmp_dir do |dir|
      write_journal(dir, [ condition_event("event-1") ])
      store = projection_store(dir)
      missing = store.read
      refute File.exist?(store.snapshot_path)

      File.write(store.snapshot_path, "{")
      corrupt = store.read
      assert_equal Hive::TaskProjection.canonical_json(missing.to_h),
                   Hive::TaskProjection.canonical_json(corrupt.to_h)

      store.rebuild!
      write_journal(dir, [ condition_event("event-1"), condition_event("event-2", state: "unsatisfied") ])
      stale = store.read
      assert_equal "unsatisfied", stale.current_condition("AgentHealthy").fetch("state")
      snapshot = JSON.parse(File.read(store.snapshot_path))
      assert_equal "event-1", snapshot.dig("journal", "event_id"), "read-only replay must not republish"
    end
  end

  def test_valid_snapshot_avoids_projector_replay
    with_tmp_dir do |dir|
      write_journal(dir, [ condition_event("event-1") ])
      projection_store(dir).rebuild!
      exploding = Object.new
      exploding.define_singleton_method(:project) { |**| raise "projector should not run" }

      replacement = ->(*) { raise "journal parser should not run" }
      projection = with_replaced_singleton_method(
        Hive::TaskProjection, :parse_journal, replacement
      ) do
        projection_store(dir, projector: exploding).read
      end
      assert_equal "satisfied", projection.current_condition("AgentHealthy").fetch("state")
    end
  end

  def test_journal_validation_fetches_each_immutable_attempt_once
    with_tmp_dir do |dir|
      write_journal(dir, [ condition_event("event-1"), condition_event("event-2") ])
      attempt = durable_attempt
      fetches = 0
      attempt_store = Object.new
      attempt_store.define_singleton_method(:fetch) do |attempt_id|
        fetches += 1
        attempt if attempt_id == "attempt-1"
      end

      projection = Hive::TaskProjection::Store.new(
        task_folder: dir, attempt_store: attempt_store
      ).read

      assert_equal "satisfied", projection.current_condition("AgentHealthy").fetch("state")
      assert_equal 1, fetches
    end
  end

  def test_valid_snapshot_overlays_post_publication_compatibility_marker_without_writing
    with_tmp_dir do |dir|
      write_journal(dir, [ condition_event("event-1") ])
      store = projection_store(dir)
      store.rebuild!
      before = File.binread(store.snapshot_path)
      marker = Hive::Markers::State.new(
        name: :execute_complete, attrs: { "mode" => "research" }, raw: nil
      )

      projection = store.read(marker: marker)

      assert_equal "execute_complete", projection["compatibility"].dig("marker", "name")
      assert_equal "execute_complete",
                   projection["compatibility"].dig("marker_fallback", "name")
      assert_equal before, File.binread(store.snapshot_path)
    end
  end

  def test_rebuild_is_byte_deterministic_and_publishes_cursor_hash_binding
    with_tmp_dir do |dir|
      write_journal(dir, [ condition_event("event-1") ])
      store = projection_store(dir)
      store.rebuild!
      first = File.binread(store.snapshot_path)
      File.delete(store.snapshot_path)
      store.rebuild!
      second = File.binread(store.snapshot_path)

      assert_equal first, second
      parsed = JSON.parse(second)
      assert_equal File.size(store.journal_path), parsed.dig("journal", "cursor")
      assert_equal Digest::SHA256.file(store.journal_path).hexdigest, parsed.dig("journal", "hash")
    end
  end

  def test_valid_snapshot_rejects_malformed_authoritative_tail
    with_tmp_dir do |dir|
      record = condition_event("event-1")
      File.write(File.join(dir, "task-journal.jsonl"), "#{JSON.generate(record)}\nnot-json\n")
      store = projection_store(dir)

      error = assert_raises(Hive::TaskProjection::InvalidJournal) { store.read }
      assert_includes error.message, "invalid JSON"
    end
  end

  def test_authoritative_journal_rejects_legacy_telemetry_shape
    with_tmp_dir do |dir|
      authoritative = condition_event("event-1")
      telemetry = { "event_id" => "telemetry-1", "event_type" => "stage_exit" }
      write_journal(dir, [ authoritative, telemetry ])

      error = assert_raises(Hive::TaskProjection::InvalidJournal) do
        projection_store(dir).read
      end
      assert_includes error.message, "unexpected record schema"
    end
  end

  def test_valid_snapshot_revalidates_referenced_durable_attempt
    with_tmp_dir do |dir|
      available = true
      attempt = durable_attempt
      attempt_store = Object.new
      attempt_store.define_singleton_method(:fetch) do |attempt_id|
        attempt if available && attempt_id == "attempt-1"
      end
      store = Hive::TaskProjection::Store.new(
        task_folder: dir, attempt_store: attempt_store
      )
      write_journal(dir, [ condition_event("event-1") ])
      store.rebuild!

      available = false
      error = assert_raises(Hive::TaskProjection::InvalidJournal) { store.read }
      assert_includes error.message, "unknown durable attempt"
    end
  end

  def test_attempt_store_error_invalidates_snapshot_and_fails_replay_closed
    with_tmp_dir do |dir|
      write_journal(dir, [ condition_event("event-1") ])
      projection_store(dir).rebuild!
      exploding_store = Object.new
      exploding_store.define_singleton_method(:fetch) do |_attempt_id|
        raise Hive::Attempts::StoreError, "attempt store unavailable"
      end
      store = Hive::TaskProjection::Store.new(
        task_folder: dir, attempt_store: exploding_store
      )

      error = assert_raises(Hive::TaskProjection::InvalidJournal) { store.read }
      assert_includes error.message, "attempt store unavailable"
    end
  end

  def test_attempt_terminal_state_invalidates_snapshot_and_reconciles_health
    with_tmp_dir do |dir|
      attempt = durable_attempt
      attempt_store = Object.new
      attempt_store.define_singleton_method(:fetch) do |attempt_id|
        attempt if attempt_id == "attempt-1"
      end
      store = Hive::TaskProjection::Store.new(
        task_folder: dir, attempt_store: attempt_store
      )
      write_journal(dir, [ condition_event("event-1") ])
      store.rebuild!

      attempt["state"] = "terminal"
      attempt["outcome"] = "failed"
      attempt["lease_version"] = 2

      projection = store.read
      health = projection.current_condition("AgentHealthy")
      assert_equal "unsatisfied", health.fetch("state")
      assert_equal "attempt_terminal_failed", health.fetch("reason")
      assert_equal true, health.dig("provenance", "projection_reconciled_attempt_state")
    end
  end

  def test_rebuild_cannot_erase_durable_handoff_after_journal_loss
    with_tmp_dir do |dir|
      write_journal(dir, [ condition_event("event-1") ])
      store = projection_store(dir)
      store.rebuild!
      snapshot = File.binread(store.snapshot_path)
      File.delete(store.journal_path)

      error = assert_raises(Hive::TaskProjection::InvalidJournal) { store.rebuild! }
      assert_includes error.message, "missing or empty after durable handoff"
      assert_equal snapshot, File.binread(store.snapshot_path)

      File.delete(store.snapshot_path)
      marker = Hive::Markers::State.new(
        name: :execute_complete,
        attrs: { "attempt_id" => "attempt-1" },
        raw: nil
      )
      assert_raises(Hive::TaskProjection::InvalidJournal) { store.read(marker: marker) }
      assert_raises(Hive::TaskProjection::InvalidJournal) { store.rebuild!(marker: marker) }
      refute File.exist?(store.snapshot_path)
    end
  end

  def test_non_execute_attempt_marker_does_not_claim_condition_journal_handoff
    with_tmp_dir do |dir|
      marker = Hive::Markers::State.new(
        name: :review_waiting,
        attrs: { "attempt_id" => "review-attempt-1" },
        raw: nil
      )

      projection = projection_store(dir).read(marker: marker)

      assert_equal "review_waiting", projection["compatibility"].dig("marker", "name")
      assert_equal 0, projection["journal"].fetch("cursor")
    end
  end

  def test_replay_rejects_future_schema_versions_and_forged_attempt_identity
    with_tmp_dir do |dir|
      future = condition_event("future")
      future["schema_version"] = Hive::TaskJournal::Envelope::SCHEMA_VERSION + 1
      write_journal(dir, [ future ])
      error = assert_raises(Hive::TaskProjection::InvalidJournal) { projection_store(dir).read }
      assert_includes error.message, "unsupported schema"

      forged = condition_event("forged")
      forged["attempt_id"] = "attempt-forged"
      write_journal(dir, [ forged ])
      error = assert_raises(Hive::TaskProjection::InvalidJournal) { projection_store(dir).read }
      assert_includes error.message, "unknown durable attempt"
    end
  end

  def test_default_read_does_not_create_attempt_store_directories
    with_tmp_dir do |dir|
      attempts_root = File.join(dir, "missing-attempts")

      with_env("HIVE_ATTEMPT_STORE_ROOT" => attempts_root) do
        projection = Hive::TaskProjection::Store.new(task_folder: dir).read
        assert_equal 0, projection["identity"].fetch("task_generation")
      end

      refute File.exist?(attempts_root)
    end
  end

  private

  def write_journal(dir, records)
    File.write(File.join(dir, "task-journal.jsonl"), records.map { |record| JSON.generate(record) }.join("\n") + "\n")
  end

  def projection_store(dir, **options)
    Hive::TaskProjection::Store.new(
      task_folder: dir, attempt_store: durable_attempt_store, **options
    )
  end

  def durable_attempt_store
    attempt = durable_attempt
    Object.new.tap do |store|
      store.define_singleton_method(:fetch) { |attempt_id| attempt if attempt_id == "attempt-1" }
    end
  end

  def durable_attempt
    {
      "attempt_id" => "attempt-1", "predecessor_attempt_id" => nil,
      "task_slug" => "task", "task_id" => "42", "intended_stage" => "4-execute",
      "task_input_epoch" => 1, "ownership_generation" => "owner-1",
      "accepted_at" => "2026-07-17T11:59:00.000000Z",
      "state" => "running", "outcome" => nil, "lease_version" => 1
    }.tap do |attempt|
      attempt.define_singleton_method(:attempt_id) { fetch("attempt_id") }
      attempt.define_singleton_method(:task_input_epoch) { fetch("task_input_epoch") }
      attempt.define_singleton_method(:ownership_generation) { fetch("ownership_generation") }
    end
  end

  def condition_event(event_id, state: "satisfied")
    {
      "schema" => Hive::TaskJournal::Envelope::SCHEMA,
      "schema_version" => 1,
      "event_id" => event_id,
      "event_type" => "condition_observed",
      "occurred_at" => "2026-07-17T12:00:00.000000Z",
      "observed_at" => "2026-07-17T12:00:00.000000Z",
      "task" => { "id" => "42", "slug" => "task" },
      "workflow" => "coding",
      "stage" => "4-execute",
      "attempt_id" => "attempt-1",
      "task_generation" => 1,
      "ownership_generation" => "owner-1",
      "commit_generation" => 0,
      "reason" => "lease_observed",
      "evidence" => [
        { "type" => "attempt_lease", "attempt_id" => "attempt-1", "lease_version" => 1, "state" => "running" }
      ],
      "provenance" => { "source" => "test" },
      "payload" => { "condition" => "AgentHealthy", "state" => state }
    }
  end
end
