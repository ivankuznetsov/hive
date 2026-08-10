require_relative "test_helper"

class AgentCliRuntimeRedactorTest < Minitest::Test
  def test_redacts_long_complete_private_keys_without_leaking_the_body
    body = "A" * 8_000
    secret = <<~KEY
      -----BEGIN PRIVATE KEY-----
      #{body}
      -----END PRIVATE KEY-----
    KEY

    redacted = AgentCliRuntime::Redactor.redact("before\n#{secret}after")

    assert_equal "before\n[REDACTED:private_key]\nafter", redacted
    refute_includes redacted, body
  end

  def test_redacts_long_truncated_private_keys_through_the_end_of_input
    body = "B" * 8_000

    redacted = AgentCliRuntime::Redactor.redact(
      "before\n-----BEGIN OPENSSH PRIVATE KEY-----\n#{body}"
    )

    assert_equal "before\n[REDACTED:private_key_header]", redacted
    refute_includes redacted, body
  end

  def test_redacts_json_secrets_before_object_and_array_delimiters
    api_key = "api_" + ("a" * 40)
    password = "b" * 30
    input = %({"api_key":"#{api_key}","password":"#{password}"})

    redacted = AgentCliRuntime::Redactor.redact(input)

    assert_includes redacted, "[REDACTED:generic_api_key]"
    assert_includes redacted, "[REDACTED:password]"
    refute_includes redacted, api_key
    refute_includes redacted, password
  end
end
