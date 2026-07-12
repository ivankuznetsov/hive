require "test_helper"
require "hive/daemon/refactor_patrol_merge_progress_store"

class HiveDaemonRefactorPatrolMergeProgressStoreTest < Minitest::Test
  include HiveTestHelper

  T0 = Time.utc(2026, 7, 10, 12, 0, 0)

  def test_atomic_round_trip_fingerprint_and_fsynced_unlink
    with_tmp_dir do |dir|
      store = build_store
      checkpoint = checkpoint_state
      progress = progress_for(store, checkpoint)

      store.write(dir, progress)

      assert_equal progress, store.load(dir)
      assert_match(/\A[a-f0-9]{64}\z/, progress.fetch("base_checkpoint_sha256"))
      assert_equal T0.iso8601, progress.dig("scan", "merged_until")
      assert_nil progress.dig("scan", "result_count")
      assert_equal 0o600, File.stat(store.path(dir)).mode & 0o777

      fsynced = []
      with_replaced_singleton_method(Hive::AtomicFile, :fsync_directory, ->(path) { fsynced << path }) do
        store.clear(dir)
      end

      refute File.exist?(store.path(dir))
      assert_equal [ File.dirname(store.path(dir)) ], fsynced
    end
  end

  def test_backoff_is_durable_exponential_bounded_and_honored
    with_tmp_dir do |dir|
      store = build_store(backoff_max_sec: 6)
      progress = progress_for(store, checkpoint_state)

      store.record_failure!(dir, progress, Hive::GhError.new("offline"), T0)
      assert store.retry_pending?(progress, T0 + 2)
      refute store.retry_pending?(progress, T0 + 3)
      assert_equal T0 + 2.5, Time.iso8601(progress.dig("retry", "not_before"))

      store.record_failure!(dir, progress, Hive::GhError.new("offline"), T0 + 3)
      assert_equal 2, progress.dig("retry", "failures")
      assert_equal T0 + 6, Time.iso8601(progress.dig("retry", "not_before"))
      assert_equal progress, store.load(dir)
    end
  end

  def test_identity_drift_is_quarantined_without_rewriting_progress
    with_tmp_dir do |dir|
      store = build_store
      progress = progress_for(store, checkpoint_state)
      store.write(dir, progress)
      bytes = File.binread(store.path(dir))

      error = assert_raises(Hive::Daemon::RefactorPatrolMergeProgressStore::Invalid) do
        store.assert_identity!(
          progress, registration: "demo", host: "github.com",
          repository: "acme/renamed", default_branch: "main",
          project_root: dir
        )
      end

      assert_match(/repository identity changed/, error.message)
      assert_equal bytes, File.binread(store.path(dir))
      evidence = Dir.glob(
        File.join(dir, ".hive-state", "refactor_patrol", "v2", "quarantine", "reconciler-progress", "*.json")
      )
      assert_equal 1, evidence.length
      assert_equal "acme/renamed", JSON.parse(File.read(evidence.first)).dig("observed", "repository")
    end
  end

  def test_corrupt_authoritative_progress_is_quarantined
    with_tmp_dir do |dir|
      store = build_store
      FileUtils.mkdir_p(File.dirname(store.path(dir)))
      File.binwrite(store.path(dir), "{")

      error = assert_raises(Hive::Daemon::RefactorPatrolMergeProgressStore::Invalid) do
        store.load(dir)
      end

      assert_match(/cannot read reconciler progress/, error.message)
      assert_equal "{", File.binread(store.path(dir))
      refute_empty Dir.glob(
        File.join(dir, ".hive-state", "refactor_patrol", "v2", "quarantine", "reconciler-progress", "*.json")
      )
    end
  end

  def test_structurally_invalid_json_progress_uses_invalid_rescue_and_quarantine
    with_tmp_dir do |dir|
      store = build_store
      progress = progress_for(store, checkpoint_state)
      progress["schema"] = "other"
      FileUtils.mkdir_p(File.dirname(store.path(dir)))
      File.write(store.path(dir), JSON.generate(progress))

      error = assert_raises(Hive::Daemon::RefactorPatrolMergeProgressStore::Invalid) do
        store.load(dir)
      end

      assert_match(/unexpected reconciler progress schema/, error.message)
      refute_empty Dir.glob(
        File.join(dir, ".hive-state", "refactor_patrol", "v2", "quarantine", "reconciler-progress", "*.json")
      )
    end
  end

  def test_every_progress_identity_dimension_fails_closed
    store = build_store(dry_run: true)
    progress = progress_for(store, checkpoint_state)
    variants = [
      [ { registration: "other", host: "github.com", repository: "acme/demo", default_branch: "main" },
        /registration identity changed/ ],
      [ { registration: "demo", host: "github.example", repository: "acme/demo", default_branch: "main" },
        /repository host changed/ ],
      [ { registration: "demo", host: "github.com", repository: "acme/demo", default_branch: "trunk" },
        /default branch changed/ ]
    ]

    variants.each do |observed, message|
      error = assert_raises(Hive::Daemon::RefactorPatrolMergeProgressStore::Invalid) do
        store.assert_identity!(progress, project_root: "/tmp/demo", **observed)
      end
      assert_match message, error.message
    end
  end

  def test_structural_validation_rejects_every_unsafe_continuation_shape
    store = build_store
    base = progress_for(store, checkpoint_state)
    variants = [
      [],
      mutate(base) { |item| item["schema"] = "other" },
      mutate(base) { |item| item["schema_version"] = 2 },
      mutate(base) { |item| item.delete("updated_at") },
      mutate(base) { |item| item["registration"] = "" },
      mutate(base) { |item| item["registration"] = 123 },
      mutate(base) { |item| item["base_checkpoint_sha256"] = "bad" },
      mutate(base) { |item| item["base_checkpoint_sha256"] = 123 },
      mutate(base) { |item| item["updated_at"] = "later" },
      mutate(base) { |item| item["updated_at"] = 123 },
      mutate(base) { |item| item["scan"]["phase"] = "done" },
      mutate(base) { |item| item["scan"]["merged_since"] = "earlier" },
      mutate(base) { |item| item["scan"]["merged_since"] = 123 },
      mutate(base) { |item| item["scan"]["merged_until"] = (T0 + 1).iso8601 },
      mutate(base) { |item| item["scan"]["result_count"] = -1 },
      mutate(base) { |item| item["scan"]["cursor"] = "" },
      mutate(base) { |item| item["scan"]["cursor"] = 123 },
      mutate(base) { |item| item["scan"]["seen_cursors"] = [ "same", "same" ] },
      mutate(base) do |item|
        item["scan"]["cursor"] = "same"
        item["scan"]["seen_cursors"] = [ "same" ]
      end,
      mutate(base) { |item| item["scan"]["items"] = [ nil ] },
      mutate(base) { |item| item["scan"]["items"] = [ summary.merge("merged_at" => "later") ] },
      mutate(base) { |item| item["scan"]["items"] = [ summary.merge("merged_at" => 123) ] },
      mutate(base) { |item| item["scan"]["items"] = [ summary.merge("merge_sha" => 123) ] },
      mutate(base) { |item| item["scan"]["items"] = [ summary.merge("merge_sha" => "ABC") ] },
      mutate(base) { |item| item["scan"]["items"] = [ summary.merge("repository" => "other/repo") ] },
      mutate(base) { |item| item["scan"]["items"] = [ summary.merge("url" => "http://[") ] },
      mutate(base) do |item|
        item["scan"]["result_count"] = 0
        item["scan"]["items"] = [ summary ]
      end,
      mutate(base) { |item| item["scan"]["ingest_index"] = -1 },
      mutate(base) { |item| item["retry"] = { "failures" => 0, "not_before" => T0.iso8601, "last_error" => "x" } },
      mutate(base) { |item| item["retry"] = { "failures" => 1, "not_before" => "later", "last_error" => "x" } },
      mutate(base) { |item| item["retry"] = { "failures" => 1, "not_before" => 123, "last_error" => "x" } },
      mutate(base) { |item| item["retry"] = { "failures" => 1, "not_before" => T0.iso8601, "last_error" => 123 } }
    ]

    with_tmp_dir do |dir|
      variants.each do |invalid|
        assert_raises(Hive::Daemon::RefactorPatrolMergeProgressStore::Invalid) do
          store.write(dir, invalid)
        end
      end
    end
  end

  def test_wrong_typed_persisted_timestamps_are_quarantined
    with_tmp_dir do |dir|
      store = build_store
      base = progress_for(store, checkpoint_state)
      variants = [
        mutate(base) { |item| item["updated_at"] = 123 },
        mutate(base) { |item| item["scan"]["merged_since"] = 123 },
        mutate(base) { |item| item["scan"]["items"] = [ summary.merge("merged_at" => 123) ] },
        mutate(base) { |item| item["scan"]["items"] = [ summary.merge("merge_sha" => 123) ] },
        mutate(base) do |item|
          item["retry"] = { "failures" => 1, "not_before" => 123, "last_error" => "x" }
        end
      ]
      FileUtils.mkdir_p(File.dirname(store.path(dir)))

      variants.each do |invalid|
        File.write(store.path(dir), JSON.generate(invalid))
        assert_raises(Hive::Daemon::RefactorPatrolMergeProgressStore::Invalid) do
          store.load(dir)
        end
      end

      assert_equal 5, Dir.glob(
        File.join(
          dir, ".hive-state", "refactor_patrol", "v2", "quarantine",
          "reconciler-progress", "*.json"
        )
      ).length
    end
  end

  def test_dry_run_is_in_memory_and_invalid_backoff_configuration_fails_fast
    with_tmp_dir do |dir|
      store = build_store(dry_run: true)
      progress = progress_for(store, nil)
      store.write(dir, progress)

      assert_equal progress, store.load(dir)
      refute File.exist?(store.path(dir))
      store.clear(dir)
      assert_nil store.load(dir)
    end

    assert_raises(ArgumentError) { build_store(backoff_base_sec: 0) }
    assert_raises(ArgumentError) { build_store(backoff_base_sec: "bad") }
    assert_raises(ArgumentError) { build_store(backoff_base_sec: 10, backoff_max_sec: 5) }
  end

  private

  def build_store(**options)
    Hive::Daemon::RefactorPatrolMergeProgressStore.new(
      jitter: -> { 0.0 }, **options
    )
  end

  def progress_for(store, checkpoint)
    store.build(
      registration: "demo", host: "github.com", repository: "acme/demo",
      default_branch: "main", previous: checkpoint,
      merged_since: T0 - 3600, now: T0
    )
  end

  def checkpoint_state
    {
      "schema" => "hive-refactor-patrol-reconciler",
      "schema_version" => 2,
      "registration" => "demo",
      "host" => "github.com",
      "repository" => "acme/demo",
      "default_branch" => "main",
      "high_water" => nil,
      "overlap_occurrences" => [],
      "seeded_at" => T0.iso8601,
      "updated_at" => T0.iso8601
    }
  end

  def summary
    {
      "number" => 7,
      "url" => "https://github.com/acme/demo/pull/7",
      "repository" => "acme/demo",
      "base_branch" => "main",
      "merge_sha" => "a" * 40,
      "merged_at" => T0.iso8601
    }
  end

  def mutate(value)
    copy = Marshal.load(Marshal.dump(value))
    yield copy
    copy
  end
end
