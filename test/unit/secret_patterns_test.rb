require "test_helper"
require "hive/secret_patterns"

# Direct coverage for Hive::SecretPatterns. The shared regex set is
# consumed by both PR-body scanning and the post-fix diff guardrail —
# false negatives there mean a credential ships to a public PR or a
# fix-agent commit, so each pattern must have at least one assertion
# proving it fires on a realistic input.
class SecretPatternsTest < Minitest::Test
  def assert_match_name(text, expected_name)
    matches = Hive::SecretPatterns.scan(text)
    assert(matches.any? { |m| m[:name] == expected_name },
           "expected #{expected_name} match in #{text.inspect}; got #{matches.inspect}")
  end

  def refute_match_any(text)
    matches = Hive::SecretPatterns.scan(text)
    assert_empty matches, "expected no matches in #{text.inspect}; got #{matches.inspect}"
  end

  def test_aws_access_key_long_term_prefix_is_detected
    assert_match_name("ACCESS = AKIAIOSFODNN7EXAMPLE", :aws_access_key)
  end

  def test_aws_access_key_session_token_prefix_is_detected
    # ASIA = STS temporary credentials. Pre-fix the regex only matched
    # AKIA, missing every session-token leak (extremely common in CI
    # environments using assume-role).
    assert_match_name("export AWS_KEY=ASIA1234567890123456", :aws_access_key)
  end

  def test_generic_api_key_quoted_is_detected
    assert_match_name(%(api_key = "abcdefghijklmnopqrstuvwxyz"), :generic_api_key)
  end

  def test_generic_api_key_unquoted_shell_assignment_is_detected
    # YAML/.env/shell style without quotes is the most common form a
    # fix-agent would write — the pre-fix regex required literal quotes
    # and missed every unquoted assignment.
    assert_match_name("API_KEY=abcdefghijklmnopqrstuvwxyz", :generic_api_key)
  end

  def test_short_api_key_value_does_not_match
    refute_match_any("api_key = 'short'")
  end

  def test_pem_private_key_is_detected
    pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIBOgIBAAJBAK\n-----END RSA PRIVATE KEY-----"
    assert_match_name(pem, :pem_private_key)
  end

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

  def test_password_assignment_unquoted_is_detected
    assert_match_name("PASSWORD=hunter2spelledbackwards", :password_assignment)
  end

  def test_password_assignment_yaml_style_is_detected
    assert_match_name("password: s3cretpassphrase42", :password_assignment)
  end

  def test_short_password_value_does_not_match
    refute_match_any("password=abc")
  end

  def test_authorization_bearer_token_is_detected
    assert_match_name(
      "Authorization: Bearer abc123XYZdef456ghi789jklMNO",
      :bearer_token
    )
  end

  def test_authorization_basic_credentials_are_detected
    assert_match_name(
      "authorization: Basic dXNlcjpzdXBlcnNlY3JldHBhc3M=",
      :bearer_token
    )
  end

  def test_session_cookie_header_is_detected
    assert_match_name(
      "Cookie: sessionid=abcdef0123456789xyz; Path=/",
      :session_cookie
    )
  end

  def test_set_cookie_session_is_detected
    assert_match_name(
      "Set-Cookie: SID=abcdef0123456789xyz; HttpOnly",
      :session_cookie
    )
  end

  def test_github_token_is_detected
    assert_match_name("token = ghp_abcdefghijklmnopqrstuvwxyz0123456789", :github_token)
  end

  def test_scan_returns_empty_for_blank_input
    assert_empty Hive::SecretPatterns.scan("")
    assert_empty Hive::SecretPatterns.scan(nil)
  end

  # ── multi-pattern + truncation pinning ─────────────────────────────────

  def test_multi_pattern_input_returns_matches_for_each_pattern
    # An AWS access key AND an Anthropic API key in the same blob —
    # both must surface; neither pattern's scan can short-circuit.
    text = "AKIA1234567890123456 sk-ant-abcdefghijklmnopqrst"
    matches = Hive::SecretPatterns.scan(text)
    names = matches.map { |m| m[:name] }
    assert_includes names, :aws_access_key,
                    "AWS pattern must match in multi-pattern input"
    assert_includes names, :anthropic_api_key,
                    "Anthropic pattern must match in multi-pattern input"
  end

  # ── redact helper ──────────────────────────────────────────────────────

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

  def test_long_secret_is_truncated_in_snippet_per_eighty_char_rule
    # Long generic API key value (well over 80 chars) must be
    # truncated in `snippet` so callers can include the snippet in
    # error messages without leaking the full secret to logs.
    long_value = "a" * 100
    text = %(api_key = "#{long_value}")
    matches = Hive::SecretPatterns.scan(text)
    snippet = matches.find { |m| m[:name] == :generic_api_key }[:snippet]
    assert_operator snippet.length, :<=, 81,
                    "snippet truncated at 80 chars + ellipsis (= 81 max)"
    assert snippet.end_with?("…"),
           "truncated snippet ends with the ellipsis character"
  end
end
