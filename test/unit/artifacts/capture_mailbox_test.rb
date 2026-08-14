require "test_helper"
require "hive/artifacts/capture_mailbox"
require "hive/commands/evidence"

class ArtifactsCaptureMailboxTest < Minitest::Test
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
end
