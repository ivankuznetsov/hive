require "json"
require "stringio"
require "faraday"
require "faraday/multipart"

module Hive
  module Bot
    class Transcriber
      DEFAULT_CONFIG = {
        "endpoint" => "https://api.openai.com/v1/audio/transcriptions",
        "model" => "whisper-1",
        "api_key_env" => "HIVE_WHISPER_API_KEY",
        "max_retries" => 3,
        "retry_backoff_sec" => 2,
        "timeout_sec" => 120,
        "no_speech_threshold" => 0.6,
        "supported_languages" => %w[en ru]
      }.freeze

      Result = Data.define(:status, :text, :language, :error_class, :message) do
        def initialize(status:, text: nil, language: nil, error_class: nil, message: nil)
          super
        end
      end

      TRANSIENT_ERRORS = [
        Faraday::ConnectionFailed,
        Faraday::TimeoutError,
        Faraday::ServerError
      ].freeze

      def initialize(config:, logger:, http_client: nil, env: ENV, sleep_proc: ->(sec) { sleep(sec) })
        @config = DEFAULT_CONFIG.merge(config || {})
        @logger = logger
        @http_client = http_client
        @env = env
        @sleep_proc = sleep_proc
      end

      def call(bytes, filename:, content_type:)
        attempts = 0
        begin
          attempts += 1
          response = post(bytes, filename: filename, content_type: content_type)
          return parse_response(response) if success?(response)
          return failed("HTTPError", "transcription returned HTTP #{status(response)}") unless transient_status?(response)

          raise TransientHttpError, "transcription returned HTTP #{status(response)}"
        rescue *TRANSIENT_ERRORS, TransientHttpError => e
          retry if retry_after?(attempts)

          log_failure(e)
          Result.new(status: :failed, error_class: e.class.name, message: e.message)
        rescue JSON::ParserError => e
          log_failure(e)
          Result.new(status: :failed, error_class: e.class.name, message: e.message)
        rescue StandardError => e
          log_failure(e)
          Result.new(status: :failed, error_class: e.class.name, message: e.message)
        end
      end

      private

      class TransientHttpError < StandardError; end

      def post(bytes, filename:, content_type:)
        client.post(endpoint) do |req|
          req.headers["Authorization"] = "Bearer #{api_key}"
          req.headers["Content-Type"] = "multipart/form-data"
          req.options.timeout = timeout_sec if req.respond_to?(:options) && req.options.respond_to?(:timeout=)
          req.body = {
            file: Faraday::Multipart::FilePart.new(StringIO.new(bytes.to_s.b), content_type, filename),
            model: model,
            response_format: "verbose_json"
          }
        end
      end

      def client
        @http_client ||= Faraday.new do |faraday|
          faraday.request :multipart
          faraday.response :raise_error
        end
      end

      def parse_response(response)
        data = JSON.parse(body(response).to_s)
        text = data["text"].to_s.strip
        return Result.new(status: :no_speech, text: text, language: data["language"]) if no_speech?(data, text)

        language = data["language"].to_s.strip
        if unsupported_language?(language)
          return Result.new(status: :unsupported_language, text: text, language: language)
        end

        Result.new(status: :ok, text: text, language: language)
      end

      def no_speech?(data, text)
        return true if text.empty?

        probs = Array(data["segments"]).filter_map do |segment|
          next unless segment.is_a?(Hash) && segment.key?("no_speech_prob")

          Float(segment["no_speech_prob"])
        rescue ArgumentError, TypeError
          nil
        end
        return false if probs.empty?

        (probs.sum / probs.length) >= no_speech_threshold
      end

      def unsupported_language?(language)
        supported = Array(@config["supported_languages"]).map(&:to_s).reject(&:empty?)
        !supported.empty? && !supported.include?(language)
      end

      def retry_after?(attempts)
        return false if attempts > max_retries

        @sleep_proc.call(retry_backoff_sec) if retry_backoff_sec.positive?
        true
      end

      def success?(response)
        status(response) >= 200 && status(response) < 300
      end

      def transient_status?(response)
        status(response) >= 500
      end

      def status(response)
        value(response, :status).to_i
      end

      def body(response)
        value(response, :body)
      end

      def value(object, key)
        return nil if object.nil?
        return object[key] || object[key.to_s] if object.is_a?(Hash)
        return object.public_send(key) if object.respond_to?(key)

        nil
      end

      def failed(error_class, message)
        @logger&.event(:send_failure, source: "transcribe_voice",
                                      error_class: error_class,
                                      message: message)
        Result.new(status: :failed, error_class: error_class, message: message)
      end

      def log_failure(error)
        @logger&.event(:send_failure, source: "transcribe_voice",
                                      error_class: error.class.name,
                                      message: error.message)
      end

      def endpoint = @config.fetch("endpoint")
      def model = @config.fetch("model")
      def api_key = @env.fetch(@config.fetch("api_key_env"), "")
      def max_retries = @config.fetch("max_retries").to_i
      def retry_backoff_sec = @config.fetch("retry_backoff_sec").to_i
      def timeout_sec = @config.fetch("timeout_sec").to_i
      def no_speech_threshold = @config.fetch("no_speech_threshold").to_f
    end
  end
end
