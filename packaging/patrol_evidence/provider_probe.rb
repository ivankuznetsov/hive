# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "openssl"
require "uri"
require_relative "../../lib/hive/secret_patterns"

module HivePatrolEvidence
  # Owns one fixed OpenRouter authentication/transport probe and no Patrol decision.
  class ProviderProbe
    class Error < StandardError
      attr_reader :reason, :status

      def initialize(reason, message = reason, status: "failed")
        @reason = reason
        @status = status
        super(message)
      end
    end

    PROVIDER = "openrouter"
    ENDPOINT = "https://openrouter.ai/api/v1/chat/completions"
    MODEL = "openai/gpt-5.6-terra"
    CREDENTIAL = "OPENROUTER_API_KEY"
    EXPECTED_OUTPUT = "HIVE_PATROL_SMOKE_OK"
    PROMPT = "Reply with exactly #{EXPECTED_OUTPUT}.".freeze
    MAX_BODY_BYTES = 1024 * 1024
    TIMEOUT = 180
    OVERRIDE_ENV = %w[
      OPENROUTER_BASE_URL HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy
      SSL_CERT_FILE SSL_CERT_DIR NODE_EXTRA_CA_CERTS
    ].freeze
    OTHER_PROVIDER_CREDENTIALS = %w[OPENAI_API_KEY ANTHROPIC_API_KEY].freeze

    def initialize(environment: ENV.to_h, transport: nil)
      @environment = environment.to_h.transform_keys(&:to_s)
      @transport = transport || method(:request_once)
      @credential = nil
    rescue NoMethodError, TypeError
      raise Error.new("credential_custody", "provider environment is malformed"), cause: nil
    end

    def call
      admit_environment!
      @credential = @environment.fetch(CREDENTIAL, "").to_s
      if @credential.empty?
        raise Error.new("credential_unavailable", "selected provider credential is unavailable", status: "blocked")
      end
      raise Error.new("credential_custody", "selected provider credential is malformed") if
        @credential.bytesize > 16 * 1024 || @credential.include?("\0")

      request = fixed_request(@credential)
      response = @transport.call(request)
      admit_response(response)
    rescue Error
      raise
    rescue Timeout::Error, Net::OpenTimeout, Net::ReadTimeout, SocketError,
           Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::ETIMEDOUT
      raise Error.new("provider_unavailable", "provider is unavailable", status: "blocked"), cause: nil
    rescue SystemCallError, IOError
      raise Error.new("provider_unavailable", "provider is unavailable", status: "blocked"), cause: nil
    rescue StandardError
      raise Error.new("provider_transport", "provider transport failed"), cause: nil
    ensure
      @environment = nil
    end

    def validate_retained!(bytes)
      text = bytes.to_s
      leaked = @credential && !@credential.empty? && text.include?(@credential)
      leaked ||= Hive::SecretPatterns.match?(text)
      raise Error.new("credential_custody", "retained evidence contains credential-shaped bytes") if leaked
      true
    end

    private

    def admit_environment!
      override = OVERRIDE_ENV.any? { |key| !@environment.fetch(key, "").to_s.empty? }
      multiple = OTHER_PROVIDER_CREDENTIALS.any? { |key| !@environment.fetch(key, "").to_s.empty? }
      if override || multiple
        raise Error.new("credential_custody", "provider transport or credential selection is overridden")
      end
    end

    def fixed_request(secret)
      body = JSON.generate(
        "max_tokens" => 16,
        "messages" => [ { "content" => PROMPT, "role" => "user" } ],
        "model" => MODEL,
        "temperature" => 0
      )
      {
        uri: URI(ENDPOINT),
        headers: {
          "Accept" => "application/json",
          "Authorization" => "Bearer #{secret}",
          "Content-Type" => "application/json",
          "User-Agent" => "hive-patrol-installed-live-smoke/1"
        }.freeze,
        body: body.freeze,
        redirects: false,
        timeout: TIMEOUT,
        max_body_bytes: MAX_BODY_BYTES
      }.freeze
    end

    def request_once(request)
      uri = request.fetch(:uri)
      unless uri.scheme == "https" && uri.host == "openrouter.ai" &&
             uri.path == "/api/v1/chat/completions" && uri.query.nil?
        raise Error.new("provider_transport", "provider endpoint differs")
      end
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = TIMEOUT
      http.read_timeout = TIMEOUT
      http.write_timeout = TIMEOUT if http.respond_to?(:write_timeout=)
      message = Net::HTTP::Post.new(uri.request_uri, request.fetch(:headers))
      message.body = request.fetch(:body)
      body = +""
      response = http.request(message) do |incoming|
        incoming.read_body do |chunk|
          remaining = MAX_BODY_BYTES - body.bytesize
          raise Error.new("output_bound", "provider response exceeds its bound") if chunk.bytesize > remaining
          body << chunk
        end
      end
      {
        status: Integer(response.code, 10),
        content_type: response["Content-Type"].to_s,
        body: body
      }
    end

    def admit_response(response)
      unless response.is_a?(Hash) && response.keys.sort == %i[body content_type status]
        raise Error.new("provider_transport", "provider response envelope is malformed")
      end
      status = Integer(response.fetch(:status))
      if status == 429 || status >= 500
        raise Error.new("provider_unavailable", "provider is unavailable", status: "blocked")
      end
      raise Error.new("provider_transport", "provider returned an unsuccessful status") unless status == 200
      content_type = response.fetch(:content_type).to_s.downcase.split(";", 2).first.strip
      raise Error.new("provider_transport", "provider content type is unexpected") unless
        content_type == "application/json"
      body = response.fetch(:body).to_s
      raise Error.new("output_bound", "provider response exceeds its bound") if body.bytesize > MAX_BODY_BYTES
      if body.include?(@credential) || Hive::SecretPatterns.match?(body)
        raise Error.new("credential_custody", "provider response contains credential-shaped bytes")
      end
      document = JSON.parse(body)
      raise Error.new("provider_transport", "provider returned an error object") if document.key?("error")
      unless document.is_a?(Hash) && document.fetch("model") == MODEL &&
             document.fetch("choices").is_a?(Array) && !document.fetch("choices").empty? &&
             document.dig("choices", 0, "message", "content") == EXPECTED_OUTPUT
        raise Error.new("provider_transport", "provider success predicate did not match")
      end
      usage = document.fetch("usage")
      values = usage.values_at("prompt_tokens", "completion_tokens", "total_tokens")
      unless values.all? { |value| value.is_a?(Integer) && value.positive? } &&
             values.fetch(2) >= values.fetch(0) + values.fetch(1)
        raise Error.new("provider_transport", "provider usage is malformed")
      end
      {
        "status" => "passed",
        "provider" => PROVIDER,
        "model" => MODEL,
        "response_sha256" => Digest::SHA256.hexdigest(body),
        "usage" => {
          "prompt_tokens" => values.fetch(0),
          "completion_tokens" => values.fetch(1),
          "total_tokens" => values.fetch(2)
        }
      }.freeze
    rescue JSON::ParserError, KeyError, TypeError, ArgumentError
      raise Error.new("provider_transport", "provider response is malformed"), cause: nil
    end
  end
end
