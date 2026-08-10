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
end
