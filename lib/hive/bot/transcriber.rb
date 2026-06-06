require "json"
require "stringio"
require "faraday"
require "faraday/multipart"
require "hive/config"
require "hive/bot/languages"

module Hive
  module Bot
    class Transcriber
      # Single source of truth for transcription defaults: the global bot
      # config block. Deriving from Hive::Config::DEFAULTS keeps this fallback
      # from drifting away from config.rb key-for-key. In production the
      # supervisor injects the full merged config, so this only fills gaps for
      # partial configs and tests. The extra "enabled" key it carries is
      # ignored here (the supervisor owns the enabled gate).
      DEFAULT_CONFIG = Hive::Config::DEFAULTS.fetch("bot").fetch("transcription").dup.freeze

      # Raised when a 5xx response should be retried through the transient
      # path. Declared up top so its raise (in #call) and rescue read in
      # source order.
      class TransientHttpError < StandardError; end

      Result = Data.define(:status, :text, :language, :error_class, :message) do
        # The legal status set lives on the data type itself, so Result is
        # self-documenting and validates against its own enumeration.
        STATUSES = %i[ok no_speech unsupported_language failed].freeze

        def initialize(status:, text: nil, language: nil, error_class: nil, message: nil)
          unless STATUSES.include?(status)
            raise ArgumentError, "unknown transcription status #{status.inspect}"
          end
          if status == :ok && text.to_s.strip.empty?
            raise ArgumentError, ":ok transcription requires non-empty text"
          end
          # Inverse invariants: a failure carries no transcript, the success
          # and benign outcomes carry no error metadata, and a failure must
          # explain itself. Keeps the four statuses from quietly representing
          # contradictory states.
          if status == :failed && !text.to_s.strip.empty?
            raise ArgumentError, ":failed transcription must not carry text"
          end
          if status == :failed && error_class.to_s.strip.empty? && message.to_s.strip.empty?
            raise ArgumentError, ":failed transcription requires error_class or message"
          end
          if %i[ok no_speech unsupported_language].include?(status) && (error_class || message)
            raise ArgumentError, "#{status.inspect} transcription must not carry error_class/message"
          end

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
          # 4xx (bad key, rate-limit, too-large) is not retried and must stay
          # distinct from a transient 5xx. The default client no longer raises
          # on status (no :raise_error middleware), so this branch runs in
          # production exactly as it does under the injected test client.
          # Whisper/OpenAI puts the actual reason (invalid_api_key,
          # file-too-large) in the 4xx body, so append a truncated copy —
          # without it the log reads "HTTP 400" with no way to know why.
          unless transient_status?(response)
            return failed("HTTPError", "transcription returned HTTP #{status(response)}#{response_body_hint(response)}")
          end

          raise TransientHttpError, "transcription returned HTTP #{status(response)}"
        rescue *TRANSIENT_ERRORS, TransientHttpError => e
          if retry?(attempts)
            sleep_before_retry
            retry
          end

          log_failure(e, attempts: attempts)
          Result.new(status: :failed, error_class: e.class.name, message: e.message)
        rescue Faraday::Error, JSON::ParserError => e
          # Expected transport/parse failures only. A programmer error
          # (NoMethodError, ArgumentError) is intentionally NOT rescued here so
          # genuine defects surface as a crash instead of a user-facing
          # "Couldn't transcribe".
          log_failure(e)
          Result.new(status: :failed, error_class: e.class.name, message: e.message)
        end
      end

      private

      def post(bytes, filename:, content_type:)
        client.post(endpoint) do |req|
          req.headers["Authorization"] = "Bearer #{api_key}"
          # No manual Content-Type header: the :multipart middleware sets it
          # with the boundary the server needs. A hand-set value here would be
          # overwritten anyway.
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
          # Intentionally NO `response :raise_error`: #call inspects the status
          # directly so the 4xx-vs-5xx handling tested with the fake client is
          # the same code that runs in production.
        end
      end

      def parse_response(response)
        data = JSON.parse(body(response).to_s)
        text = data["text"].to_s.strip
        language = data["language"].to_s.strip
        return Result.new(status: :no_speech, text: text, language: language) if no_speech?(data, text)

        if unsupported_language?(language)
          return Result.new(status: :unsupported_language, text: text, language: language)
        end

        Result.new(status: :ok, text: text, language: language)
      end

      def no_speech?(data, text)
        return true if text.empty?

        # Unweighted mean of per-segment no_speech_prob: every segment counts
        # equally regardless of its duration, so a short silent segment can
        # weigh as much as a long spoken one. A clip with a few very-high-prob
        # segments but a low mean won't trip the threshold — that's the
        # intended, threshold-tunable (no_speech_threshold) heuristic; revisit
        # with duration weighting only if misclassification shows up.
        probs = Array(data["segments"]).filter_map { |segment| segment_no_speech_prob(segment) }
        return false if probs.empty?

        (probs.sum / probs.length) >= no_speech_threshold
      end

      def segment_no_speech_prob(segment)
        return nil unless segment.is_a?(Hash) && segment.key?("no_speech_prob")

        Float(segment["no_speech_prob"])
      rescue ArgumentError, TypeError
        # A malformed prob is dropped from the mean rather than crashing the
        # whole transcript. Log it so an all-malformed clip (which then reads
        # as speech via the empty-probs return) is debuggable.
        @logger&.event(:transcription_failed, source: "transcribe_voice",
                                              error_class: "MalformedSegment",
                                              message: "non-numeric no_speech_prob: #{segment["no_speech_prob"].inspect}")
        nil
      end

      def unsupported_language?(language)
        supported = Array(@config["supported_languages"]).filter_map { |entry| normalize_language(entry) }
        return false if supported.empty?

        !supported.include?(normalize_language(language))
      end

      # Whisper's verbose_json reports `language` as a full English name
      # ("english", "russian"), not an ISO code, while operators configure
      # supported_languages as ISO codes ("en", "ru"). Normalize both sides
      # through the canonical map so the gate accepts either form. Unmapped
      # tokens compare lowercased and as-is, so a config written with full
      # names (or an exotic language) still works.
      def normalize_language(language)
        token = language.to_s.strip.downcase
        return nil if token.empty?

        Hive::Bot::Languages::NAME_TO_ISO.fetch(token, token)
      end

      def retry?(attempts)
        attempts <= max_retries
      end

      def sleep_before_retry
        @sleep_proc.call(retry_backoff_sec) if retry_backoff_sec.positive?
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

      # A short, log-safe slice of a 4xx response body. The provider returns
      # the human reason here (invalid_api_key, file-too-large); truncate so a
      # large/odd body can't bloat the log line. Empty bodies add nothing.
      def response_body_hint(response)
        text = body(response).to_s.strip
        return "" if text.empty?

        " - #{text[0, 200]}"
      end

      def value(object, key)
        return nil if object.nil?
        return object[key] || object[key.to_s] if object.is_a?(Hash)
        return object.public_send(key) if object.respond_to?(key)

        nil
      end

      def failed(error_class, message)
        @logger&.event(:transcription_failed, source: "transcribe_voice",
                                              error_class: error_class,
                                              message: message)
        Result.new(status: :failed, error_class: error_class, message: message)
      end

      def log_failure(error, attempts: nil)
        attrs = { source: "transcribe_voice", error_class: error.class.name, message: error.message }
        # On retry exhaustion record how many attempts were burned, so a
        # one-shot failure is distinguishable from one that spent
        # max_retries × backoff.
        attrs[:attempts] = attempts if attempts
        @logger&.event(:transcription_failed, **attrs)
      end

      def endpoint = @config.fetch("endpoint")
      def model = @config.fetch("model")

      # A missing secret would otherwise go out as "Authorization: Bearer " and
      # come back as a generic 401, indistinguishable from a transient upstream
      # error. Emit a distinct "api key not configured" signal at call time so
      # the misconfiguration is greppable rather than buried in HTTP noise.
      def api_key
        key = @env.fetch(@config.fetch("api_key_env"), "")
        if key.to_s.strip.empty?
          @logger&.event(:transcription_failed, source: "transcribe_voice",
                                                error_class: "ApiKeyNotConfigured",
                                                message: "transcription api key env #{@config.fetch("api_key_env").inspect} is unset")
        end
        key
      end
      def max_retries = @config.fetch("max_retries").to_i
      def retry_backoff_sec = @config.fetch("retry_backoff_sec").to_i
      def timeout_sec = @config.fetch("timeout_sec").to_i
      def no_speech_threshold = @config.fetch("no_speech_threshold").to_f
    end
  end
end
