require "test_helper"
require "digest"
require_relative "../../../packaging/live_agent_skills/workflow_creator_capture"

class WorkflowCreatorCaptureTest < Minitest::Test
  Capture = HiveLiveAgentProof::WorkflowCreator::Capture

  def test_caps_each_stream_and_digests_only_admitted_bytes
    capture = Capture.new(limit_bytes: 8, tail_bytes: 16)
    capture.write(:stdout, "abc")
    capture.write(:stdout, "defghijkl")
    capture.write(:stderr, "err")

    result = capture.finish

    assert_equal 8, result.fetch("stdout_bytes")
    assert_equal Digest::SHA256.hexdigest("abcdefgh"), result.fetch("stdout_sha256")
    assert result.fetch("stdout_truncated")
    assert_equal 3, result.fetch("stderr_bytes")
    assert_equal Digest::SHA256.hexdigest("err"), result.fetch("stderr_sha256")
    refute result.fetch("stderr_truncated")
    assert_equal "abcdefghijkl", result.dig("tails", "stdout")
    assert_equal "passed", result.dig("secret_scan", "status")
  end

  def test_detects_an_exact_secret_split_across_chunks_and_redacts_the_tail
    secret = "creator-secret-value"
    capture = Capture.new(limit_bytes: 64, tail_bytes: 64, exact_secrets: [ secret ])

    capture.write(:stdout, "safe creator-se")
    capture.write(:stdout, "cret-value suffix")
    result = capture.finish

    assert_equal "failed", result.dig("secret_scan", "status")
    assert_equal [ "stdout:exact-secret:0" ], result.dig("secret_scan", "findings")
    assert_equal "[REDACTED]", result.dig("tails", "stdout")
    refute_includes result.to_s, secret
  end

  def test_detects_a_maximum_window_secret_before_trimming_scan_overlap
    secret = "s" * 3_000
    capture = Capture.new(limit_bytes: 8_192, exact_secrets: [ secret ])

    capture.write(:stdout, ("x" * 1_097) + secret + ("y" * 2_047))
    result = capture.finish

    assert_equal "failed", result.dig("secret_scan", "status")
    assert_equal [ "stdout:exact-secret:0" ], result.dig("secret_scan", "findings")
    assert_equal "[REDACTED]", result.dig("tails", "stdout")
  end

  def test_detects_a_secret_pattern_split_across_chunks_after_the_byte_cap
    token = "sk-proj-#{'a' * 24}"
    capture = Capture.new(limit_bytes: 4, tail_bytes: 32)

    capture.write(:stderr, "noise" * 2_000 + token.byteslice(0, 10))
    capture.write(:stderr, token.byteslice(10, token.bytesize))
    result = capture.finish

    assert_equal 4, result.fetch("stderr_bytes")
    assert result.fetch("stderr_truncated")
    assert_includes result.dig("secret_scan", "findings"), "stderr:pattern:openai"
    assert_equal "[REDACTED]", result.dig("tails", "stderr")
  end

  def test_empty_streams_have_the_empty_digest_and_bounded_utf8_tails
    capture = Capture.new(limit_bytes: 32, tail_bytes: 5)
    capture.write(:stdout, "x\xFFé".b)
    result = capture.finish

    assert_equal Digest::SHA256.hexdigest(""), result.fetch("stderr_sha256")
    assert_equal "xé", result.dig("tails", "stdout")
    assert_operator result.dig("tails", "stdout").bytesize, :<=, 5
  end

  def test_rejects_invalid_limits_streams_chunks_and_exact_secrets
    assert_raises(Capture::Error) { Capture.new(limit_bytes: 0) }
    assert_raises(Capture::Error) { Capture.new(limit_bytes: 1_048_577) }
    assert_raises(Capture::Error) { Capture.new(limit_bytes: 8, tail_bytes: 4_097) }
    assert_raises(Capture::Error) { Capture.new(limit_bytes: 8, exact_secrets: [ "" ]) }
    assert_raises(Capture::Error) { Capture.new(limit_bytes: 8, exact_secrets: [ "x" ] * 65) }

    capture = Capture.new(limit_bytes: 8)
    assert_raises(Capture::Error) { capture.write(:other, "value") }
    assert_raises(Capture::Error) { capture.write(:stdout, Object.new) }
    capture.finish
    assert_raises(Capture::Error) { capture.write(:stdout, "late") }
  end
end
