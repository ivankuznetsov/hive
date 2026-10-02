require "test_helper"
require "hive/attempts/stream_log"

class AttemptsStreamLogTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 16, 12, 0, 0)

  class FileWriter
    attr_accessor :flush_error
    attr_reader :writes

    def initialize(io, limit: nil, separator_outcome: nil, frame_prefix_before_error: nil,
                   unlock_result: true, close_error: nil, error: Errno::EINTR.new)
      @io = io
      @limit = limit
      @separator_outcome = separator_outcome
      @frame_prefix_before_error = frame_prefix_before_error
      @unlock_result = unlock_result
      @close_error = close_error
      @error = error
      @writes = []
      @separator_flush_pending = false
    end

    def syswrite(chunk)
      @writes << chunk.dup
      outcome = chunk == "#\n".b ? @separator_outcome : nil
      @separator_outcome = nil if outcome && outcome != :flush_error
      case outcome
      when :write_error
        raise @error
      when :sentinel_then_error
        @io.syswrite("#".b)
        raise @error
      when :separator_then_error
        @io.syswrite("#\n".b)
        raise @error
      when :flush_error
        @separator_flush_pending = true
      end

      if chunk.start_with?("{".b) && @frame_prefix_before_error
        prefix = @frame_prefix_before_error
        @frame_prefix_before_error = nil
        @io.syswrite(chunk.byteslice(0, prefix))
        raise @error
      end

      written = @limit ? [ @limit, chunk.bytesize ].min : chunk.bytesize
      @io.syswrite(chunk.byteslice(0, written))
    end

    def flush
      if @flush_error
        error = @flush_error
        @flush_error = nil
        raise error
      end

      if @separator_flush_pending
        @separator_flush_pending = false
        @separator_outcome = nil
        raise @error
      end

      @io.flush
    end

    def flock(operation)
      if operation == File::LOCK_UN && @unlock_result != true
        result = @unlock_result
        @unlock_result = true
        return result
      end

      @io.flock(operation)
    end

    def stat = @io.stat
    def fsync = @io.fsync

    def close
      @io.close
      raise @close_error if @close_error
    end

    def closed? = @io.closed?
  end

  class ReadFile
    attr_accessor :error, :short_read
    attr_reader :full_reads

    def initialize(io, error: nil, short_read: nil, close_error: nil)
      @io = io
      @error = error
      @short_read = short_read
      @close_error = close_error
      @full_reads = 0
    end

    def pread(length, offset)
      return "".b if @short_read == :tail && length == 1
      return "".b if @short_read == :full && offset.zero? && length > 1

      if offset.zero? && length > 1
        @full_reads += 1
        raise @error if @error
      end

      @io.pread(length, offset)
    end

    def stat = @io.stat

    def close
      @io.close
      raise @close_error if @close_error
    end

    def closed? = @io.closed?
  end

  class CustodyFile
    attr_reader :flocks

    def initialize(unlock_error: nil, close_error: nil)
      @unlock_error = unlock_error
      @close_error = close_error
      @closed = false
      @flocks = []
    end

    def flock(operation)
      @flocks << operation
      raise @unlock_error if operation == File::LOCK_UN && @unlock_error

      true
    end

    def close
      @closed = true
      raise @close_error if @close_error
    end

    def closed? = @closed
  end

  class GatedWriter < FileWriter
    def initialize(io, entered:, release:)
      super(io)
      @entered = entered
      @release = release
      @gated = false
    end

    def syswrite(chunk)
      if chunk.start_with?("{".b) && !@gated
        @gated = true
        @entered << true
        @release.pop
      end

      super
    end
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
      reference = Hive::OutputReference.build(path, root: root)
      assert Hive::OutputReference.verify(reference, root: root)
    end
  end

  def test_append_retries_short_writes_until_the_frame_is_complete
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      writer = FileWriter.new(log.instance_variable_get(:@io), limit: 7)
      log.instance_variable_set(:@io, writer)

      assert_equal 1, log.append(:stdout, "complete-json-document")
      assert_operator writer.writes.length, :>, 1
      assert File.binread(path).end_with?("\n")
      assert_equal [ "complete-json-document" ], Hive::Attempts::StreamLog.read(path).map(&:bytes)
    ensure
      log&.close
    end
  end

  def test_separator_write_error_fails_before_frame_allocation_and_same_instance_retry_recovers
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      log.append(:stdout, "published")
      torn = '{"sequence":2'
      File.open(path, "ab") { |file| file.write(torn) }
      before = File.binread(path)
      error = Errno::EINTR.new("separator")
      writer = FileWriter.new(
        log.instance_variable_get(:@io), separator_outcome: :write_error, error: error
      )
      log.instance_variable_set(:@io, writer)

      raised = assert_raises(Errno::EINTR) { log.append(:stdout, "recovered") }
      assert_same error, raised
      assert_equal [ "#\n".b ], writer.writes
      assert_equal before, File.binread(path)
      assert_equal [ 1 ], Hive::Attempts::StreamLog.read(path).map(&:sequence)

      assert_equal 2, log.append(:stdout, "recovered")
      assert_equal [ 1, 2 ], Hive::Attempts::StreamLog.read(path).map(&:sequence)
      assert_equal [ "published", "recovered" ], Hive::Attempts::StreamLog.read(path).map(&:bytes)
    ensure
      log&.close
    end
  end

  def test_same_instance_retries_use_physical_separator_outcomes
    {
      sentinel_then_error: "#",
      separator_then_error: "#\n",
      flush_error: "#\n"
    }.each do |outcome, physical_suffix|
      with_tmp_dir do |root|
        path = File.join(root, "logs", "#{outcome}.frames")
        log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
        log.append(:stdout, "published")
        torn = '{"sequence":2'
        File.open(path, "ab") { |file| file.write(torn) }
        damaged_prefix = File.binread(path)
        error = Errno::EINTR.new(outcome.to_s)
        writer = FileWriter.new(
          log.instance_variable_get(:@io), separator_outcome: outcome, error: error
        )
        log.instance_variable_set(:@io, writer)

        raised = assert_raises(Errno::EINTR) { log.append(:stdout, "failed") }
        assert_same error, raised
        assert_equal damaged_prefix + physical_suffix, File.binread(path)
        assert_equal [ 1 ], Hive::Attempts::StreamLog.read(path).map(&:sequence)

        assert_equal 2, log.append(:stdout, "recovered")
        frames = Hive::Attempts::StreamLog.read(path)
        assert_equal [ 1, 2 ], frames.map(&:sequence)
        assert_equal [ "published", "recovered" ], frames.map(&:bytes)
      ensure
        log&.close
      end
    end
  end

  def test_reopen_retries_use_physical_separator_outcomes
    {
      write_error: "",
      sentinel_then_error: "#",
      separator_then_error: "#\n"
    }.each do |outcome, physical_suffix|
      with_tmp_dir do |root|
        path = File.join(root, "logs", "#{outcome}.frames")
        log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
        log.append(:stdout, "published")
        torn = '{"sequence":2'
        File.open(path, "ab") { |file| file.write(torn) }
        damaged_prefix = File.binread(path)
        writer = FileWriter.new(log.instance_variable_get(:@io), separator_outcome: outcome)
        log.instance_variable_set(:@io, writer)

        assert_raises(Errno::EINTR) { log.append(:stdout, "failed") }
        assert_equal damaged_prefix + physical_suffix, File.binread(path)
        log.close

        reopened = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
        assert_equal damaged_prefix + physical_suffix, File.binread(path)
        assert_equal 2, reopened.append(:stdout, "recovered")
        reopened.close

        frames = Hive::Attempts::StreamLog.read(path)
        assert_equal [ 1, 2 ], frames.map(&:sequence)
        assert_equal [ "published", "recovered" ], frames.map(&:bytes)
      ensure
        reopened&.close unless reopened&.closed?
        log&.close unless log&.closed?
      end
    end
  end

  def test_short_separator_writes_complete_before_the_frame_is_written
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      log.append(:stdout, "published")
      File.open(path, "ab") { |file| file.write("torn") }
      damaged_prefix = File.binread(path)
      writer = FileWriter.new(log.instance_variable_get(:@io), limit: 1)
      log.instance_variable_set(:@io, writer)

      assert_equal 2, log.append(:stdout, "recovered")
      assert_equal [ "#\n".b, "\n".b ], writer.writes.first(2)
      assert File.binread(path).start_with?(damaged_prefix + "#\n")
      assert_equal [ "published", "recovered" ], Hive::Attempts::StreamLog.read(path).map(&:bytes)
    ensure
      log&.close
    end
  end

  def test_initialization_does_not_mutate_a_torn_tail
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      first = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      first.append(:stdout, "published")
      first.close
      File.open(path, "ab") { |file| file.write("torn bytes") }
      before = File.binread(path)

      reopened = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      assert_equal before, File.binread(path)
      assert_equal 2, reopened.append(:stdout, "recovered")
      assert File.binread(path).start_with?(before + "#\n")
    ensure
      reopened&.close
    end
  end

  def test_retry_after_mid_frame_failure_invalidates_the_torn_frame
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      log.append(:stdout, "published")
      error = IOError.new("mid-frame")
      writer = FileWriter.new(
        log.instance_variable_get(:@io), frame_prefix_before_error: 20, error: error
      )
      log.instance_variable_set(:@io, writer)

      raised = assert_raises(IOError) { log.append(:stdout, "not published") }
      assert_same error, raised
      assert_equal [ 1 ], Hive::Attempts::StreamLog.read(path).map(&:sequence)

      assert_equal 2, log.append(:stdout, "recovered")
      frames = Hive::Attempts::StreamLog.read(path)
      assert_equal [ 1, 2 ], frames.map(&:sequence)
      assert_equal [ "published", "recovered" ], frames.map(&:bytes)
    ensure
      log&.close
    end
  end

  def test_newline_terminated_malformed_record_is_not_rewritten
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      first = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      first.append(:stdout, "published")
      first.close
      File.open(path, "ab") { |file| file.write("not-json\n") }
      before = File.binread(path)

      reopened = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      assert_equal before, File.binread(path)
      assert_equal 2, reopened.append(:stdout, "next")
      assert File.binread(path).start_with?(before)
      assert_equal [ 1, 2 ], Hive::Attempts::StreamLog.read(path).map(&:sequence)
    ensure
      reopened&.close
    end
  end

  def test_valid_json_without_newline_stays_unreadable_after_recovery
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      first = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      first.append(:stdout, "published")
      first.close
      unconfirmed = serialized_frame(sequence: 2, bytes: "unconfirmed").delete_suffix("\n")
      File.open(path, "ab") { |file| file.write(unconfirmed) }

      reopened = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      assert_equal 2, reopened.append(:stdout, "confirmed")
      reopened.close

      assert_includes File.binread(path), "#{unconfirmed}#\n"
      frames = Hive::Attempts::StreamLog.read(path)
      assert_equal [ 1, 2 ], frames.map(&:sequence)
      assert_equal [ "published", "confirmed" ], frames.map(&:bytes)
    end
  end

  def test_strict_reconciliation_errors_do_not_reset_the_sequence
    [ Errno::EACCES.new("strict read"), IOError.new("strict read") ].each do |error|
      with_tmp_dir do |root|
        path = File.join(root, "logs", "#{error.class.name.split('::').last}.frames")
        log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
        log.append(:stdout, "one")
        read_file = ReadFile.new(log.instance_variable_get(:@read_io), error: error)
        log.instance_variable_set(:@read_io, read_file)
        other = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
        assert_equal 2, other.append(:stdout, "two")
        other.close

        raised = assert_raises(error.class) { log.append(:stdout, "blocked") }
        assert_same error, raised
        assert_equal [ 1, 2 ], Hive::Attempts::StreamLog.read(path).map(&:sequence)

        read_file.error = nil
        assert_equal 3, log.append(:stdout, "three")
        assert_equal [ 1, 2, 3 ], Hive::Attempts::StreamLog.read(path).map(&:sequence)
      ensure
        other&.close unless other&.closed?
        log&.close unless log&.closed?
      end
    end
  end

  def test_reported_boundary_short_reads_fail_closed_and_allow_retry
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      log.append(:stdout, "one")
      read_file = ReadFile.new(log.instance_variable_get(:@read_io), short_read: :tail)
      log.instance_variable_set(:@read_io, read_file)

      error = assert_raises(IOError) { log.append(:stdout, "blocked") }
      assert_match(/reported boundary/, error.message)
      read_file.short_read = nil
      assert_equal 2, log.append(:stdout, "two")

      other = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      assert_equal 3, other.append(:stdout, "three")
      other.close
      read_file.short_read = :full
      error = assert_raises(IOError) { log.append(:stdout, "blocked again") }
      assert_match(/reported boundary/, error.message)
      read_file.short_read = nil
      assert_equal 4, log.append(:stdout, "four")
      assert_equal [ 1, 2, 3, 4 ], Hive::Attempts::StreamLog.read(path).map(&:sequence)
    ensure
      other&.close unless other&.closed?
      log&.close unless log&.closed?
    end
  end

  def test_lock_release_failure_invalidates_the_snapshot_for_retry
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      writer = FileWriter.new(log.instance_variable_get(:@io), unlock_result: false)
      log.instance_variable_set(:@io, writer)

      error = assert_raises(IOError) { log.append(:stdout, "physically published") }
      assert_match(/lock could not be released/, error.message)
      assert_equal [ 1 ], Hive::Attempts::StreamLog.read(path).map(&:sequence)
      assert_equal 2, log.append(:stdout, "retry")
      assert_equal [ 1, 2 ], Hive::Attempts::StreamLog.read(path).map(&:sequence)
    ensure
      log&.close
    end
  end

  def test_lock_release_failure_does_not_mask_the_separator_error
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      File.open(path, "ab") { |file| file.write("torn") }
      error = Errno::EINTR.new("separator")
      writer = FileWriter.new(
        log.instance_variable_get(:@io), separator_outcome: :write_error,
        unlock_result: false, error: error
      )
      log.instance_variable_set(:@io, writer)

      raised = assert_raises(Errno::EINTR) { log.append(:stdout, "blocked") }
      assert_same error, raised
      assert_equal 1, log.append(:stdout, "recovered")
    ensure
      log&.close
    end
  end

  def test_shared_instance_append_calls_are_serialized
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      entered = Queue.new
      release = Queue.new
      results = Queue.new
      writer = GatedWriter.new(log.instance_variable_get(:@io), entered: entered, release: release)
      log.instance_variable_set(:@io, writer)
      first = Thread.new { results << log.append(:stdout, "first") }
      Timeout.timeout(2) { entered.pop }
      second_started = Queue.new
      second = Thread.new do
        second_started << true
        results << log.append(:stdout, "second")
      end
      Timeout.timeout(2) { second_started.pop }
      assert_raises(Timeout::Error) { Timeout.timeout(0.05) { results.pop } }

      release << true
      Timeout.timeout(2) { first.value }
      Timeout.timeout(2) { second.value }
      assert_equal [ 1, 2 ], [ results.pop, results.pop ].sort
      assert_equal %w[first second], Hive::Attempts::StreamLog.read(path).map(&:bytes)
    ensure
      release << true if release
      first&.join(0.1)
      second&.join(0.1)
      log&.close
    end
  end

  def test_constructor_strict_read_failure_closes_both_descriptors_and_releases_lock
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      seed = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      seed.append(:stdout, "published")
      seed.close
      original_open = File.method(:open)
      opened = []
      error = IOError.new("strict read failed")
      replacement = lambda do |candidate, *args, **kwargs, &block|
        io = original_open.call(candidate, *args, **kwargs, &block)
        next io unless candidate == path && args.first.is_a?(Integer)

        if (args.first & File::WRONLY) == File::WRONLY
          opened << io
          io
        else
          reader = ReadFile.new(io, error: error, close_error: IOError.new("close failed"))
          opened << reader
          reader
        end
      end

      with_replaced_singleton_method(File, :open, replacement) do
        raised = assert_raises(IOError) { Hive::Attempts::StreamLog.new(path) }
        assert_same error, raised
      end
      assert_equal 2, opened.length
      assert opened.all?(&:closed?)
      Timeout.timeout(2) { Hive::Attempts::StreamLog.new(path).close }
    end
  end

  def test_constructor_rejects_descriptors_for_different_inodes_and_closes_them
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      other_path = File.join(root, "other.frames")
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, "")
      File.binwrite(other_path, "")
      original_open = File.method(:open)
      opened = []
      replacement = lambda do |candidate, *args, **kwargs, &block|
        if candidate == path && args.first.is_a?(Integer) &&
           (args.first & File::WRONLY) != File::WRONLY
          io = original_open.call(other_path, *args, **kwargs, &block)
        else
          io = original_open.call(candidate, *args, **kwargs, &block)
        end
        opened << io if candidate == path && args.first.is_a?(Integer)
        io
      end

      with_replaced_singleton_method(File, :open, replacement) do
        error = assert_raises(IOError) { Hive::Attempts::StreamLog.new(path) }
        assert_match(/same regular file/, error.message)
      end
      assert_equal 2, opened.length
      assert opened.all?(&:closed?)
    end
  end

  def test_close_releases_custody_and_preserves_cleanup_errors
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      custody = CustodyFile.new
      log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW }, custody_io: custody)
      log.append(:stdout, "published")
      log.close
      assert_equal [ File::LOCK_UN ], custody.flocks
      assert custody.closed?

      sync_log = Hive::Attempts::StreamLog.new(File.join(root, "sync.frames"), clock: -> { NOW })
      sync_error = IOError.new("flush failed")
      sync_writer = FileWriter.new(sync_log.instance_variable_get(:@io))
      sync_writer.flush_error = sync_error
      sync_log.instance_variable_set(:@io, sync_writer)
      assert_same sync_error, assert_raises(IOError) { sync_log.close }
      assert sync_log.closed?

      close_log = Hive::Attempts::StreamLog.new(File.join(root, "close.frames"), clock: -> { NOW })
      close_error = IOError.new("descriptor close failed")
      close_writer = FileWriter.new(close_log.instance_variable_get(:@io), close_error: close_error)
      close_log.instance_variable_set(:@io, close_writer)
      assert_same close_error, assert_raises(IOError) { close_log.close }
      assert close_log.closed?

      unlock_error = IOError.new("custody unlock failed")
      custody_close_error = IOError.new("custody close failed")
      failing_custody = CustodyFile.new(
        unlock_error: unlock_error, close_error: custody_close_error
      )
      custody_log = Hive::Attempts::StreamLog.new(
        File.join(root, "custody.frames"), clock: -> { NOW }, custody_io: failing_custody
      )
      assert_same unlock_error, assert_raises(IOError) { custody_log.close }
      assert failing_custody.closed?
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

      reopened = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      assert_equal before, File.binread(path)
      assert_equal 2, reopened.append(:stdout, "b")
      assert File.binread(path).start_with?(before + "{")
      refute_includes File.binread(path).byteslice(before.bytesize, 2), "#"
      reopened.close
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

  def test_reader_ignores_non_directory_and_symlink_loop_parents
    with_tmp_dir do |root|
      not_directory = File.join(root, "not-directory")
      File.write(not_directory, "operator data\n")

      assert_empty Hive::Attempts::StreamLog.read(
        File.join(not_directory, "attempt.frames")
      )

      loop_path = File.join(root, "loop")
      File.symlink("loop", loop_path)
      assert_empty Hive::Attempts::StreamLog.read(
        File.join(loop_path, "attempt.frames")
      )
    end
  end

  def test_open_race_that_surfaces_eloop_is_reported_as_a_symlink
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      original_open = File.method(:open)
      with_replaced_singleton_method(File, :open, lambda { |candidate, *args, **kwargs, &block|
        raise Errno::ELOOP, candidate if candidate == path

        original_open.call(candidate, *args, **kwargs, &block)
      }) do
        error = assert_raises(IOError) { Hive::Attempts::StreamLog.new(path) }
        assert_match(/path is a symlink/, error.message)
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

  private

  def serialized_frame(sequence:, bytes:)
    JSON.generate(
      "sequence" => sequence,
      "timestamp" => NOW.iso8601(6),
      "channel" => "stdout",
      "data" => Base64.strict_encode64(bytes)
    ) + "\n"
  end
end
