require "test_helper"
require "hive/task_projection/store"

class TaskProjectionStoreTest < Minitest::Test
  include HiveTestHelper

  def test_missing_corrupt_and_stale_snapshots_replay_to_canonical_state_without_writing
    with_tmp_dir do |dir|
      write_journal(dir, [ condition_event("event-1") ])
      store = Hive::TaskProjection::Store.new(task_folder: dir)
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
      Hive::TaskProjection::Store.new(task_folder: dir).rebuild!
      exploding = Object.new
      exploding.define_singleton_method(:project) { |**| raise "projector should not run" }

      projection = Hive::TaskProjection::Store.new(task_folder: dir, projector: exploding).read
      assert_equal "satisfied", projection.current_condition("AgentHealthy").fetch("state")
    end
  end

  def test_rebuild_is_byte_deterministic_and_publishes_cursor_hash_binding
    with_tmp_dir do |dir|
      write_journal(dir, [ condition_event("event-1") ])
      store = Hive::TaskProjection::Store.new(task_folder: dir)
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

  private

  def write_journal(dir, records)
    File.write(File.join(dir, "events.jsonl"), records.map { |record| JSON.generate(record) }.join("\n") + "\n")
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
