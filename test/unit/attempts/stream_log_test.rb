require "test_helper"
require "hive/attempts/stream_log"
require_relative "../../support/stream_log_test_support"

class AttemptsStreamLogTest < Minitest::Test
  include HiveTestHelper
  include StreamLogTestSupport

  NOW = Time.utc(2026, 7, 16, 12, 0, 0)

  class FileWriter < StreamLogTestSupport::DelegatingIO
    attr_accessor :flush_error
    attr_reader :writes

    def initialize(io, limit: nil, separator_outcome: nil, frame_prefix_before_error: nil,
                   lock_error: nil, unlock_error: nil, close_error: nil,
                   error: Errno::EINTR.new)
      super(io)
      @limit = limit
      @separator_outcome = separator_outcome
      @frame_prefix_before_error = frame_prefix_before_error
      @lock_error = lock_error
      @unlock_error = unlock_error
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
      raise @lock_error if operation & File::LOCK_EX != 0 && @lock_error
      if operation == File::LOCK_UN && @unlock_error
        error = @unlock_error
        @unlock_error = nil
        raise error
      end

      super
    end

    def close
      @io.close
      raise @close_error if @close_error
    end

    def closed? = @io.closed?
  end

  class ReadFile < StreamLogTestSupport::DelegatingIO
    attr_accessor :error
    attr_reader :full_reads, :pread_calls, :bytes_requested

    def initialize(io, error: nil, close_error: nil)
      super(io)
      @error = error
      @close_error = close_error
      @full_reads = 0
      @pread_calls = 0
      @bytes_requested = 0
    end

    def pread(length, offset)
      @pread_calls += 1
      @bytes_requested += length
      if offset.zero? && length > 1
        @full_reads += 1
        raise @error if @error
      end

      super
    end

    def close
      @io.close
      raise @close_error if @close_error
    end

    def closed? = @io.closed?
  end

  class TruncatingReadFile < StreamLogTestSupport::DelegatingIO
    def initialize(io, path:, truncate_to:, trigger:)
      super(io)
      @path = path
      @truncate_to = truncate_to
      @trigger = trigger
      @truncated = false
    end

    def pread(length, offset)
      if !@truncated && @trigger.call(length, offset)
        @truncated = true
        File.truncate(@path, @truncate_to)
      end
      super
    end
  end

  class InterruptingLockWriter < StreamLogTestSupport::DelegatingIO
    attr_reader :unlock_attempts

    def initialize(io, interrupt:, unlock_error:)
      super(io)
      @interrupt = interrupt
      @unlock_error = unlock_error
      @interrupted = false
      @unlock_attempts = 0
    end

    def flock(operation)
      if operation & File::LOCK_EX != 0 && !@interrupted
        @interrupted = true
        super
        raise @interrupt
      end
      if operation == File::LOCK_UN
        @unlock_attempts += 1
        raise @unlock_error
      end

      super
    end
  end

  class PostWriteStatFaultWriter < StreamLogTestSupport::DelegatingIO
    attr_reader :stat_calls

    def initialize(io, error:)
      super(io)
      @error = error
      @stat_calls = 0
    end

    def stat
      @stat_calls += 1
      raise @error if @stat_calls > 1

      super
    end
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

  class GatedSeparatorWriter < FileWriter
    def initialize(io, entered:, release:, **options)
      super(io, **options)
      @entered = entered
      @release = release
      @gated = false
    end

    def syswrite(chunk)
      if chunk == "#\n".b && !@gated
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
      seed_torn_tail(path, '{"sequence":2')

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
      seed_torn_tail(path, torn)
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
        seed_torn_tail(path, torn)
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
        seed_torn_tail(path, torn)
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
      seed_torn_tail(path)
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
      seed_torn_tail(path, "torn bytes")
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

  def test_successful_append_derives_its_snapshot_without_a_post_write_stat
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      writer = PostWriteStatFaultWriter.new(
        log.instance_variable_get(:@io), error: IOError.new("post-write stat")
      )
      log.instance_variable_set(:@io, writer)

      assert_equal 1, log.append(:stdout, "published")
      assert_equal 1, writer.stat_calls
      assert_equal [ "published" ], Hive::Attempts::StreamLog.read(path).map(&:bytes)
    ensure
      log&.close unless log&.closed?
    end
  end

  def test_newline_terminated_malformed_record_is_not_rewritten
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      first = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      first.append(:stdout, "published")
      first.close
      seed_torn_tail(path, "not-json\n")
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

  def test_streaming_reconciliation_matches_public_replay_for_invalid_base64
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      log.append(:stdout, "published")
      [ "not base64", "AB==", "AAB=" ].each_with_index do |data, index|
        malformed = JSON.generate(
          "sequence" => 97 + index,
          "timestamp" => NOW.iso8601(6),
          "channel" => "stdout",
          "data" => data
        ) + "\n"
        seed_torn_tail(path, malformed)
      end

      assert_equal 2, log.append(:stdout, "next")
      assert_equal [ 1, 2 ], Hive::Attempts::StreamLog.read(path).map(&:sequence)
    ensure
      log&.close unless log&.closed?
    end
  end

  def test_reconciliation_base64_validation_matches_strict_decoder_padding_rules
    [ "", "AAAA", "AA==", "AAA=", "AB==", "AAB=", "not base64" ].each do |encoded|
      replayable = begin
        Base64.strict_decode64(encoded)
        true
      rescue ArgumentError
        false
      end

      assert_equal replayable, Hive::Attempts::StreamLog.valid_base64?(encoded), encoded.inspect
    end
  end

  def test_reconciliation_base64_validation_matches_strict_decoder_for_every_final_quantum
    alphabet = [ *"A".."Z", *"a".."z", *"0".."9", "+", "/" ]
    replayable = lambda do |encoded|
      Base64.strict_decode64(encoded)
      true
    rescue ArgumentError
      false
    end
    mismatches = []
    alphabet.product(alphabet).each do |first, second|
      encoded = "QUJD#{first}#{second}=="
      mismatches << encoded unless replayable.call(encoded) == Hive::Attempts::StreamLog.valid_base64?(encoded)
      alphabet.each do |third|
        encoded = "QUJD#{first}#{second}#{third}="
        mismatches << encoded unless replayable.call(encoded) == Hive::Attempts::StreamLog.valid_base64?(encoded)
      end
    end

    assert_empty mismatches
  end

  def test_reopen_ignores_frames_with_noncanonical_padding_bits_like_public_replay
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      first = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      first.append(:stdout, "published")
      first.close
      [ [ 98, "AB==" ], [ 99, "AAB=" ] ].each do |sequence, data|
        seed_torn_tail(path, JSON.generate(
          "sequence" => sequence, "timestamp" => NOW.iso8601(6), "channel" => "stdout", "data" => data
        ) + "\n")
      end
      assert_equal [ 1 ], Hive::Attempts::StreamLog.read(path).map(&:sequence)

      reopened = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      assert_equal 2, reopened.append(:stdout, "next")
      assert_equal [ 1, 2 ], Hive::Attempts::StreamLog.read(path).map(&:sequence)
    ensure
      reopened&.close unless reopened&.closed?
    end
  end

  def test_non_object_and_out_of_range_frames_are_skipped_by_replay_and_reconciliation
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      first = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      first.append(:stdout, "published")
      first.close
      seed_torn_tail(path, "\"text\"\nnull\n[1]\n42\n")
      seed_torn_tail(path, %({"sequence":1e400,"timestamp":"t","channel":"stdout","data":""}\n))
      assert_equal [ 1 ], Hive::Attempts::StreamLog.read(path).map(&:sequence)

      reopened = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      assert_equal 2, reopened.append(:stdout, "next")
      seed_torn_tail(path, "null\n")
      assert_equal 3, reopened.append(:stdout, "after foreign append")
      assert_equal [ 1, 2, 3 ], Hive::Attempts::StreamLog.read(path).map(&:sequence)
    ensure
      reopened&.close unless reopened&.closed?
    end
  end

  def test_valid_json_without_newline_stays_unreadable_after_recovery
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      first = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      first.append(:stdout, "published")
      first.close
      unconfirmed = serialized_frame(sequence: 2, bytes: "unconfirmed").delete_suffix("\n")
      seed_torn_tail(path, unconfirmed)

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

  def test_strict_reconciliation_translates_an_eof_error
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      log.append(:stdout, "one")
      reader = ReadFile.new(log.instance_variable_get(:@read_io), error: EOFError.new("short read"))
      log.instance_variable_set(:@read_io, reader)
      other = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      other.append(:stdout, "two")
      other.close

      error = assert_raises(IOError) { log.append(:stdout, "blocked") }
      assert_match(/reported boundary/, error.message)
    ensure
      other&.close unless other&.closed?
      log&.close unless log&.closed?
    end
  end

  def test_real_truncation_past_reported_boundaries_fails_closed_and_allows_retry
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      log.append(:stdout, "one")
      seed_torn_tail(path, "x")
      tail_size = File.size(path)
      tail_reader = TruncatingReadFile.new(
        log.instance_variable_get(:@read_io), path: path, truncate_to: tail_size - 1,
        trigger: ->(length, _offset) { length == 1 }
      )
      log.instance_variable_set(:@read_io, tail_reader)

      error = assert_raises(IOError) { log.append(:stdout, "blocked") }
      assert_match(/reported boundary/, error.message)
      assert_equal 2, log.append(:stdout, "two")

      other = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      assert_equal 3, other.append(:stdout, "three")
      other.close
      retained_size = log.instance_variable_get(:@observed_size)
      full_reader = TruncatingReadFile.new(
        tail_reader, path: path, truncate_to: retained_size,
        trigger: ->(length, offset) { offset.zero? && length > 1 }
      )
      log.instance_variable_set(:@read_io, full_reader)
      error = assert_raises(IOError) { log.append(:stdout, "blocked again") }
      assert_match(/reported boundary/, error.message)
      assert_equal 3, log.append(:stdout, "four")
      assert_equal [ 1, 2, 3 ], Hive::Attempts::StreamLog.read(path).map(&:sequence)
    ensure
      other&.close unless other&.closed?
      log&.close unless log&.closed?
    end
  end

  def test_lock_release_failure_invalidates_the_snapshot_for_retry
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      unlock_error = Errno::EIO.new("unlock")
      writer = FileWriter.new(log.instance_variable_get(:@io), unlock_error: unlock_error)
      log.instance_variable_set(:@io, writer)

      error = assert_raises(Errno::EIO) { log.append(:stdout, "physically published") }
      assert_same unlock_error, error
      assert_equal [ 1 ], Hive::Attempts::StreamLog.read(path).map(&:sequence)
      independent = Timeout.timeout(1) do
        Hive::Attempts::StreamLog.new(path, clock: -> { NOW }, lock_timeout: 0.1)
      end
      assert_equal 2, independent.append(:stdout, "independent")
      independent.close
      assert_equal 3, log.append(:stdout, "retry")
      assert_equal [ 1, 2, 3 ], Hive::Attempts::StreamLog.read(path).map(&:sequence)
    ensure
      independent&.close unless independent&.closed?
      log&.close
    end
  end

  def test_lock_release_failure_does_not_mask_the_separator_error
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      seed_torn_tail(path)
      error = Errno::EINTR.new("separator")
      writer = FileWriter.new(
        log.instance_variable_get(:@io), separator_outcome: :write_error,
        unlock_error: Errno::EIO.new("unlock"), error: error
      )
      log.instance_variable_set(:@io, writer)

      raised = assert_raises(Errno::EINTR) { log.append(:stdout, "blocked") }
      assert_same error, raised
      assert_equal 1, log.append(:stdout, "recovered")
    ensure
      log&.close
    end
  end

  def test_interrupt_during_acquisition_is_preserved_and_fallback_releases_the_lock
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      interrupt = Interrupt.new("stop")
      writer = InterruptingLockWriter.new(
        log.instance_variable_get(:@io), interrupt: interrupt,
        unlock_error: Errno::EIO.new("unlock")
      )
      log.instance_variable_set(:@io, writer)

      raised = assert_raises(Interrupt) { log.append(:stdout, "blocked") }
      assert_same interrupt, raised
      assert_equal 1, writer.unlock_attempts
      independent = Timeout.timeout(1) do
        Hive::Attempts::StreamLog.new(path, clock: -> { NOW }, lock_timeout: 0.1)
      end
      assert_equal 1, independent.append(:stdout, "recovered")
    ensure
      independent&.close unless independent&.closed?
      log&.close unless log&.closed?
    end
  end

  def test_lock_wait_is_bounded_without_releasing_another_descriptors_lock
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      holder = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      contender = Hive::Attempts::StreamLog.new(
        path, clock: -> { NOW }, lock_timeout: 0.02
      )
      holder_io = holder.instance_variable_get(:@io)
      assert holder_io.flock(File::LOCK_EX | File::LOCK_NB)

      error = assert_raises(IOError) { contender.append(:stdout, "blocked") }
      assert_match(/held longer than/, error.message)
      File.open(path, File::WRONLY | File::APPEND) do |probe|
        refute probe.flock(File::LOCK_EX | File::LOCK_NB),
               "timed-out contender must not unlock the holder's descriptor"
      end

      holder_io.flock(File::LOCK_UN)
      assert_equal 1, contender.append(:stdout, "recovered")
    ensure
      holder_io&.flock(File::LOCK_UN) rescue nil
      contender&.close unless contender&.closed?
      holder&.close unless holder&.closed?
    end
  end

  def test_constructor_lock_wait_is_bounded_and_closes_opened_descriptors
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      seed = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      seed.close
      holder = File.open(path, File::WRONLY | File::APPEND)
      assert holder.flock(File::LOCK_EX | File::LOCK_NB)

      error = assert_raises(IOError) do
        Hive::Attempts::StreamLog.new(path, clock: -> { NOW }, lock_timeout: 0.02)
      end
      assert_match(/held longer than/, error.message)
      refute holder.closed?
    ensure
      holder&.flock(File::LOCK_UN) rescue nil
      holder&.close unless holder&.closed?
      seed&.close unless seed&.closed?
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

  def test_open_instances_serialize_torn_tail_recovery_and_keep_cursor_visibility
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      seed = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      seed.append(:stdout, "seed")
      seed.close
      seed_torn_tail(path)

      first_log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      second_log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      entered = Queue.new
      release = Queue.new
      results = Queue.new
      writer = GatedWriter.new(first_log.instance_variable_get(:@io), entered: entered, release: release)
      first_log.instance_variable_set(:@io, writer)

      first = Thread.new { results << [ "first", first_log.append(:stdout, "first") ] }
      Timeout.timeout(2) { entered.pop }
      second_started = Queue.new
      second = Thread.new do
        second_started << true
        results << [ "second", second_log.append(:stdout, "second") ]
      end
      Timeout.timeout(2) { second_started.pop }
      assert_raises(Timeout::Error) { Timeout.timeout(0.05) { results.pop } }

      release << true
      Timeout.timeout(2) { first.value }
      Timeout.timeout(2) { second.value }
      returned = 2.times.to_h { results.pop }
      assert_equal [ 2, 3 ], returned.values.sort

      frames = Hive::Attempts::StreamLog.read(path)
      assert_equal [ 1, 2, 3 ], frames.map(&:sequence)
      assert_equal %w[first second], frames.drop(1).map(&:bytes).sort
      lower_sequence, higher_sequence = returned.values.sort
      assert_equal [ higher_sequence ],
                   Hive::Attempts::StreamLog.read(path, after_sequence: lower_sequence).map(&:sequence)
    ensure
      release << true if release
      first&.join(0.1)
      second&.join(0.1)
      first_log&.close unless first_log&.closed?
      second_log&.close unless second_log&.closed?
      seed&.close unless seed&.closed?
    end
  end

  def test_separator_failure_releases_the_lock_for_another_instance
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      seed = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      seed.append(:stdout, "seed")
      seed.close
      seed_torn_tail(path)

      failing_log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      recovering_log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      entered = Queue.new
      release = Queue.new
      failed = Queue.new
      recovered = Queue.new
      error = Errno::EINTR.new("separator")
      writer = GatedSeparatorWriter.new(
        failing_log.instance_variable_get(:@io), entered: entered, release: release,
        separator_outcome: :write_error, error: error
      )
      failing_log.instance_variable_set(:@io, writer)

      failing = Thread.new do
        failing_log.append(:stdout, "not published")
      rescue StandardError => raised
        failed << raised
      end
      Timeout.timeout(2) { entered.pop }
      recovering_started = Queue.new
      recovering = Thread.new do
        recovering_started << true
        recovered << recovering_log.append(:stdout, "recovered")
      end
      Timeout.timeout(2) { recovering_started.pop }
      assert_raises(Timeout::Error) { Timeout.timeout(0.05) { recovered.pop } }

      release << true
      Timeout.timeout(2) { failing.value }
      Timeout.timeout(2) { recovering.value }
      assert_same error, failed.pop
      assert_equal 2, recovered.pop
      frames = Hive::Attempts::StreamLog.read(path)
      assert_equal [ 1, 2 ], frames.map(&:sequence)
      assert_equal [ "seed", "recovered" ], frames.map(&:bytes)
    ensure
      release << true if release
      failing&.join(0.1)
      recovering&.join(0.1)
      failing_log&.close unless failing_log&.closed?
      recovering_log&.close unless recovering_log&.closed?
      seed&.close unless seed&.closed?
    end
  end

  def test_frame_failure_releases_the_lock_for_another_instance
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      first_log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      first_log.append(:stdout, "seed")
      second_log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      error = IOError.new("mid-frame")
      writer = FileWriter.new(
        first_log.instance_variable_get(:@io), frame_prefix_before_error: 20, error: error
      )
      first_log.instance_variable_set(:@io, writer)

      assert_same error, assert_raises(IOError) { first_log.append(:stdout, "not published") }
      assert_equal 2, Timeout.timeout(2) { second_log.append(:stdout, "recovered") }
      frames = Hive::Attempts::StreamLog.read(path)
      assert_equal [ 1, 2 ], frames.map(&:sequence)
      assert_equal [ "seed", "recovered" ], frames.map(&:bytes)
    ensure
      first_log&.close unless first_log&.closed?
      second_log&.close unless second_log&.closed?
    end
  end

  def test_healthy_appends_use_the_snapshot_until_external_progress_or_an_error
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      read_file = ReadFile.new(log.instance_variable_get(:@read_io))
      log.instance_variable_set(:@read_io, read_file)
      original_open = File.method(:open)
      original_binread = File.method(:binread)
      original_read = File.method(:read)
      original_stream_read = Hive::Attempts::StreamLog.method(:read)
      path_opens = 0
      alternate_reads = 0
      replacement = lambda do |candidate, *args, **kwargs, &block|
        path_opens += 1 if File.expand_path(candidate) == path
        original_open.call(candidate, *args, **kwargs, &block)
      end
      binread_replacement = lambda do |candidate, *args, **kwargs|
        alternate_reads += 1 if File.expand_path(candidate) == path
        original_binread.call(candidate, *args, **kwargs)
      end
      read_replacement = lambda do |candidate, *args, **kwargs|
        alternate_reads += 1 if File.expand_path(candidate) == path
        original_read.call(candidate, *args, **kwargs)
      end
      stream_read_replacement = lambda do |candidate, **kwargs|
        alternate_reads += 1 if File.expand_path(candidate) == path
        original_stream_read.call(candidate, **kwargs)
      end

      with_replaced_singleton_method(File, :open, replacement) do
        with_replaced_singleton_method(File, :binread, binread_replacement) do
          with_replaced_singleton_method(File, :read, read_replacement) do
            with_replaced_singleton_method(
              Hive::Attempts::StreamLog, :read, stream_read_replacement
            ) do
              assert_equal 1, log.append(:stdout, "one")
              assert_equal 2, log.append(:stdout, "two")
            end
          end
        end
      end
      assert_equal 0, path_opens
      assert_equal 0, alternate_reads
      assert_equal 0, read_file.full_reads
      assert_equal 1, read_file.pread_calls
      assert_equal 1, read_file.bytes_requested

      other = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      assert_equal 3, other.append(:stdout, "three")
      other.close
      assert_equal 4, log.append(:stdout, "four")
      assert_equal 1, read_file.full_reads

      clock_error = IOError.new("clock failed")
      log.instance_variable_set(:@clock, -> { raise clock_error })
      assert_same clock_error, assert_raises(IOError) { log.append(:stdout, "blocked") }
      assert_equal 1, read_file.full_reads

      log.instance_variable_set(:@clock, -> { NOW })
      assert_equal 5, log.append(:stdout, "five")
      assert_equal 2, read_file.full_reads
      assert_equal [ 1, 2, 3, 4, 5 ], Hive::Attempts::StreamLog.read(path).map(&:sequence)
    ensure
      other&.close unless other&.closed?
      log&.close unless log&.closed?
    end
  end

  def test_reconciliation_streams_sequences_without_decoding_or_allocating_frames
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      log.append(:stdout, "one")
      other = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      other.append(:stdout, "two")
      other.close

      with_replaced_singleton_method(
        Base64, :strict_decode64, ->(_encoded) { raise "decoded during reconciliation" }
      ) do
        with_replaced_singleton_method(
          Hive::Attempts::StreamLog::Frame, :new,
          ->(**_attributes) { raise "allocated a frame during reconciliation" }
        ) do
          assert_equal 3, log.append(:stdout, "three")
        end
      end
      assert_equal [ 1, 2, 3 ], Hive::Attempts::StreamLog.read(path).map(&:sequence)
    ensure
      other&.close unless other&.closed?
      log&.close unless log&.closed?
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
          writer = FileWriter.new(io, close_error: IOError.new("append close failed"))
          opened << writer
          writer
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

  def test_constructor_failure_closes_real_custody_descriptor_without_masking_the_error
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      seed = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      seed.append(:stdout, "published")
      seed.close
      custody_path = File.join(root, "custody.lock")
      custody = File.open(custody_path, File::RDWR | File::CREAT, 0o600)
      assert custody.flock(File::LOCK_EX | File::LOCK_NB)
      original_open = File.method(:open)
      error = IOError.new("strict read failed")
      replacement = lambda do |candidate, *args, **kwargs, &block|
        io = original_open.call(candidate, *args, **kwargs, &block)
        if candidate == path && args.first.is_a?(Integer) &&
           (args.first & File::WRONLY) != File::WRONLY
          ReadFile.new(io, error: error)
        else
          io
        end
      end

      with_replaced_singleton_method(File, :open, replacement) do
        raised = assert_raises(IOError) do
          Hive::Attempts::StreamLog.new(path, custody_io: custody)
        end
        assert_same error, raised
      end
      assert custody.closed?
      File.open(custody_path, File::RDWR) do |probe|
        assert probe.flock(File::LOCK_EX | File::LOCK_NB)
      end
    ensure
      custody&.close unless custody&.closed?
    end
  end

  def test_constructor_lock_acquisition_failure_closes_descriptors_without_masking_the_error
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, "")
      original_open = File.method(:open)
      opened = []
      error = Errno::ENOLCK.new("append lock")
      replacement = lambda do |candidate, *args, **kwargs, &block|
        io = original_open.call(candidate, *args, **kwargs, &block)
        next io unless candidate == path && args.first.is_a?(Integer)

        if (args.first & File::WRONLY) == File::WRONLY
          writer = FileWriter.new(
            io, lock_error: error, close_error: IOError.new("append close failed")
          )
          opened << writer
          writer
        else
          reader = ReadFile.new(io, close_error: IOError.new("read close failed"))
          opened << reader
          reader
        end
      end

      with_replaced_singleton_method(File, :open, replacement) do
        raised = assert_raises(Errno::ENOLCK) { Hive::Attempts::StreamLog.new(path) }
        assert_same error, raised
      end
      assert_equal 2, opened.length
      assert opened.all?(&:closed?)
      Timeout.timeout(2) { Hive::Attempts::StreamLog.new(path).close }
    end
  end

  def test_constructor_interrupt_closes_descriptors_and_custody_without_masking_the_interrupt
    [ :lock, :scan ].each do |phase|
      with_tmp_dir do |root|
        path = File.join(root, "logs", "#{phase}.frames")
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, serialized_frame(sequence: 1, bytes: "published"))
        custody = CustodyFile.new(close_error: IOError.new("custody close failed"))
        original_open = File.method(:open)
        opened = []
        interrupt = Interrupt.new("#{phase} interrupted")
        replacement = lambda do |candidate, *args, **kwargs, &block|
          io = original_open.call(candidate, *args, **kwargs, &block)
          next io unless candidate == path && args.first.is_a?(Integer)

          if (args.first & File::WRONLY) == File::WRONLY
            writer = FileWriter.new(
              io, lock_error: (interrupt if phase == :lock),
              close_error: IOError.new("append close failed")
            )
            opened << writer
            writer
          else
            reader = ReadFile.new(
              io, error: (interrupt if phase == :scan),
              close_error: IOError.new("read close failed")
            )
            opened << reader
            reader
          end
        end

        with_replaced_singleton_method(File, :open, replacement) do
          raised = assert_raises(Interrupt) do
            Hive::Attempts::StreamLog.new(path, custody_io: custody)
          end
          assert_same interrupt, raised
        end
        assert_equal 2, opened.length
        assert opened.all?(&:closed?), "#{phase} interrupt must close both log descriptors"
        assert custody.closed?, "#{phase} interrupt must close custody"
      ensure
        custody&.close unless custody&.closed?
      end
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
      refute sync_log.closed?
      sync_log.append(:supervisor, "diagnostic")
      sync_log.close
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

  def test_close_releases_remaining_resources_when_append_descriptor_replacement_fails
    [ :open, :validation, :mismatch, :cleanup, :writer_close ].each do |failure|
      with_tmp_dir do |root|
        path = File.join(root, "logs", "#{failure}.frames")
        other_path = File.join(root, "other.frames")
        File.binwrite(other_path, "") if failure == :mismatch
        custody = CustodyFile.new
        log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW }, custody_io: custody)
        reader = log.instance_variable_get(:@read_io)
        if [ :validation, :cleanup ].include?(failure)
          reader.define_singleton_method(:stat) { raise IOError, "validation failed" }
        end
        writer = FileWriter.new(
          log.instance_variable_get(:@io), unlock_error: Errno::EIO.new("unlock"),
          close_error: (IOError.new("writer close failed") if failure == :writer_close)
        )
        log.instance_variable_set(:@io, writer)
        original_open = File.method(:open)
        uninstalled = nil
        replacement = lambda do |candidate, *args, **kwargs, &block|
          replacing = candidate == path && args.first.is_a?(Integer) &&
            (args.first & File::WRONLY) == File::WRONLY && (args.first & File::CREAT).zero?
          next original_open.call(candidate, *args, **kwargs, &block) unless replacing
          raise Errno::EMFILE, "replacement unavailable" if failure == :open

          opened = original_open.call(failure == :mismatch ? other_path : candidate, *args, **kwargs, &block)
          uninstalled = if failure == :cleanup
            FileWriter.new(opened, close_error: IOError.new("replacement close failed"))
          else
            opened
          end
        end

        with_replaced_singleton_method(File, :open, replacement) do
          assert_raises(Errno::EIO) { log.append(:stdout, "published") }
        end
        assert writer.closed?
        if failure == :writer_close
          refute uninstalled.closed?, "the successfully installed replacement must remain open"
        else
          assert uninstalled.closed? if uninstalled
        end
        refute log.closed?, "retained reader and custody still require explicit cleanup"

        log.close
        assert reader.closed?
        assert custody.closed?
        assert log.closed?
      ensure
        log&.close unless log&.closed?
      end
    end
  end

  def test_reopen_after_torn_write_preserves_the_first_post_recovery_frame
    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      log.append(:stdout, "a")
      log.close
      seed_torn_tail(path, '{"sequence":2,"timestamp":"2026-')

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
