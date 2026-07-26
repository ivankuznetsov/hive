require "test_helper"
require "json_schemer"
require "hive/daemon/pr_merge_reconciliation_store"

class HiveDaemonPrMergeReconciliationStoreTest < Minitest::Test
  include HiveTestHelper

  T0 = Time.utc(2026, 7, 25, 12)

  def test_atomic_round_trip_schema_cursor_and_private_mode
    with_tmp_dir do |dir|
      store = build_store
      identity = identity_for(dir)
      candidate = candidate_for(store)
      state = store.transaction(identity, now: T0) do |document|
        document["candidates"][candidate.fetch("key")] = candidate
        document["backlog"] = {
          "watermark" => T0.iso8601(6),
          "scanned_at" => T0.iso8601(6),
          "complete" => true,
          "outcomes" => {}
        }
      end

      assert_equal candidate.fetch("key"), store.next_candidate(state, now: T0).fetch("key")
      store.advance_cursor!(state, candidate.fetch("key"))
      state["candidates"][candidate.fetch("key")]["archive"]["status"] = "archived"
      assert_nil store.next_candidate(state, now: T0 + 1)
      assert_equal 0o600, File.stat(store.path(identity.fetch("hive_state_path"))).mode & 0o777

      persisted = store.load(identity)
      schema = JSONSchemer.schema(
        JSON.parse(File.read(Hive::Schemas.schema_path(store.class::SCHEMA)))
      )
      assert schema.valid?(persisted), schema.validate(persisted).to_a.inspect
    end
  end

  def test_next_candidate_rotates_and_honors_retry_time
    store = build_store(dry_run: true)
    identity = identity_for("/tmp/demo")
    first = candidate_for(store, slug: "first", generation: "a" * 64)
    second = candidate_for(store, slug: "second", generation: "b" * 64)
    state = store.transaction(identity, now: T0) do |document|
      document["candidates"][first.fetch("key")] = first
      document["candidates"][second.fetch("key")] = second
    end
    picked = store.next_candidate(state, now: T0)
    store.advance_cursor!(state, picked.fetch("key"))
    assert_equal(
      (state.fetch("candidates").keys - [ picked.fetch("key") ]).first,
      store.next_candidate(state, now: T0).fetch("key")
    )

    state.fetch("candidates").each_value do |candidate|
      candidate["retry"]["not_before"] = (T0 + 60).iso8601(6)
    end
    assert_nil store.next_candidate(state, now: T0 + 30)
    refute_nil store.next_candidate(state, now: T0 + 61)
  end

  def test_failure_backoff_is_unbounded_in_count_and_capped_in_time
    store = build_store(dry_run: true, backoff_base_sec: 10, backoff_max_sec: 20)
    candidate = candidate_for(store)

    30.times do |index|
      store.record_failure!(candidate, Hive::GhError.new("offline #{index}"), now: T0 + index)
    end

    assert_equal 30, candidate.dig("retry", "failures")
    assert_equal T0 + 29 + 20, Time.iso8601(candidate.dig("retry", "not_before"))
    assert_match(/offline 29/, candidate.dig("archive", "last_error"))
    store.clear_retry!(candidate)
    assert_equal({ "failures" => 0, "not_before" => nil }, candidate.fetch("retry"))
  end

  def test_identity_drift_and_corruption_quarantine_without_rewrite
    with_tmp_dir do |dir|
      store = build_store
      identity = identity_for(dir)
      store.transaction(identity, now: T0) { |_state| nil }
      authoritative = File.binread(store.path(identity.fetch("hive_state_path")))
      changed = identity.merge("repository" => "acme/renamed")

      error = assert_raises(Hive::Daemon::PrMergeReconciliationStore::Invalid) do
        store.load(changed)
      end
      assert_match(/repository identity changed/, error.message)
      assert_equal authoritative, File.binread(store.path(identity.fetch("hive_state_path")))
      refute_empty quarantine_paths(identity)

      File.binwrite(store.path(identity.fetch("hive_state_path")), "{")
      assert_raises(Hive::Daemon::PrMergeReconciliationStore::Invalid) do
        store.load(identity)
      end
      assert_equal "{", File.binread(store.path(identity.fetch("hive_state_path")))
      assert_operator quarantine_paths(identity).length, :>=, 2
    end
  end

  def test_quarantine_preserves_raw_bytes_once_by_content_digest
    with_tmp_dir do |dir|
      store = build_store
      identity = identity_for(dir)
      store.transaction(identity, now: T0) { |_state| nil }
      corrupt = "{not-json"
      File.binwrite(store.path(identity.fetch("hive_state_path")), corrupt)

      2.times do
        assert_raises(Hive::Daemon::PrMergeReconciliationStore::Invalid) do
          store.load(identity)
        end
      end

      root = File.join(
        identity.fetch("hive_state_path"), "daemon", "quarantine",
        "pr-merge-reconciliation"
      )
      digest = Digest::SHA256.hexdigest(corrupt)
      assert_equal corrupt, File.binread(File.join(root, "#{digest}.payload"))
      assert File.file?(File.join(root, "#{digest}.json"))
      assert_equal 2, Dir[File.join(root, "#{digest}.*")].length
    end
  end

  def test_terminal_candidates_are_compacted_after_retention_window
    store = build_store(dry_run: true)
    identity = identity_for("/tmp/demo")
    candidate = candidate_for(store)
    candidate["archive"]["status"] = "archived"
    store.transaction(identity, now: T0) do |state|
      state["candidates"][candidate.fetch("key")] = candidate
      state["cursor"] = candidate.fetch("key")
    end

    state = store.transaction(
      identity,
      now: T0 + Hive::Daemon::PrMergeReconciliationStore::TERMINAL_RETENTION_SEC + 1
    ) { |_document| nil }

    assert_empty state.fetch("candidates")
    assert_nil state.fetch("cursor")
  end

  def test_transaction_lock_prevents_lost_concurrent_candidates
    with_tmp_dir do |dir|
      store = build_store
      identity = identity_for(dir)
      threads = 4.times.map do |index|
        Thread.new do
          candidate = candidate_for(
            store, slug: "task-#{index}", generation: index.to_s(16).rjust(64, "0")
          )
          store.transaction(identity, now: T0 + index) do |state|
            state["candidates"][candidate.fetch("key")] = candidate
          end
        end
      end
      threads.each(&:value)

      assert_equal 4, store.load(identity).fetch("candidates").length
    end
  end

  def test_invalid_shapes_and_configuration_fail_closed
    store = build_store(dry_run: true)
    identity = identity_for("/tmp/demo")
    state = store.build(identity, now: T0)
    [
      [],
      state.merge("schema_version" => 99),
      state.merge("cursor" => "bad"),
      state.merge("updated_at" => "later"),
      state.merge("backlog" => {}),
      state.merge("candidates" => { "bad" => {} })
    ].each do |invalid|
      assert_raises(Hive::Daemon::PrMergeReconciliationStore::Invalid) do
        store.validate!(invalid)
      end
    end

    candidate = candidate_for(store)
    candidate["remote"]["state"] = "lost"
    state = store.build(identity, now: T0)
    state["candidates"][candidate.fetch("key")] = candidate
    assert_raises(Hive::Daemon::PrMergeReconciliationStore::Invalid) do
      store.validate!(state)
    end

    assert_raises(ArgumentError) { build_store(backoff_base_sec: 0) }
    assert_raises(ArgumentError) { build_store(backoff_max_sec: -1) }
    assert_raises(ArgumentError) do
      build_store(backoff_base_sec: 20, backoff_max_sec: 10)
    end
  end

  def test_dry_run_stays_in_memory_and_returns_detached_reads
    store = build_store(dry_run: true)
    identity = identity_for("/tmp/demo")
    store.transaction(identity, now: T0) { |_state| nil }
    first = store.load(identity)
    first["registration"] = "mutated"

    assert_equal "demo", store.load(identity).fetch("registration")
    refute File.exist?(store.path(identity.fetch("hive_state_path")))
    assert_match(/\A[a-f0-9]{64}\z/,
                 store.candidate_key(
                   project: "demo", slug: "task", task_generation: "x",
                   pull_request: pull_request
                 ))
  end

  private

  def build_store(**options)
    Hive::Daemon::PrMergeReconciliationStore.new(**options)
  end

  def identity_for(root)
    project = File.expand_path(root)
    {
      "registration" => "demo",
      "project_path" => project,
      "hive_state_path" => File.join(project, ".hive-state"),
      "host" => "github.com",
      "repository" => "acme/demo",
      "default_branch" => "main"
    }
  end

  def candidate_for(store, slug: "task", generation: "a" * 64)
    key = store.candidate_key(
      project: "demo", slug: slug, task_generation: generation,
      pull_request: pull_request
    )
    {
      "key" => key,
      "task" => {
        "project" => "demo", "slug" => slug, "id" => 1,
        "workflow" => "coding", "folder" => "/tmp/demo/#{slug}"
      },
      "observation" => {
        "stage" => "5-open-pr", "marker" => "complete",
        "marker_generation" => "b" * 64,
        "task_generation" => generation,
        "state_file_mtime" => T0.iso8601(6),
        "held" => false,
        "hold_reason" => nil
      },
      "pull_request" => {
        "url" => "https://github.com/acme/demo/pull/42",
        "host" => "github.com", "repository" => "acme/demo",
        "number" => 42, "observed_head" => "c" * 40
      },
      "remote" => {
        "state" => "unknown", "merge_oid" => nil,
        "merged_at" => nil, "observed_at" => nil
      },
      "architecture" => {
        "status" => "pending", "request_id" => nil,
        "receipt" => nil, "last_error" => nil
      },
      "archive" => {
        "status" => "pending", "receipt_digest" => nil,
        "archived_at" => nil, "last_error" => nil
      },
      "retry" => { "failures" => 0, "not_before" => nil },
      "updated_at" => T0.iso8601(6)
    }
  end

  def pull_request
    {
      "url" => "https://github.com/acme/demo/pull/42",
      "host" => "github.com", "repository" => "acme/demo",
      "number" => 42, "observed_head" => "c" * 40
    }
  end

  def quarantine_paths(identity)
    Dir.glob(
      File.join(
        identity.fetch("hive_state_path"), "daemon", "quarantine",
        "pr-merge-reconciliation", "*.json"
      )
    )
  end
end
