require "test_helper"
require "digest"
require "json"
require_relative "../../../packaging/patrol_evidence/provider_probe"

class PatrolEvidenceProviderProbeTest < Minitest::Test
  Probe = HivePatrolEvidence::ProviderProbe

  def test_one_fixed_request_has_a_closed_success_predicate_and_retains_no_text
    secret = "openrouter-secret-that-must-not-be-retained"
    requests = []
    response = {
      status: 200, content_type: "application/json",
      body: JSON.generate(
        "model" => Probe::MODEL,
        "choices" => [ { "message" => { "content" => Probe::EXPECTED_OUTPUT } } ],
        "usage" => { "prompt_tokens" => 4, "completion_tokens" => 2, "total_tokens" => 6 }
      )
    }
    probe = Probe.new(
      environment: { "OPENROUTER_API_KEY" => secret },
      transport: ->(request) { requests << request; response }
    )

    receipt = probe.call

    assert_equal 1, requests.size
    assert_equal URI(Probe::ENDPOINT), requests.first.fetch(:uri)
    assert_equal "Bearer #{secret}", requests.first.dig(:headers, "Authorization")
    assert_equal "passed", receipt.fetch("status")
    assert_equal Digest::SHA256.hexdigest(response.fetch(:body)), receipt.fetch("response_sha256")
    refute_includes JSON.generate(receipt), secret
    refute_includes JSON.generate(receipt), Probe::EXPECTED_OUTPUT
    assert probe.validate_retained!(JSON.generate(receipt))
  end

  def test_override_and_multiple_credential_checks_precede_transport
    called = false
    {
      "HTTPS_PROXY" => "https://proxy.invalid",
      "OPENROUTER_BASE_URL" => "https://evil.invalid",
      "SSL_CERT_FILE" => "/tmp/ca",
      "OPENAI_API_KEY" => "another-provider-secret"
    }.each do |key, value|
      probe = Probe.new(
        environment: { "OPENROUTER_API_KEY" => "selected-secret", key => value },
        transport: ->(*) { called = true }
      )
      error = assert_raises(Probe::Error, key) { probe.call }
      assert_equal "credential_custody", error.reason
    end
    refute called
  end

  def test_provider_unavailability_and_false_success_never_become_a_skip
    missing = Probe.new(environment: {}, transport: ->(*) { flunk("transport must not run") })
    error = assert_raises(Probe::Error) { missing.call }
    assert_equal "credential_unavailable", error.reason
    assert_equal "blocked", error.status

    malformed = Probe.new(
      environment: { "OPENROUTER_API_KEY" => "selected-secret" },
      transport: ->(*) do
        { status: 200, content_type: "application/json",
          body: JSON.generate("model" => Probe::MODEL, "choices" => [],
                              "usage" => { "total_tokens" => 0 }) }
      end
    )
    error = assert_raises(Probe::Error) { malformed.call }
    assert_equal "provider_transport", error.reason
    assert_equal "failed", error.status
  end
end
