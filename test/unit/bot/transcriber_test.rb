require "test_helper"
require "hive/bot/transcriber"

class HiveBotTranscriberTest < Minitest::Test
  Response = Struct.new(:status, :body, keyword_init: true)

  class FakeRequest
    attr_reader :headers
    attr_accessor :body

    def initialize
      @headers = {}
      @options = Struct.new(:timeout, :open_timeout).new
    end

    def options
      @options
    end
  end

  class FakeHttp
    attr_reader :calls

    def initialize(responses)
      @responses = responses.dup
      @calls = []
    end

    def post(url)
      request = FakeRequest.new
      yield request
      @calls << { url: url, headers: request.headers.dup, body: request.body,
                  timeout: request.options.timeout, open_timeout: request.options.open_timeout }
      response = @responses.shift
      raise response if response.is_a?(Exception)

      response
    end
  end

  class StubLogger
    attr_reader :events

    def initialize
      @events = []
    end

    def event(name, **attrs)
      @events << [ name, attrs ]
    end
  end

  def setup
    @logger = StubLogger.new
    @env = { "HIVE_WHISPER_API_KEY" => "sk-test-secret" }
    @sleeps = []
  end

  def transcriber(http, config = {})
    Hive::Bot::Transcriber.new(
      config: {
        "endpoint" => "https://whisper.test/v1/audio/transcriptions",
        "model" => "whisper-test",
        "api_key_env" => "HIVE_WHISPER_API_KEY",
        "max_retries" => 3,
        "retry_backoff_sec" => 0,
        "timeout_sec" => 120,
        "no_speech_threshold" => 0.6,
        "supported_languages" => %w[en ru]
      }.merge(config),
      logger: @logger,
      http_client: http,
      env: @env,
      sleep_proc: ->(sec) { @sleeps << sec }
    )
  end

  # Whisper verbose_json returns the language as a full English name
  # ("english"), never the ISO code "en" — the fixtures use that realistic
  # value so the language gate can no longer be masked by a value the real
  # API never emits.
  def test_ok_transcribes_text_and_sends_auth_header
    http = FakeHttp.new([
      Response.new(status: 200, body: JSON.generate("text" => " capture this ", "language" => "english"))
    ])

    result = transcriber(http).call("bytes", filename: "voice.oga", content_type: "audio/ogg")

    assert_equal :ok, result.status
    assert_equal "capture this", result.text
    assert_equal "english", result.language
    assert_equal "Bearer sk-test-secret", http.calls.first.fetch(:headers).fetch("Authorization")
    assert_equal "whisper-test", http.calls.first.fetch(:body).fetch(:model)
    assert_equal "verbose_json", http.calls.first.fetch(:body).fetch(:response_format)
    assert_equal 120, http.calls.first.fetch(:timeout)
    assert_equal 10, http.calls.first.fetch(:open_timeout),
                 "open_timeout must bound the TCP connect so a hung connect can't stall the poll thread"
  end

  def test_full_language_name_is_accepted_against_iso_supported_list
    http = FakeHttp.new([
      Response.new(status: 200, body: JSON.generate("text" => "privet", "language" => "russian"))
    ])

    result = transcriber(http).call("bytes", filename: "voice.oga", content_type: "audio/ogg")

    assert_equal :ok, result.status, "full-name 'russian' should match ISO 'ru' in supported_languages"
    assert_equal "privet", result.text
  end

  def test_high_no_speech_probability_returns_no_speech
    http = FakeHttp.new([
      Response.new(status: 200, body: JSON.generate(
        "text" => "noise",
        "language" => "english",
        "segments" => [ { "no_speech_prob" => 0.8 }, { "no_speech_prob" => 0.7 } ]
      ))
    ])

    result = transcriber(http).call("bytes", filename: "voice.oga", content_type: "audio/ogg")

    assert_equal :no_speech, result.status
  end

  def test_malformed_no_speech_probability_is_logged_and_ignored
    http = FakeHttp.new([
      Response.new(status: 200, body: JSON.generate(
        "text" => "speech",
        "language" => "english",
        "segments" => [ { "no_speech_prob" => "abc" }, { "no_speech_prob" => 0.1 } ]
      ))
    ])

    result = transcriber(http).call("bytes", filename: "voice.oga", content_type: "audio/ogg")

    assert_equal :ok, result.status
    assert(@logger.events.any? do |event, attrs|
      event == :transcription_failed && attrs[:error_class] == "MalformedSegment"
    end)
  end

  def test_low_no_speech_probability_returns_ok
    http = FakeHttp.new([
      Response.new(status: 200, body: JSON.generate(
        "text" => "real speech here",
        "language" => "english",
        "segments" => [ { "no_speech_prob" => 0.1 }, { "no_speech_prob" => 0.2 } ]
      ))
    ])

    result = transcriber(http).call("bytes", filename: "voice.oga", content_type: "audio/ogg")

    assert_equal :ok, result.status, "mean below no_speech_threshold (0.6) must transcribe, not drop as no_speech"
    assert_equal "real speech here", result.text
  end

  def test_empty_text_returns_no_speech
    http = FakeHttp.new([
      Response.new(status: 200, body: JSON.generate("text" => "   ", "language" => "en"))
    ])

    result = transcriber(http).call("bytes", filename: "voice.oga", content_type: "audio/ogg")

    assert_equal :no_speech, result.status
  end

  def test_unsupported_language_returns_unsupported_language
    http = FakeHttp.new([
      Response.new(status: 200, body: JSON.generate("text" => "guten tag", "language" => "de"))
    ])

    result = transcriber(http).call("bytes", filename: "voice.oga", content_type: "audio/ogg")

    assert_equal :unsupported_language, result.status
    assert_equal "de", result.language
  end

  def test_empty_supported_languages_accepts_any_language
    http = FakeHttp.new([
      Response.new(status: 200, body: JSON.generate("text" => "guten tag", "language" => "de"))
    ])

    result = transcriber(http, "supported_languages" => []).call("bytes", filename: "voice.oga",
                                                                 content_type: "audio/ogg")

    assert_equal :ok, result.status
    assert_equal "de", result.language
  end

  def test_retries_transient_5xx_then_succeeds
    http = FakeHttp.new([
      Response.new(status: 503, body: "unavailable"),
      Response.new(status: 503, body: "unavailable"),
      Response.new(status: 200, body: JSON.generate("text" => "done", "language" => "english"))
    ])

    result = transcriber(http).call("bytes", filename: "voice.oga", content_type: "audio/ogg")

    assert_equal :ok, result.status
    assert_equal "done", result.text
    assert_equal 3, http.calls.size
  end

  def test_backoff_sleep_runs_between_retries
    http = FakeHttp.new([
      Response.new(status: 503, body: "unavailable"),
      Response.new(status: 503, body: "unavailable"),
      Response.new(status: 200, body: JSON.generate("text" => "done", "language" => "english"))
    ])

    result = transcriber(http, "retry_backoff_sec" => 2).call("bytes", filename: "voice.oga",
                                                              content_type: "audio/ogg")

    assert_equal :ok, result.status
    # One sleep before each of the two retries; dropping the backoff (and
    # hammering Whisper) would leave @sleeps empty and fail here.
    assert_equal [ 2, 2 ], @sleeps, "expected a backoff sleep before each retry"
  end

  def test_persistent_500_fails_after_retries
    http = FakeHttp.new([
      Response.new(status: 500, body: "no"),
      Response.new(status: 500, body: "no"),
      Response.new(status: 500, body: "no")
    ])

    result = transcriber(http, "max_retries" => 2).call("bytes", filename: "voice.oga",
                                                        content_type: "audio/ogg")

    assert_equal :failed, result.status
    assert_equal 3, http.calls.size
    assert_equal :transcription_failed, @logger.events.first.first
    refute_includes @logger.events.inspect, "sk-test-secret"
  end

  def test_malformed_json_fails
    http = FakeHttp.new([ Response.new(status: 200, body: "{") ])

    result = transcriber(http).call("bytes", filename: "voice.oga", content_type: "audio/ogg")

    assert_equal :failed, result.status
    assert_equal "JSON::ParserError", result.error_class
    refute_includes @logger.events.inspect, "sk-test-secret", "API key must never be logged on the malformed-JSON path"
  end

  # Directly exercise Result's self-validating invariants so a refactor that
  # loosens any guard fails here, not silently downstream in parse_response.
  def test_result_rejects_contradictory_states
    cases = {
      "unknown status" => { status: :bogus },
      ":ok with empty text" => { status: :ok, text: "  " },
      ":failed carrying text" => { status: :failed, text: "oops", message: "boom" },
      ":failed without error_class or message" => { status: :failed },
      "benign status carrying error metadata" => { status: :no_speech, error_class: "X" }
    }

    cases.each do |label, kwargs|
      assert_raises(ArgumentError, "Result should reject: #{label}") do
        Hive::Bot::Transcriber::Result.new(**kwargs)
      end
    end
  end

  def test_non_transient_400_fails_without_retry
    http = FakeHttp.new([ Response.new(status: 400, body: "invalid_api_key") ])

    result = transcriber(http).call("bytes", filename: "voice.oga", content_type: "audio/ogg")

    assert_equal :failed, result.status
    assert_equal 1, http.calls.size
    assert_includes result.message, "400", "the HTTP status must reach the failure message"
    assert_includes result.message, "invalid_api_key",
                    "the 4xx response body reason must reach result.message for debuggability"
    refute_includes @logger.events.inspect, "sk-test-secret", "API key must never be logged on the 4xx path"
  end

  def test_missing_api_key_emits_distinct_signal
    # Empty env -> the key env is unset, so the transcriber emits a distinct
    # ApiKeyNotConfigured signal at call time rather than letting it look like a
    # generic upstream 401.
    @env = {}
    http = FakeHttp.new([ Response.new(status: 401, body: "unauthorized") ])

    result = transcriber(http).call("bytes", filename: "voice.oga", content_type: "audio/ogg")

    assert_equal :failed, result.status
    assert(@logger.events.any? do |event, attrs|
      event == :transcription_failed && attrs[:error_class] == "ApiKeyNotConfigured"
    end, "an unset api key env must emit a distinct ApiKeyNotConfigured signal")
  end

  def test_all_malformed_segments_falls_back_to_ok
    http = FakeHttp.new([
      Response.new(status: 200, body: JSON.generate(
        "text" => "speech",
        "language" => "english",
        "segments" => [ { "no_speech_prob" => "abc" }, { "no_speech_prob" => "xyz" } ]
      ))
    ])

    result = transcriber(http).call("bytes", filename: "voice.oga", content_type: "audio/ogg")

    assert_equal :ok, result.status,
                 "all-malformed probs leave the mean empty, which must read as speech (:ok), not no_speech"
    assert_equal "speech", result.text
  end

  def test_blank_language_with_supported_list_still_transcribes
    http = FakeHttp.new([
      Response.new(status: 200, body: JSON.generate("text" => "hello there", "language" => ""))
    ])

    result = transcriber(http).call("bytes", filename: "voice.oga", content_type: "audio/ogg")

    assert_equal :ok, result.status,
                 "a non-empty transcript with a blank/unknown language must not be dropped as unsupported"
    assert_equal "hello there", result.text
  end
end
