require "test_helper"
require "hive/secret_patterns"

# Log redaction only. Detection is tested against Betterleaks.
class SecretPatternsTest < Minitest::Test
  def test_pem_private_key_block_body_is_redacted_not_just_header
    # Pre-fix the regex matched only the BEGIN delimiter, leaving the
    # base64 body and END line in redacted output. A leak path because
    # diagnose-time artifacts now egress through the agent profile +
    # on-disk red-status.md + diagnostic.detail JSON. See PR #84 #3.
    pem = <<~PEM
      -----BEGIN RSA PRIVATE KEY-----
      MIIEowIBAAKCAQEAvbPHGfakebodyzxcvbnmasdfghjklqwertyuiopASDF1234==
      QWERTYZXCVBNMqwertyuiopasdfghjklzxcvbnm1234567890abcdefABCDEFGH==
      -----END RSA PRIVATE KEY-----
    PEM
    redacted = Hive::SecretPatterns.redact(pem)
    refute_includes redacted, "MIIEow",
                    "PEM body bytes must be redacted, not just the BEGIN delimiter"
    refute_includes redacted, "-----END RSA PRIVATE KEY-----",
                    "PEM END delimiter must also be inside the redaction span"
    assert_includes redacted, "[REDACTED:pem_private_key]"
  end

  def test_truncated_pem_header_with_partial_body_is_redacted
    # Status diagnostic tails are cut at DIAGNOSTIC_DETAIL_MAX (4000 bytes);
    # most real-world leaks look like BEGIN + partial body + EOF (no
    # matching END). pem_private_key (block form) cannot match this; the
    # pem_private_key_header fallback must catch it. See issue #88.
    truncated = <<~PEM
      ... noisy log tail ...
      -----BEGIN RSA PRIVATE KEY-----
      MIIEowIBAAKCAQEAvbPHGfakebodyzxcvbnmasdfghjklqwertyuiopASDF1234==
      QWERTYZXCVBNMqwertyuiopasdfghjklzxcvbnm1234567890abcdefABCDEFGH==
    PEM

    redacted = Hive::SecretPatterns.redact(truncated)
    refute_includes redacted, "MIIEow",
                    "partial PEM body bytes must be redacted even without END delimiter"
    refute_includes redacted, "QWERTYZXCVBNM",
                    "later partial PEM body lines must also be redacted"
    assert_includes redacted, "[REDACTED:pem_private_key_header]"
    # Non-PEM context (the noisy log tail) must survive — over-redaction
    # would erase too much operator-useful context.
    assert_includes redacted, "noisy log tail"
  end

  def test_long_private_key_bodies_are_fully_redacted
    complete_body = "A" * 8_000
    complete = <<~PEM
      -----BEGIN PRIVATE KEY-----
      #{complete_body}
      -----END PRIVATE KEY-----
    PEM
    complete_redacted = Hive::SecretPatterns.redact(complete)
    refute_includes complete_redacted, complete_body
    assert_includes complete_redacted, "[REDACTED:pem_private_key]"

    truncated_body = "B" * 8_000
    truncated =
      "-----BEGIN OPENSSH PRIVATE KEY-----\n#{truncated_body}"
    truncated_redacted = Hive::SecretPatterns.redact(truncated)
    refute_includes truncated_redacted, truncated_body
    assert_includes(
      truncated_redacted,
      "[REDACTED:pem_private_key_header]"
    )
  end

  def test_truncated_pem_header_alone_with_no_body_is_redacted
    # Edge case: truncation cut at the BEGIN line itself, leaving no
    # body. Still redact — the header signal alone is meaningful and
    # there may be a byte or two of key material on the same line.
    head_only = "log line\n-----BEGIN OPENSSH PRIVATE KEY-----\n"
    redacted = Hive::SecretPatterns.redact(head_only)
    refute_includes redacted, "BEGIN OPENSSH PRIVATE KEY"
  end

  def test_complete_pem_uses_block_pattern_not_header_fallback
    # Ordering invariant: a full BEGIN..END envelope must be redacted by
    # pem_private_key (the block-form pattern), NOT swallowed by the
    # broader header-only fallback. Otherwise the placeholder name
    # changes silently as code evolves.
    pem = <<~PEM
      -----BEGIN RSA PRIVATE KEY-----
      MIIEowIBAAKCAQEAvbPHGfakebodyzxcvbnmasdfghjklqwertyuiopASDF1234==
      -----END RSA PRIVATE KEY-----
    PEM
    redacted = Hive::SecretPatterns.redact(pem)
    assert_includes redacted, "[REDACTED:pem_private_key]"
    refute_includes redacted, "[REDACTED:pem_private_key_header]"
  end

  def test_current_fine_grained_github_pat_is_detected_and_redacted
    token = "github_pat_#{'AbC123_' * 8}"
    redacted = Hive::SecretPatterns.redact("token=#{token}")
    refute_includes redacted, token
    assert_includes redacted, "[REDACTED:github_fine_grained_pat]"
  end

  def test_hyphenated_openai_project_credential_is_detected_and_redacted
    credential = "sk-proj-#{'AbC123_' * 6}"

    redacted = Hive::SecretPatterns.redact("credential=#{credential}")
    refute_includes redacted, credential
    assert_includes redacted, "[REDACTED:openai_api_key]"
  end

  def test_redact_replaces_match_with_named_placeholder
    text = "ACCESS = AKIAIOSFODNN7EXAMPLE"
    assert_equal "ACCESS = [REDACTED:aws_access_key]", Hive::SecretPatterns.redact(text)
  end

  def test_redact_handles_nil_and_blank
    assert_equal "", Hive::SecretPatterns.redact(nil)
    assert_equal "", Hive::SecretPatterns.redact("")
  end

  def test_redact_does_not_mutate_input
    text = "ACCESS = AKIAIOSFODNN7EXAMPLE"
    snapshot = text.dup
    Hive::SecretPatterns.redact(text)
    assert_equal snapshot, text, "redact must not mutate its argument"
  end

  def test_redact_coerces_binary_input_to_utf8_without_raising
    # tail_file used to return ASCII-8BIT bytes; gsub against the
    # PATTERNS regexes (UTF-8) raised Encoding::CompatibilityError on
    # any non-ASCII byte, aborting `hive status --json`. See PR #84 #4.
    binary = "log entry \xff\xfe AKIAIOSFODNN7EXAMPLE done".dup.force_encoding(Encoding::ASCII_8BIT)
    redacted = Hive::SecretPatterns.redact(binary)
    assert_equal Encoding::UTF_8, redacted.encoding
    assert_includes redacted, "[REDACTED:aws_access_key]"
  end

  def test_redact_preserves_valid_utf8_bytes_tagged_as_binary
    token = "ghp_#{'u' * 36}"
    binary = "日本語 #{token}".b
    redacted = Hive::SecretPatterns.redact(binary)

    assert_equal Encoding::UTF_8, redacted.encoding
    assert_includes redacted, "日本語"
    assert_includes redacted, "[REDACTED:github_token]"
    refute_includes redacted, "???"
  end
end
