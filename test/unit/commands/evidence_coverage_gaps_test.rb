require "test_helper"
require "hive/commands/evidence"

class CommandsEvidenceCoverageGapsTest < Minitest::Test
  include HiveTestHelper

  Evidence = Hive::Commands::Evidence
  Mailbox = Hive::Artifacts::CaptureMailbox

  def test_browser_keeps_a_defensive_status_check_after_gateway_admission
    command = Evidence.new("browser", "snapshot", environment: {})
    command.define_singleton_method(:gateway_request) do |_payload|
      { "ok" => false, "status" => 1, "stdout" => "", "stderr" => "" }
    end

    assert_raises(Hive::UsageError) do
      capture_io { command.send(:run_browser) }
    end
  end

  def test_mailbox_and_request_boundaries_reject_symlinks_regular_files_and_absence
    Dir.mktmpdir("hive-evidence-boundaries") do |root|
      target = File.join(root, "target")
      Dir.mkdir(target)
      link = File.join(root, "mailbox-link")
      File.symlink(target, link)
      assert_raises(Hive::UsageError) do
        Evidence.new(
          "browser", "snapshot",
          environment: { "HIVE_EVIDENCE_CAPTURE_MAILBOX" => link }
        ).call
      end

      request = File.join(target, "requests.fifo")
      File.write(request, "not a fifo")
      assert_raises(Hive::UsageError) do
        Evidence.new(
          "browser", "snapshot",
          environment: { "HIVE_EVIDENCE_CAPTURE_MAILBOX" => target }
        ).call
      end

      File.unlink(request)
      error = assert_raises(Hive::UsageError) do
        Evidence.new(
          "browser", "snapshot",
          environment: { "HIVE_EVIDENCE_CAPTURE_MAILBOX" => target }
        ).call
      end
      assert_match(/gateway is unavailable/, error.message)
    end
  end

  def test_gateway_rejects_oversized_requests_and_request_fifo_replacement
    with_mailbox(->(*) { flunk "oversized request must not reach the controller" }) do |mailbox|
      assert_raises(Hive::UsageError) do
        Evidence.new(
          "browser", "x" * Mailbox::MAX_REQUEST_BYTES,
          environment: mailbox_environment(mailbox)
        ).call
      end
    end

    with_mailbox(->(*) { flunk "replaced request boundary must not execute" }) do |mailbox|
      request_path = File.join(mailbox.root, "requests.fifo")
      request_stat = File.lstat(request_path)
      fake_stat = Struct.new(:pipe?, :dev, :ino)
        .new(true, request_stat.dev, request_stat.ino + 1)
      writer = Object.new
      writer.define_singleton_method(:stat) { fake_stat }
      original = File.method(:open)
      replacement = lambda do |path, *args, **kwargs, &block|
        if path == request_path && block
          block.call(writer)
        else
          original.call(path, *args, **kwargs, &block)
        end
      end

      with_replaced_singleton_method(File, :open, replacement) do
        assert_raises(Hive::UsageError) do
          Evidence.new(
            "browser", "snapshot", environment: mailbox_environment(mailbox)
          ).call
        end
      end
    end
  end

  def test_reply_cleanup_tolerates_a_race
    with_mailbox(
      ->(*) { { "ok" => true, "status" => 0, "stdout" => "ready\n", "stderr" => "" } }
    ) do |mailbox|
      with_replaced_singleton_method(File, :unlink, ->(*) { raise Errno::ENOENT }) do
        out, = capture_io do
          Evidence.new(
            "browser", "snapshot", environment: mailbox_environment(mailbox)
          ).call
        end
        assert_equal "ready\n", out
      end
    end
  end

  def test_nonblocking_gateway_write_waits_and_times_out
    command = Evidence.new("browser", "snapshot", environment: {})
    source = "request\n"
    writer = Object.new
    calls = 0
    writer.define_singleton_method(:write_nonblock) do |value|
      calls += 1
      raise IO::EAGAINWaitWritable if calls == 1

      value.bytesize
    end
    with_replaced_singleton_method(IO, :select, ->(*) { true }) do
      assert_nil command.send(:write_gateway_request, writer, source)
    end
    assert_equal 2, calls

    writer.define_singleton_method(:write_nonblock) { |_| raise IO::EAGAINWaitWritable }
    clocks = [ 0.0, 6.0 ]
    with_replaced_singleton_method(Process, :clock_gettime, ->(*) { clocks.shift }) do
      assert_raises(Hive::UsageError) do
        command.send(:write_gateway_request, writer, source)
      end
    end
  end

  def test_nonblocking_gateway_read_retries_and_bounds_the_response
    command = Evidence.new("browser", "snapshot", environment: {})
    reader = Object.new
    calls = 0
    reader.define_singleton_method(:read_nonblock) do |_bytes|
      calls += 1
      raise IO::EAGAINWaitReadable if calls == 1

      "{\"ok\":true}\n"
    end
    with_replaced_singleton_method(IO, :select, ->(*) { true }) do
      assert_equal true, command.send(:read_gateway_response, reader).fetch("ok")
    end

    oversized = Object.new
    oversized.define_singleton_method(:read_nonblock) do |_bytes|
      "x" * (Mailbox::MAX_RESPONSE_BYTES + 1)
    end
    with_replaced_singleton_method(IO, :select, ->(*) { true }) do
      assert_raises(Hive::UsageError) do
        command.send(:read_gateway_response, oversized)
      end
    end
  end

  private

  def with_mailbox(handler)
    mailbox = Mailbox.new(handler: handler).start!
    yield mailbox
  ensure
    mailbox&.close
  end

  def mailbox_environment(mailbox)
    { "HIVE_EVIDENCE_CAPTURE_MAILBOX" => mailbox.root }
  end
end
