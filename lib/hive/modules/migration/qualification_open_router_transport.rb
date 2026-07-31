require "json"
require "net/http"
require "openssl"
require "timeout"
require "uri"
require "hive/errors"
require "hive/modules/migration/qualification_provider_protocol"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      # Fixed, host-only OpenRouter adapter for Patrol qualification. It owns
      # the credential and destination, performs one bounded request, and
      # exposes only canonical model content plus numeric usage to the broker.
      class QualificationOpenRouterTransport
        ENDPOINT =
          URI("https://openrouter.ai/api/v1/chat/completions").freeze
        MODEL = "openai/gpt-5.6-terra".freeze
        MAX_OUTPUT_TOKENS = 8_192
        MAX_RESPONSE_BYTES = 192 * 1024
        MIN_TIMEOUT_SECONDS = 0.1
        MAX_TIMEOUT_SECONDS = 300.0

        Result = Data.define(
          :content, :input_tokens, :output_tokens
        )

        class Failure < Hive::ConfigError
          attr_reader :reason, :retryable

          def initialize(reason:, retryable:)
            @reason = reason.to_s.freeze
            @retryable = retryable == true
            super("patrol qualification provider request failed")
          end
        end

        def initialize(
          api_key:, model: MODEL, endpoint: ENDPOINT,
          http_factory: ->(host, port) { Net::HTTP.new(host, port) }
        )
          @api_key = api_key.to_s
          @model = model.to_s
          @endpoint = endpoint.is_a?(URI) ?
            endpoint : URI(endpoint.to_s)
          @http_factory = http_factory
          validate_configuration!
        rescue URI::InvalidURIError
          configuration_error!
        end

        attr_reader :model

        def call(prompt:, kind:, timeout_seconds:)
          timeout = bounded_timeout(timeout_seconds)
          request = Net::HTTP::Post.new(@endpoint.request_uri)
          request["Authorization"] = "Bearer #{@api_key}"
          request["Content-Type"] = "application/json"
          request["Accept"] = "application/json"
          request["X-OpenRouter-Cache"] = "true"
          request.body = canonical(
            "model" => @model,
            "messages" => [
              {
                "role" => "system",
                "content" => system_instruction(kind)
              },
              {
                "role" => "user",
                "content" => prompt.to_s
              }
            ],
            "response_format" => { "type" => "json_object" },
            "max_tokens" => MAX_OUTPUT_TOKENS,
            "temperature" => 0,
            "seed" => 0
          )
          http = @http_factory.call(
            @endpoint.host, @endpoint.port
          )
          http.use_ssl = true
          http.open_timeout = timeout
          http.read_timeout = timeout
          http.write_timeout = timeout if
            http.respond_to?(:write_timeout=)
          response = nil
          bytes = +"".b
          http.start do |connection|
            connection.request(request) do |incoming|
              response = incoming
              declared = incoming["Content-Length"]
              if declared &&
                 Integer(declared, 10) > MAX_RESPONSE_BYTES
                fail_with!(
                  "provider_response_malformed",
                  retryable: false
                )
              end
              incoming.read_body do |chunk|
                bytes << chunk
                if bytes.bytesize > MAX_RESPONSE_BYTES
                  fail_with!(
                    "provider_response_malformed",
                    retryable: false
                  )
                end
              end
            end
          end
          classify_status!(response.code.to_i)
          parse_result(bytes)
        rescue Failure
          raise
        rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
          fail_with!("provider_timeout", retryable: true)
        rescue IOError, SocketError, SystemCallError,
               OpenSSL::SSL::SSLError
          fail_with!("provider_transport_failed", retryable: true)
        rescue ArgumentError, TypeError
          fail_with!("provider_response_malformed", retryable: false)
        ensure
          request&.[]=("Authorization", "Bearer [REDACTED]")
        end

        private

        def validate_configuration!
          unless
            !@api_key.empty? &&
              @model ==
                QualificationOpenRouterTransport::MODEL &&
              @endpoint == ENDPOINT &&
              @endpoint.scheme == "https" &&
              @http_factory.respond_to?(:call)
            configuration_error!
          end
        end

        def configuration_error!
          raise Hive::ConfigError,
                "patrol qualification provider configuration is malformed"
        end

        def bounded_timeout(value)
          timeout = Float(value)
          unless
            timeout.finite? &&
              timeout.between?(
                MIN_TIMEOUT_SECONDS,
                MAX_TIMEOUT_SECONDS
              )
            fail_with!("provider_timeout", retryable: true)
          end
          timeout
        rescue ArgumentError, TypeError
          fail_with!("provider_timeout", retryable: true)
        end

        def system_instruction(kind)
          root =
            QualificationProviderProtocol::KINDS
              .fetch(kind.to_s)
              .fetch(:root_key)
          "Return only one JSON object whose sole top-level key is " \
            "#{root.inspect} and whose value is an array. Follow the " \
            "user prompt's exact item schema. Do not use markdown."
        rescue KeyError
          fail_with!(
            "session_protocol_violation",
            retryable: false
          )
        end

        def classify_status!(status)
          return if status.between?(200, 299)

          case status
          when 401, 403
            fail_with!(
              "provider_authentication_failed",
              retryable: true
            )
          when 402
            fail_with!(
              "provider_credit_exhausted",
              retryable: true
            )
          when 408, 504
            fail_with!("provider_timeout", retryable: true)
          when 429
            fail_with!(
              "provider_rate_limited",
              retryable: true
            )
          when 500..599
            fail_with!(
              "provider_unavailable",
              retryable: true
            )
          else
            fail_with!(
              "provider_transport_failed",
              retryable: false
            )
          end
        end

        def parse_result(bytes)
          value = JSON.parse(bytes)
          unless
            value.is_a?(Hash) &&
              value.fetch("model") == @model
            fail_with!(
              "provider_response_malformed",
              retryable: false
            )
          end
          choices = value.fetch("choices")
          content =
            choices.fetch(0).fetch("message").fetch("content")
          usage = value.fetch("usage")
          input = Integer(usage.fetch("prompt_tokens"))
          output = Integer(usage.fetch("completion_tokens"))
          unless
            choices.length == 1 &&
              content.is_a?(String) &&
              !content.empty? &&
              content.bytesize <= MAX_RESPONSE_BYTES &&
              input.between?(0, 100_000) &&
              output.between?(0, MAX_OUTPUT_TOKENS)
            fail_with!(
              "provider_response_malformed",
              retryable: false
            )
          end
          Result.new(
            content: content.b.freeze,
            input_tokens: input,
            output_tokens: output
          ).freeze
        rescue JSON::ParserError, KeyError, IndexError,
               ArgumentError, TypeError
          fail_with!(
            "provider_response_malformed",
            retryable: false
          )
        end

        def canonical(value)
          Hive::WorkflowPackage::CanonicalJSON.generate(value)
        end

        def fail_with!(reason, retryable:)
          raise Failure.new(
            reason: reason,
            retryable: retryable
          )
        end
      end
    end
  end
end
