require "test_helper"
require "hive/attempts/stream_log"

class AttemptsStreamLogTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 16, 12, 0, 0)

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

  def test_reader_ignores_malformed_frames_and_read_errors
    with_tmp_dir do |root|
      path = File.join(root, "bad.frames")
      File.write(path, "not-json\n")
      assert_empty Hive::Attempts::StreamLog.read(path)

      with_replaced_singleton_method(File, :binread, ->(_path) { raise Errno::EACCES }) do
        assert_empty Hive::Attempts::StreamLog.read(path)
      end
    end
  end
end
