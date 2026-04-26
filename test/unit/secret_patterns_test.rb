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
    assert_match_name("-----BEGIN RSA PRIVATE KEY-----", :pem_private_key)
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
