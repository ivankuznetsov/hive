require "test_helper"
require "hive/artifacts/capture_mailbox"
require "hive/commands/evidence"

class ArtifactsCaptureMailboxTest < Minitest::Test
  include HiveTestHelper

  def test_mailbox_is_private_bounded_and_recovers_after_malformed_input
    mailbox = Hive::Artifacts::CaptureMailbox.new(
      handler: ->(request) do
        {
          "ok" => true, "status" => 0,
          "stdout" => request.fetch("argv").join(" ") << "\n", "stderr" => ""
        }
      end
    ).start!
    root = mailbox.root
    request_path = File.join(root, "requests.fifo")
    assert_equal 0o700, File.stat(root).mode & 0o777
    assert_equal 0o600, File.stat(request_path).mode & 0o777
    assert File.pipe?(request_path)

    File.open(request_path, File::WRONLY | File::NONBLOCK | File::NOFOLLOW) do |writer|
      writer.write("not-json\n")
    end
    out, = capture_io do
      Hive::Commands::Evidence.new(
        "browser", "snapshot", command: [ "-i" ],
        environment: { "HIVE_EVIDENCE_CAPTURE_MAILBOX" => root }
      ).call
    end
    assert_equal "snapshot -i\n", out

    assert mailbox.close
    refute File.exist?(root)
  ensure
    mailbox&.close
  end

  def test_partial_request_does_not_block_controller_shutdown
    mailbox = Hive::Artifacts::CaptureMailbox.new(
      handler: ->(_request) { flunk "partial request must not execute" }
    ).start!
    File.open(
      File.join(mailbox.root, "requests.fifo"),
      File::WRONLY | File::NONBLOCK | File::NOFOLLOW
    ) { |writer| writer.write("{") }

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert mailbox.close
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator elapsed, :<, 1.0
  ensure
    mailbox&.close
  end

  def test_response_larger_than_fifo_capacity_is_delivered_completely
    output = "x" * (128 * 1024)
    mailbox = Hive::Artifacts::CaptureMailbox.new(
      handler: ->(_request) do
        { "ok" => true, "status" => 0, "stdout" => output, "stderr" => "" }
      end
    ).start!

    actual, = capture_io do
      Hive::Commands::Evidence.new(
        "browser", "snapshot",
        environment: { "HIVE_EVIDENCE_CAPTURE_MAILBOX" => mailbox.root }
      ).call
    end
    assert_equal output, actual
  ensure
    mailbox&.close
  end

  def test_start_and_close_normalize_filesystem_failures
    mailbox = Hive::Artifacts::CaptureMailbox.new(handler: ->(*) { })
    error = with_replaced_singleton_method(
      Dir, :mktmpdir, ->(*) { raise Errno::EACCES, "denied" }
    ) do
      assert_raises(Hive::Artifacts::CaptureMailbox::MailboxError) { mailbox.start! }
    end
    assert_match(/unavailable/, error.message)

    request = Object.new
    request.define_singleton_method(:closed?) { false }
    request.define_singleton_method(:close) { raise IOError, "closed elsewhere" }
    mailbox.instance_variable_set(:@request, request)
    refute mailbox.close
    assert_nil mailbox.instance_variable_get(:@request)
  end

  def test_serve_recovers_from_nonblocking_reads_oversized_fragments_and_closed_descriptors
    mailbox = Hive::Artifacts::CaptureMailbox.new(handler: ->(*) { })
    reader, writer = IO.pipe
    calls = 0
    mailbox.define_singleton_method(:closed?) do
      calls += 1
      calls > 1
    end
    mailbox.instance_variable_set(:@request, reader)
    with_replaced_singleton_method(IO, :select, ->(*) { true }) do
      assert_nil mailbox.send(:serve)
    end
    reader.close
    writer.close

    mailbox = Hive::Artifacts::CaptureMailbox.new(handler: ->(*) { })
    request = Object.new
    request.define_singleton_method(:read_nonblock) do |*|
      "x" * (Hive::Artifacts::CaptureMailbox::MAX_REQUEST_BYTES + 1)
    end
    calls = 0
    mailbox.define_singleton_method(:closed?) do
      calls += 1
      calls > 1
    end
    mailbox.instance_variable_set(:@request, request)
    with_replaced_singleton_method(IO, :select, ->(*) { true }) do
      assert_nil mailbox.send(:serve)
    end

    mailbox = Hive::Artifacts::CaptureMailbox.new(handler: ->(*) { })
    mailbox.define_singleton_method(:closed?) { false }
    mailbox.instance_variable_set(:@request, request)
    with_replaced_singleton_method(IO, :select, ->(*) { raise IOError, "closed" }) do
      assert_nil mailbox.send(:serve)
    end
  end

  def test_request_failures_are_generic_and_reply_paths_fail_closed
    mailbox = Hive::Artifacts::CaptureMailbox.new(
      handler: ->(*) { raise RuntimeError, "private detail" }
    ).start!
    environment = { "HIVE_EVIDENCE_CAPTURE_MAILBOX" => mailbox.root }
    error = assert_raises(Hive::UsageError) do
      Hive::Commands::Evidence.new(
        "browser", "snapshot", environment: environment
      ).call
    end
    assert_equal "capture gateway command failed", error.message

    regular = File.join(mailbox.root, "reply-#{'a' * 24}.fifo")
    File.write(regular, "not a fifo")
    assert_raises(Hive::Artifacts::CaptureMailbox::MailboxError) do
      mailbox.send(:reply_path, File.basename(regular))
    end
    assert_raises(Hive::Artifacts::CaptureMailbox::MailboxError) do
      mailbox.send(:reply_path, "reply-#{'b' * 24}.fifo")
    end

    abandoned = File.join(mailbox.root, "reply-#{'c' * 24}.fifo")
    File.mkfifo(abandoned, 0o600)
    assert_nil mailbox.send(:respond, abandoned, "ok" => true)
  ensure
    mailbox&.close
  end

  def test_owned_root_cleanup_tolerates_a_disappearing_root
    root = Dir.mktmpdir("hive-mailbox-cleanup")
    mailbox = Hive::Artifacts::CaptureMailbox.new(handler: ->(*) { })
    mailbox.instance_variable_set(:@root, root)
    original = FileUtils.method(:remove_entry_secure)
    replacement = lambda do |path|
      original.call(path)
      raise Errno::ENOENT, path
    end

    with_replaced_singleton_method(FileUtils, :remove_entry_secure, replacement) do
      assert_nil mailbox.send(:remove_owned_root)
    end
    refute_path_exists root
  ensure
    FileUtils.remove_entry_secure(root) if root && File.directory?(root)
  end
end
