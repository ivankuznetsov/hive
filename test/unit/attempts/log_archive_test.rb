require "test_helper"
require "hive/attempts/log_archive"

class AttemptsLogArchiveTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 8, 10, 12, 0, 0)

  def test_active_writer_and_reader_custody_block_maintenance
    with_tmp_dir do |root|
      store = Hive::Attempts::Store.new(root: root)
      archive = store.log_archive
      writer = archive.open_writer("attempt-1", clock: -> { NOW })
      writer.append(:stdout, "open\n")

      assert_equal :busy, archive.archive("attempt-1")
      assert File.file?(archive.hot_path("attempt-1"))
      refute File.exist?(archive.cold_path("attempt-1"))

      writer.close
      reader_entered = Queue.new
      release_reader = Queue.new
      reader = Thread.new do
        archive.with_reader("attempt-1") do |_path, availability|
          reader_entered << availability
          release_reader.pop
        end
      end
      assert_equal :available, reader_entered.pop
      assert_equal :busy, archive.archive("attempt-1")
      release_reader << true
      reader.join

      assert_equal :archived, archive.archive("attempt-1")
      assert File.file?(archive.cold_path("attempt-1"))
      assert_equal [ "open\n" ], archive.read("attempt-1").frames.map(&:bytes)
    ensure
      writer&.close unless writer&.closed?
      release_reader << true if reader&.alive?
      reader&.join
    end
  end

  def test_expiry_is_point_addressed_and_hot_wins_over_an_expiry_tombstone
    with_tmp_dir do |root|
      store = Hive::Attempts::Store.new(root: root)
      archive = store.log_archive
      writer = archive.open_writer("attempt-1", clock: -> { NOW })
      writer.append(:stdout, "done\n")
      writer.close
      assert_equal :archived, archive.archive("attempt-1")

      assert_equal :expired, archive.expire("attempt-1", now: NOW + 1)
      assert_equal :expired, archive.resolve("attempt-1").availability
      assert_empty archive.read("attempt-1").frames

      replacement = archive.open_writer("attempt-1", clock: -> { NOW + 2 })
      replacement.append(:stdout, "hot\n")
      replacement.close
      resolved = archive.resolve("attempt-1")
      assert_equal :available, resolved.availability
      assert_equal archive.hot_path("attempt-1"), resolved.path
    end
  end

  def test_cold_pages_are_sharded_bounded_and_resume_from_the_cursor
    with_tmp_dir do |root|
      store = Hive::Attempts::Store.new(root: root)
      archive = store.log_archive
      %w[attempt-1 attempt-2 attempt-3].each do |attempt_id|
        writer = archive.open_writer(attempt_id, clock: -> { NOW })
        writer.append(:stdout, "done\n")
        writer.close
        assert_equal :archived, archive.archive(attempt_id)
        assert_equal Digest::SHA256.hexdigest(attempt_id)[0, 2],
                     File.basename(File.dirname(archive.cold_path(attempt_id)))
      end

      first = archive.cold_attempt_ids_page(
        cursor: { "shard" => 0, "after" => nil }, limit: 2
      )
      second = archive.cold_attempt_ids_page(cursor: first.cursor, limit: 2)

      assert_equal 2, first.attempt_ids.size
      assert_equal 2, second.attempt_ids.size
      assert_empty(%w[attempt-1 attempt-2 attempt-3] -
                   (first.attempt_ids + second.attempt_ids))
    end
  end

  def test_writer_setup_failure_releases_custody_for_later_maintenance
    with_tmp_dir do |root|
      store = Hive::Attempts::Store.new(root: root)
      archive = store.log_archive
      logs_root = store.logs_root
      FileUtils.rm_rf(logs_root)
      File.write(logs_root, "not a directory")

      assert_raises(Hive::Attempts::StoreError) do
        archive.open_writer("attempt-1", clock: -> { NOW })
      end

      FileUtils.rm_f(logs_root)
      FileUtils.mkdir_p(logs_root)
      assert_equal :missing, archive.archive("attempt-1")
    end
  end

  def test_duplicate_hot_and_cold_logs_must_match_before_hot_is_removed
    with_tmp_dir do |root|
      store = Hive::Attempts::Store.new(root: root)
      archive = store.log_archive
      write_log(archive, "attempt-1", "original\n")
      assert_equal :archived, archive.archive("attempt-1")

      write_log(archive, "attempt-1", "conflict\n")
      error = assert_raises(Hive::Attempts::StoreError) do
        archive.archive("attempt-1")
      end
      assert_match(/hot and cold logs conflict/, error.message)
      assert File.file?(archive.hot_path("attempt-1"))
      assert File.file?(archive.cold_path("attempt-1"))

      File.unlink(archive.hot_path("attempt-1"))
      write_log(archive, "attempt-1", "original\n")
      assert_equal :archived, archive.archive("attempt-1")
      refute File.exist?(archive.hot_path("attempt-1"))
      assert_equal [ "original\n" ], archive.read("attempt-1").frames.map(&:bytes)
    end
  end

  def test_cold_page_validation_translates_invalid_inputs_and_filesystem_failures
    with_tmp_dir do |root|
      store = Hive::Attempts::Store.new(root: root)
      archive = store.log_archive

      error = assert_raises(Hive::Attempts::StoreError) do
        archive.cold_attempt_ids_page(cursor: { "shard" => 0, "after" => nil }, limit: "many")
      end
      assert_match(/page limit is invalid/, error.message)

      error = assert_raises(Hive::Attempts::StoreError) do
        archive.cold_attempt_ids_page(cursor: {}, limit: 1)
      end
      assert_match(/cursor is invalid/, error.message)

      shard = File.join(store.cold_logs_root, "00")
      FileUtils.mkdir_p(shard)
      original_children = Dir.method(:children)
      with_replaced_singleton_method(
        Dir, :children,
        ->(path) { path == shard ? raise(Errno::EIO) : original_children.call(path) }
      ) do
        error = assert_raises(Hive::Attempts::StoreError) do
          archive.cold_attempt_ids_page(
            cursor: { "shard" => 0, "after" => nil }, limit: 1
          )
        end
        assert_match(/archive is unavailable/, error.message)
      end
    end
  end

  def test_archive_reuses_a_safe_existing_shard_and_rejects_a_symlinked_one
    with_tmp_dir do |root|
      store = Hive::Attempts::Store.new(root: File.join(root, "safe"))
      archive = store.log_archive
      shard = File.dirname(archive.cold_path("attempt-1"))
      FileUtils.mkdir_p(shard)
      File.chmod(0o755, shard)
      write_log(archive, "attempt-1", "done\n")

      assert_equal :archived, archive.archive("attempt-1")
      assert_equal 0o700, File.stat(shard).mode & 0o777

      unsafe_store = Hive::Attempts::Store.new(root: File.join(root, "unsafe"))
      unsafe_archive = unsafe_store.log_archive
      unsafe_shard = File.dirname(unsafe_archive.cold_path("attempt-2"))
      outside = File.join(root, "outside")
      FileUtils.mkdir_p(outside)
      File.symlink(outside, unsafe_shard)
      write_log(unsafe_archive, "attempt-2", "done\n")

      error = assert_raises(Hive::Attempts::StoreError) do
        unsafe_archive.archive("attempt-2")
      end
      assert_match(/cold log shard is unsafe/, error.message)
      assert File.file?(unsafe_archive.hot_path("attempt-2"))
      assert_empty Dir.children(outside)
    end
  end

  def test_cold_page_rejects_unsafe_shards_and_skips_malformed_entries
    with_tmp_dir do |root|
      unsafe_store = Hive::Attempts::Store.new(root: File.join(root, "unsafe"))
      unsafe_archive = unsafe_store.log_archive
      outside = File.join(root, "outside")
      FileUtils.mkdir_p(outside)
      File.symlink(outside, File.join(unsafe_store.cold_logs_root, "00"))

      error = assert_raises(Hive::Attempts::StoreError) do
        unsafe_archive.cold_attempt_ids_page(
          cursor: { "shard" => 0, "after" => nil }, limit: 1
        )
      end
      assert_match(/cold log shard is unsafe/, error.message)

      malformed_store = Hive::Attempts::Store.new(root: File.join(root, "malformed"))
      malformed_archive = malformed_store.log_archive
      shard = File.join(malformed_store.cold_logs_root, "00")
      FileUtils.mkdir_p(shard)
      File.write(File.join(shard, "bad name.frames"), "ignored")

      page = malformed_archive.cold_attempt_ids_page(
        cursor: { "shard" => 0, "after" => nil }, limit: 1
      )
      assert_empty page.attempt_ids
    end
  end

  def test_custody_lock_rejects_symlinks_and_inode_replacement_without_leaking_the_lock
    with_tmp_dir do |root|
      symlink_store = Hive::Attempts::Store.new(root: File.join(root, "symlink"))
      symlink_archive = symlink_store.log_archive
      symlink_path = custody_lock_path(symlink_store, "attempt-1")
      outside = File.join(root, "outside.lock")
      File.write(outside, "")
      File.symlink(outside, symlink_path)

      error = assert_raises(Hive::Attempts::StoreError) do
        symlink_archive.resolve("attempt-1")
      end
      assert_match(/custody lock is a symlink/, error.message)

      race_store = Hive::Attempts::Store.new(root: File.join(root, "race"))
      race_archive = race_store.log_archive
      lock_path = custody_lock_path(race_store, "attempt-2")
      replacement = File.join(root, "replacement.lock")
      File.write(replacement, "")
      original_lstat = File.method(:lstat)
      with_replaced_singleton_method(
        File, :lstat,
        ->(path) { path == lock_path ? original_lstat.call(replacement) : original_lstat.call(path) }
      ) do
        error = assert_raises(Hive::Attempts::StoreError) do
          race_archive.resolve("attempt-2")
        end
        assert_match(/custody lock is unsafe/, error.message)
      end

      assert_equal :missing, race_archive.archive("attempt-2")
    end
  end

  def test_corrupt_expiry_state_and_unsafe_attempt_ids_fail_closed
    with_tmp_dir do |root|
      store = Hive::Attempts::Store.new(root: root)
      archive = store.log_archive
      assert_equal :expired, archive.expire("attempt-1", now: NOW)
      state_path = Dir.glob(File.join(store.log_state_root, "**", "*"))
                      .find { |path| File.file?(path) }
      refute_nil state_path
      File.write(state_path, "{")

      error = assert_raises(Hive::Attempts::StoreError) do
        archive.resolve("attempt-1")
      end
      assert_match(/state is corrupt or colliding/, error.message)

      error = assert_raises(Hive::Attempts::StoreError) { archive.resolve("../escape") }
      assert_match(/unsafe attempt id/, error.message)
    end
  end

  private

  def write_log(archive, attempt_id, bytes)
    writer = archive.open_writer(attempt_id, clock: -> { NOW })
    writer.append(:stdout, bytes)
    writer.close
  end

  def custody_lock_path(store, attempt_id)
    digest = Digest::SHA256.hexdigest(attempt_id)
    shard = digest[0, 2].to_i(16) % Hive::Attempts::LogArchive::CUSTODY_LOCK_SHARDS
    File.join(store.generation_locks_root, format("log-custody-%02x.lock", shard))
  end
end
