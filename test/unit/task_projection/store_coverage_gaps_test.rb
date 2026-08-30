require "test_helper"
require "hive/task_projection/store"

class TaskProjectionStoreCoverageGapsTest < Minitest::Test
  include HiveTestHelper

  def test_checkpoint_validation_distinguishes_invalid_and_oversized_documents
    with_tmp_dir do |dir|
      store = projection_store(dir)

      write_checkpoint(store, "schema" => "wrong")
      assert_equal "checkpoint_invalid", store.send(:read_checkpoint, 10_000).fetch("reason")

      write_checkpoint(store, checkpoint_document.merge("state" => "oversized"))
      assert_equal "checkpoint_oversized", store.send(:read_checkpoint, 10_000).fetch("reason")

      write_checkpoint(store, checkpoint_document.merge("snapshot" => []))
      assert_equal "checkpoint_invalid", store.send(:read_checkpoint, 10_000).fetch("reason")

      File.write(store.checkpoint_path, "{")
      assert_equal "checkpoint_invalid", store.send(:read_checkpoint, 10_000).fetch("reason")
    end
  end

  def test_checkpoint_publication_bounds_large_snapshots_and_ignores_io_failure
    with_tmp_dir do |dir|
      store = projection_store(dir)
      projection = Object.new
      projection.define_singleton_method(:to_h) { { "payload" => "x" * 600_000 } }
      binding = { "cursor" => 0, "hash" => Digest::SHA256.hexdigest(""), "event_id" => nil }

      store.send(:publish_checkpoint, binding: binding, bytes: "", projection: projection)
      assert_equal "oversized", JSON.parse(File.read(store.checkpoint_path)).fetch("state")

      with_replaced_singleton_method(
        Hive::AtomicFile, :write, ->(*) { raise IOError, "disk unavailable" }
      ) do
        assert_nil store.send(
          :publish_checkpoint, binding: binding, bytes: "", projection: projection
        )
      end
    end
  end

  def test_checkpoint_suffix_rejects_torn_and_excessive_event_tails
    with_tmp_dir do |dir|
      write_journal(dir, [ condition_event("event-1") ])
      store = projection_store(dir)
      store.rebuild!
      File.open(store.journal_path, "a") { |file| file.write(JSON.generate(condition_event("event-2"))) }

      torn = store.read_bounded
      assert_equal "journal_suffix_torn", torn.diagnostics.first.fetch("reason")

      write_journal(dir, [ condition_event("event-1") ])
      store.rebuild!
      File.open(store.journal_path, "a") do |file|
        file.write("#{JSON.generate(condition_event("event-2"))}\n")
      end
      excessive = store.read_bounded(journal_event_limit: 0)
      assert excessive.truncated
      assert_equal "suffix_event_limit_exceeded", excessive.diagnostics.first.fetch("reason")
    end
  end

  def test_checkpoint_fallback_bounds_size_torn_tail_event_count_and_missing_journal
    with_tmp_dir do |dir|
      store = projection_store(dir)
      File.write(store.journal_path, "oversized\n")
      oversized = store.read_bounded(journal_suffix_max_bytes: 1)
      assert oversized.truncated
      assert_equal "journal_suffix_bytes", oversized.diagnostics.first.dig("details", "cap")

      File.write(store.journal_path, "{")
      torn = store.read_bounded
      assert_equal "journal_suffix_torn", torn.diagnostics.first.fetch("reason")

      write_journal(dir, [ condition_event("event-1"), condition_event("event-2") ])
      excessive = store.read_bounded(journal_event_limit: 1)
      assert excessive.truncated
      assert_equal "journal_event_limit_exceeded", excessive.diagnostics.first.fetch("reason")

      File.delete(store.journal_path)
      missing = store.read_bounded
      assert_equal 0, missing.journal_cursor
      assert_equal "partial", missing.state
    end
  end

  def test_routine_read_does_not_replay_a_small_journal_without_a_checkpoint
    with_tmp_dir do |dir|
      write_journal(dir, [ condition_event("event-1") ])
      store = projection_store(dir)
      store.define_singleton_method(:journal_bytes) do
        raise "complete journal read must not run"
      end

      result = store.read_routine

      assert_equal "repair_required", result.state
      assert_equal "checkpoint_missing", result.diagnostics.first.fetch("reason")
      assert_empty result.journal_records
    end
  end

  def test_routine_read_accepts_only_an_explicit_pristine_task
    with_tmp_dir do |dir|
      store = projection_store(dir)

      broken = store.read_routine
      pristine = store.read_routine(pristine: true)

      assert_equal "repair_required", broken.state
      assert broken.repair_required?
      assert_equal "pristine", pristine.state
      assert_equal 0, pristine.journal_cursor
      assert_empty pristine.diagnostics
    end
  end

  def test_routine_read_enforces_attempt_and_predecessor_budgets
    with_tmp_dir do |dir|
      write_journal(dir, [ condition_event("event-1") ])
      store = projection_store(dir)
      store.rebuild!
      checkpoint = JSON.parse(File.read(store.checkpoint_path))
      binding = checkpoint.dig("snapshot", "journal", "attempts").fetch(0)

      checkpoint["snapshot"]["journal"]["attempts"] = [
        binding,
        binding.merge("attempt_id" => "attempt-2")
      ]
      write_checkpoint(store, checkpoint)
      attempts = store.read_routine(
        limits: Hive::TaskWorkspace::Limits.new(attempt_ids: 1)
      )
      assert_equal "repair_required", attempts.state
      assert_equal "attempt_ids", attempts.diagnostics.first.dig("details", "cap")

      attempts_by_id = {
        "attempt-1" => durable_attempt,
        "attempt-2" => durable_attempt.merge(
          "attempt_id" => "attempt-2", "predecessor_attempt_id" => "predecessor-1"
        ),
        "predecessor-1" => durable_attempt.merge(
          "attempt_id" => "predecessor-1", "predecessor_attempt_id" => "predecessor-2"
        ),
        "predecessor-2" => durable_attempt.merge(
          "attempt_id" => "predecessor-2", "predecessor_attempt_id" => nil
        )
      }
      attempt_store = Object.new
      attempt_store.define_singleton_method(:fetch) { |attempt_id| attempts_by_id[attempt_id] }
      store = Hive::TaskProjection::Store.new(task_folder: dir, attempt_store: attempt_store)
      write_journal(dir, [ condition_event("event-1") ])
      store.rebuild!
      suffix_event = condition_event("event-2")
      suffix_event["attempt_id"] = "attempt-2"
      suffix_event.fetch("evidence").first["attempt_id"] = "attempt-2"
      File.open(store.journal_path, "a") do |journal|
        journal.write("#{JSON.generate(suffix_event)}\n")
      end

      suffix_attempts = store.read_routine(
        limits: Hive::TaskWorkspace::Limits.new(attempt_ids: 1)
      )
      assert_equal "repair_required", suffix_attempts.state
      assert_equal "attempt_ids", suffix_attempts.diagnostics.first.dig("details", "cap")

      predecessors = store.read_routine(
        limits: Hive::TaskWorkspace::Limits.new(predecessor_fetches: 1)
      )
      assert_equal "repair_required", predecessors.state
      assert_equal "predecessor_fetches",
                   predecessors.diagnostics.first.dig("details", "cap")
    end
  end

  def test_bounded_read_and_prefix_failures_degrade_without_raising
    with_tmp_dir do |dir|
      store = projection_store(dir)
      store.define_singleton_method(:read_checkpoint) { |_| raise KeyError, "bad checkpoint" }

      degraded = store.read_bounded
      assert_equal "bounded_projection_failed", degraded.diagnostics.first.fetch("reason")
      assert_equal "KeyError", degraded.diagnostics.first.dig("details", "error_class")

      refute projection_store(dir).send(:checkpoint_prefix_valid?, {}, 0)
    end
  end

  def test_bounded_attempt_store_supports_direct_fetch
    calls = []
    underlying = Object.new
    underlying.define_singleton_method(:fetch) do |attempt_id|
      calls << attempt_id
      { "attempt_id" => attempt_id }
    end
    bounded_class = Hive::TaskProjection::Store.const_get(:BoundedAttemptStore, false)
    bounded = bounded_class.new(
      store: underlying, primary_attempt_ids: [ "attempt-1" ], predecessor_limit: 1
    )

    assert_equal "attempt-1", bounded.fetch("attempt-1").fetch("attempt_id")
    assert_equal [ "attempt-1" ], calls
  end

  def test_pristine_initialization_fails_closed_when_its_checkpoint_is_not_current
    with_tmp_dir do |dir|
      store = projection_store(dir)
      projection = Hive::TaskProjection.project(records: [])
      bounded = Hive::TaskProjection::Store::BoundedRead.new(
        projection: projection, state: "repair_required",
        diagnostics: [ { "reason" => "checkpoint_invalid" } ], truncated: false,
        journal_cursor: 0, journal_records: []
      )
      store.define_singleton_method(:read_bounded_unlocked) { |**| bounded }

      error = assert_raises(Hive::TaskProjection::InvalidJournal) do
        store.initialize_pristine!
      end
      assert_match(/checkpoint_invalid/, error.message)
    end
  end

  def test_checkpoint_prefix_returns_false_on_an_open_failure
    with_tmp_dir do |dir|
      store = projection_store(dir)
      File.write(store.journal_path, "journal\n")
      original_open = File.method(:open)
      replacement = lambda do |path, *args, **kwargs, &block|
        raise Errno::EACCES, path if path == store.journal_path

        original_open.call(path, *args, **kwargs, &block)
      end

      with_replaced_singleton_method(File, :open, replacement) do
        refute store.send(:checkpoint_prefix_valid?, {}, 0)
      end
    end
  end

  def test_journal_locks_reject_descriptor_replacement
    %i[read write].each do |mode|
      with_tmp_dir do |dir|
        store = projection_store(dir)
        lock_path = File.join(dir, Hive::TaskJournal::LOCK_BASENAME)
        File.write(lock_path, "old\n")
        old_path = "#{lock_path}.old"
        original_open = File.method(:open)
        swapped = false
        replacement = lambda do |path, *args, **kwargs, &block|
          if path == lock_path && !swapped
            swapped = true
            File.rename(lock_path, old_path)
            File.write(lock_path, "new\n")
          end
          original_open.call(path, *args, **kwargs, &block)
        end

        with_replaced_singleton_method(File, :open, replacement) do
          error_class = mode == :read ?
            Hive::TaskProjection::RoutineLockInvalid : Hive::TaskProjection::InvalidJournal
          assert_raises(error_class) do
            store.send("with_journal_#{mode}_lock") { flunk "mismatched lock must not yield" }
          end
        end
      end
    end
  end

  def test_checkpoint_seed_reconstructs_identity_operator_and_legacy_records
    with_tmp_dir do |dir|
      store = projection_store(dir)
      data = seed_projection_data
      projection = Object.new
      projection.define_singleton_method(:to_h) { data }

      records = store.send(:checkpoint_seed_records, projection)
      assert_includes records.map { |row| row.fetch("event_type") }, "legacy_baseline"
      assert_includes records.map { |row| row.fetch("event_type") }, "implementation_identity_captured"
      assert_includes records.map { |row| row.fetch("event_type") }, "implementation_stage_resolved"
      assert_includes records.map { |row| row.fetch("event_type") }, "implementation_identity_fallback"
      assert_includes records.map { |row| row.fetch("event_type") }, "operator_action"
      identity = records.find { |row| row["event_id"] == "identity-1" }
      refute identity.dig("payload", "identity").key?("resolved_attempt")
    end
  end

  def test_degraded_read_uses_a_bounded_snapshot_and_rejects_a_corrupt_one
    with_tmp_dir do |dir|
      write_journal(dir, [ condition_event("event-1") ])
      store = projection_store(dir)
      expected = store.rebuild!

      degraded = store.send(
        :degraded_bounded_read, reason: "forced", state: "partial",
        snapshot_limit: 512 * 1024, error: IOError.new("forced")
      )
      assert_equal expected.to_h, degraded.projection.to_h
      assert_equal expected.to_h.dig("journal", "cursor"), degraded.journal_cursor

      File.write(store.snapshot_path, "{")
      assert_nil store.send(:bounded_snapshot_projection, 512 * 1024)
    end
  end

  private

  def projection_store(dir)
    Hive::TaskProjection::Store.new(task_folder: dir, attempt_store: durable_attempt_store)
  end

  def write_checkpoint(store, document)
    File.write(store.checkpoint_path, "#{JSON.generate(document)}\n")
  end

  def checkpoint_document
    {
      "schema" => Hive::TaskProjection::Store::CHECKPOINT_SCHEMA,
      "schema_version" => Hive::TaskProjection::Store::CHECKPOINT_SCHEMA_VERSION,
      "state" => "current", "snapshot" => {}, "journal" => {}
    }
  end

  def write_journal(dir, records)
    body = records.map { |record| JSON.generate(record) }.join("\n")
    File.write(File.join(dir, Hive::TaskJournal::JOURNAL_BASENAME), "#{body}\n")
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

  def condition_event(event_id)
    {
      "schema" => Hive::TaskJournal::Envelope::SCHEMA, "schema_version" => 1,
      "event_id" => event_id, "event_type" => "condition_observed",
      "occurred_at" => "2026-07-17T12:00:00.000000Z",
      "observed_at" => "2026-07-17T12:00:00.000000Z",
      "task" => { "id" => "42", "slug" => "task" }, "workflow" => "coding",
      "stage" => "4-execute", "attempt_id" => "attempt-1", "task_generation" => 1,
      "ownership_generation" => "owner-1", "commit_generation" => 0,
      "reason" => "lease_observed", "evidence" => [ {
        "type" => "attempt_lease", "attempt_id" => "attempt-1",
        "lease_version" => 1, "state" => "running"
      } ],
      "provenance" => { "source" => "test" },
      "payload" => { "condition" => "AgentHealthy", "state" => "satisfied" }
    }
  end

  def seed_projection_data
    identity_entry = {
      "event_id" => "identity-1", "resolved_attempt" => "attempt-1",
      "generation" => 1, "model" => "codex"
    }
    {
      "task" => { "id" => "42", "slug" => "task" },
      "journal" => { "attempts" => [ { "attempt_id" => "attempt-1", "stage" => "4-execute" } ] },
      "conditions" => { "current" => [], "history" => [] },
      "identity" => { "attempt_id" => "attempt-1", "task_generation" => 1, "commit_generation" => 0 },
      "compatibility" => { "baseline_present" => true },
      "implementation_identity" => {
        "history" => [ identity_entry ], "stages" => { "execute" => identity_entry },
        "fallback_warnings" => [ { "event_id" => "warning-1", "generation" => 1,
                                  "reason" => "fallback" } ]
      },
      "condition_overrides" => [ {
        "event_id" => "override-1", "task_generation" => 1,
        "attempt_id" => "attempt-1", "reason" => "operator override",
        "transition" => "advance", "from_stage" => "3-plan", "to_stage" => "4-execute"
      } ]
    }
  end
end
