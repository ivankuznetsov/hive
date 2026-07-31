require "test_helper"
require "hive/attempts/stream_log"

class AttemptsStreamLogTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 16, 12, 0, 0)

  class ShortWriter
    attr_reader :bytes, :writes

    def initialize(limit:)
      @limit = limit
      @bytes = +"".b
      @writes = 0
      @closed = false
    end

    def syswrite(chunk)
      written = [ @limit, chunk.bytesize ].min
      @bytes << chunk.byteslice(0, written)
      @writes += 1
      written
    end

    def flush = true
    def fsync = true
    def close = @closed = true
    def closed? = @closed
  end

  def test_frames_preserve_sequence_channel_and_binary_bytes
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      log.append(:stdout, "hello\n")
      log.append(:stderr, "\xFFbad".b)
      log.close

      frames = Hive::Attempts::StreamLog.read(path)
      assert_equal [ 1, 2 ], frames.map(&:sequence)
      assert_equal %w[stdout stderr], frames.map(&:channel)
      assert_equal "hello\n", frames.first.bytes
      assert_equal "\xFFbad".b, frames.last.bytes
      assert_equal [ 2 ], Hive::Attempts::StreamLog.read(path, after_sequence: 1).map(&:sequence)
    end
  end

  def test_reader_ignores_partial_trailing_frame_and_reference_has_integrity
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      log.append(:stdout, "complete")
      log.close
      File.open(path, "ab") { |file| file.write('{"sequence":2') }

      assert_equal [ "complete" ], Hive::Attempts::StreamLog.read(path).map(&:bytes)
      reference = Hive::Attempts::OutputReference.build(path, root: root)
      assert Hive::Attempts::OutputReference.verify(reference, root: root)
    end
  end

  def test_append_retries_short_writes_until_the_frame_is_complete
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      log.instance_variable_get(:@io).close
      writer = ShortWriter.new(limit: 7)
      log.instance_variable_set(:@io, writer)

      assert_equal 1, log.append(:stdout, "complete-json-document")
      assert_operator writer.writes, :>, 1
      assert writer.bytes.end_with?("\n")
      File.binwrite(path, writer.bytes)
      assert_equal [ "complete-json-document" ], Hive::Attempts::StreamLog.read(path).map(&:bytes)
    ensure
      log&.close
    end
  end

  def test_reopen_after_torn_write_preserves_the_first_post_recovery_frame
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      log.append(:stdout, "a")
      log.close
      File.open(path, "ab") { |file| file.write('{"sequence":2,"timestamp":"2026-') }

      reopened = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      assert_equal 2, reopened.append(:stdout, "b")
      reopened.close

      frames = Hive::Attempts::StreamLog.read(path)
      assert_equal [ 1, 2 ], frames.map(&:sequence)
      assert_equal "b", frames.last.bytes
    end
  end

  def test_reopen_of_a_log_ending_at_a_frame_boundary_leaves_the_file_unchanged
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      log.append(:stdout, "a")
      log.close
      before = File.binread(path)

      Hive::Attempts::StreamLog.new(path, clock: -> { NOW }).close
      assert_equal before, File.binread(path)
    end
  end

  def test_reader_ignores_malformed_frames_and_read_errors
    with_tmp_dir do |root|
      path = File.join(root, "bad.frames")
      assert_empty Hive::Attempts::StreamLog.read(File.join(root, "missing.frames"))

      File.write(path, "not-json\n")
      assert_empty Hive::Attempts::StreamLog.read(path)

      with_replaced_singleton_method(File, :binread, ->(_path) { raise Errno::EACCES }) do
        assert_empty Hive::Attempts::StreamLog.read(path)
      end
    end
  end

  def test_symlinked_log_directories_and_files_fail_closed_without_external_access
    with_tmp_dir do |root|
      outside = File.join(root, "outside")
      FileUtils.mkdir_p(outside)
      File.chmod(0o755, outside)
      File.symlink(outside, File.join(root, "logs"))

      error = assert_raises(IOError) do
        Hive::Attempts::StreamLog.new(File.join(root, "logs", "attempt.frames"))
      end

      assert_match(/directory.*symlink/, error.message)
      assert_equal 0o755, File.stat(outside).mode & 0o777
      assert_empty Dir.children(outside)
    end

    with_tmp_dir do |root|
      logs = File.join(root, "logs")
      outside = File.join(root, "outside.frames")
      FileUtils.mkdir_p(logs)
      File.binwrite(outside, "{\"sequence\":1,\"timestamp\":\"external\",\"channel\":\"stdout\",\"data\":\"bGVhaw==\"}\n")
      File.chmod(0o644, outside)
      path = File.join(logs, "attempt.frames")
      File.symlink(outside, path)

      error = assert_raises(IOError) { Hive::Attempts::StreamLog.new(path) }
      assert_match(/path.*symlink/, error.message)
      assert_empty Hive::Attempts::StreamLog.read(path)
      assert_equal 0o644, File.stat(outside).mode & 0o777
      assert_match(/bGVhaw==/, File.binread(outside))
    end
  end
end
