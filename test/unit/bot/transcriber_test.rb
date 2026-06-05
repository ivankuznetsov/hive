require "test_helper"
require "hive/bot/transcriber"

class HiveBotTranscriberTest < Minitest::Test
  Response = Struct.new(:status, :body, keyword_init: true)

  class FakeRequest
    attr_reader :headers
    attr_accessor :body

    def initialize
      @headers = {}
      @options = Struct.new(:timeout).new
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
                  timeout: request.options.timeout }
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
    assert_equal :send_failure, @logger.events.first.first
    refute_includes @logger.events.inspect, "sk-test-secret"
  end

  def test_malformed_json_fails
    http = FakeHttp.new([ Response.new(status: 200, body: "{") ])

    result = transcriber(http).call("bytes", filename: "voice.oga", content_type: "audio/ogg")

    assert_equal :failed, result.status
    assert_equal "JSON::ParserError", result.error_class
    refute_includes @logger.events.inspect, "sk-test-secret", "API key must never be logged on the malformed-JSON path"
  end

  def test_non_transient_400_fails_without_retry
    http = FakeHttp.new([ Response.new(status: 400, body: "bad") ])

    result = transcriber(http).call("bytes", filename: "voice.oga", content_type: "audio/ogg")

    assert_equal :failed, result.status
    assert_equal 1, http.calls.size
    refute_includes @logger.events.inspect, "sk-test-secret", "API key must never be logged on the 4xx path"
  end
end
