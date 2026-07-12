require "test_helper"
require "hive/atomic_file"

class HiveAtomicFileTest < Minitest::Test
  include HiveTestHelper

  def test_write_creates_parent_dirs_sets_mode_and_returns_path
    with_tmp_dir do |dir|
      path = File.join(dir, "nested", "state.json")

      returned = Hive::AtomicFile.write(path, "{\"a\":1}\n", mode: 0o600)

      assert_equal path, returned
      assert_equal "{\"a\":1}\n", File.read(path)
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_empty Dir.glob(File.join(dir, "nested", ".*tmp*")),
                   "no tempfile may remain after a successful write"
    end
  end

  def test_write_replaces_existing_content_atomically
    with_tmp_dir do |dir|
      path = File.join(dir, "state.json")
      Hive::AtomicFile.write(path, "old")

      Hive::AtomicFile.write(path, "new", fsync: false)

      assert_equal "new", File.read(path)
    end
  end

  def test_failed_rename_leaves_target_untouched_and_cleans_tempfile
    with_tmp_dir do |dir|
      path = File.join(dir, "state.json")
      Hive::AtomicFile.write(path, "old")

      with_replaced_singleton_method(File, :rename, ->(*_args) { raise Errno::EACCES, "locked" }) do
        assert_raises(Errno::EACCES) { Hive::AtomicFile.write(path, "new") }
      end

      assert_equal "old", File.read(path), "a failed rename must leave the previous content intact"
      assert_empty Dir.glob(File.join(dir, ".*tmp*")),
                   "the ensure block must remove the orphaned tempfile"
    end
  end

  def test_fsync_directory_flushes_and_tolerates_unsupported_platforms
    with_tmp_dir do |dir|
      assert_equal 0, Hive::AtomicFile.fsync_directory(dir)

      [ NotImplementedError.new("unsupported"), Errno::EINVAL.new(dir) ].each do |error|
        with_replaced_singleton_method(File, :open, ->(*) { raise error }) do
          assert_nil Hive::AtomicFile.fsync_directory(dir)
        end
      end
    end
  end
end
