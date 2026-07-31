require "test_helper"
require "json"
require "hive/modules/migration/qualification_open_router_transport"

class ModulesMigrationQualificationOpenRouterTransportTest <
    Minitest::Test
  TRANSPORT =
    Hive::Modules::Migration::QualificationOpenRouterTransport

  FakeResponse = Data.define(:code, :headers, :chunks) do
    def [](name) = headers[name]

    def read_body
      chunks.each { |chunk| yield chunk }
    end
  end

  class FakeHTTP
    attr_accessor(
      :open_timeout, :read_timeout, :use_ssl, :write_timeout
    )
    attr_reader :requests

    def initialize(response)
      @response = response
      @requests = []
    end

    def start
      yield self
    end

    def request(request)
      @requests << {
        authorization: request["Authorization"],
        cache: request["X-OpenRouter-Cache"],
        content_type: request["Content-Type"],
        path: request.path,
        body: request.body
      }.freeze
      yield @response
    end
  end

  def test_uses_only_the_fixed_endpoint_model_and_bounded_json_contract
    http = FakeHTTP.new(
      response(
        body: JSON.generate(
          "model" => TRANSPORT::MODEL,
          "choices" => [
            {
              "message" => {
                "content" => "{\"findings\":[]}"
              }
            }
          ],
          "usage" => {
            "prompt_tokens" => 19,
            "completion_tokens" => 5
          }
        )
      )
    )
    transport = build_transport(http)

    result = transport.call(
      prompt: "Review the candidate",
      kind: "ordinary_findings",
      timeout_seconds: 12
    )

    assert_equal "{\"findings\":[]}", result.content
    assert_equal 19, result.input_tokens
    assert_equal 5, result.output_tokens
    request = http.requests.fetch(0)
    assert_equal "Bearer provider-token",
                 request.fetch(:authorization)
    assert_equal "true", request.fetch(:cache)
    assert_equal "application/json",
                 request.fetch(:content_type)
    assert_equal "/api/v1/chat/completions",
                 request.fetch(:path)
    body = JSON.parse(request.fetch(:body))
    assert_equal TRANSPORT::MODEL, body.fetch("model")
    assert_equal TRANSPORT::MAX_OUTPUT_TOKENS,
                 body.fetch("max_tokens")
    assert_equal 0, body.fetch("temperature")
    assert_equal 0, body.fetch("seed")
    assert_equal(
      { "type" => "json_object" },
      body.fetch("response_format")
    )
    assert_equal "Review the candidate",
                 body.dig("messages", 1, "content")
    assert_equal true, http.use_ssl
    assert_equal 12.0, http.open_timeout
    assert_equal 12.0, http.read_timeout
    assert_equal 12.0, http.write_timeout
  end

  def test_maps_retryable_provider_statuses_to_closed_reasons
    {
      401 => "provider_authentication_failed",
      402 => "provider_credit_exhausted",
      408 => "provider_timeout",
      429 => "provider_rate_limited",
      503 => "provider_unavailable"
    }.each do |status, reason|
      error = assert_raises(TRANSPORT::Failure) do
        build_transport(
          FakeHTTP.new(
            response(
              status: status,
              body: "provider secret diagnostic prose"
            )
          )
        ).call(
          prompt: "review",
          kind: "ordinary_findings",
          timeout_seconds: 1
        )
      end

      assert_equal reason, error.reason
      assert_equal true, error.retryable
      refute_includes error.message, "secret diagnostic"
    end
  end

  def test_rejects_wrong_model_malformed_usage_and_oversized_responses
    bodies = [
      JSON.generate(
        "model" => "openai/other-model",
        "choices" => [
          { "message" => { "content" => "{\"findings\":[]}" } }
        ],
        "usage" => {
          "prompt_tokens" => 1,
          "completion_tokens" => 1
        }
      ),
      JSON.generate(
        "model" => TRANSPORT::MODEL,
        "choices" => [
          { "message" => { "content" => "{\"findings\":[]}" } }
        ],
        "usage" => {
          "prompt_tokens" => -1,
          "completion_tokens" => 1
        }
      )
    ]
    bodies.each do |body|
      error = assert_raises(TRANSPORT::Failure) do
        build_transport(
          FakeHTTP.new(response(body: body))
        ).call(
          prompt: "review",
          kind: "ordinary_findings",
          timeout_seconds: 1
        )
      end

      assert_equal "provider_response_malformed", error.reason
      assert_equal false, error.retryable
    end

    oversized = response(
      body: "{}",
      headers: {
        "Content-Length" =>
          (TRANSPORT::MAX_RESPONSE_BYTES + 1).to_s
      }
    )
    error = assert_raises(TRANSPORT::Failure) do
      build_transport(FakeHTTP.new(oversized)).call(
        prompt: "review",
        kind: "ordinary_findings",
        timeout_seconds: 1
      )
    end
    assert_equal "provider_response_malformed", error.reason
    assert_equal false, error.retryable
  end

  def test_rejects_any_configuration_override
    [
      { api_key: "" },
      { api_key: "token", model: "openai/other-model" },
      {
        api_key: "token",
        endpoint: "https://example.com/v1/chat/completions"
      }
    ].each do |options|
      assert_raises(Hive::ConfigError) do
        TRANSPORT.new(**options)
      end
    end
  end

  private

  def build_transport(http)
    TRANSPORT.new(
      api_key: "provider-token",
      http_factory: ->(_host, _port) { http }
    )
  end

  def response(status: 200, body:, headers: {})
    FakeResponse.new(
      code: status.to_s,
      headers: headers.freeze,
      chunks: [ body.b ].freeze
    ).freeze
  end
end
