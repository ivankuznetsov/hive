require "test_helper"
require "json"
require "telegram/bot"
require "hive/bot/poll_health"
require "hive/bot/telegram"

class HiveBotTelegramTest < Minitest::Test
  include HiveTestHelper

  FakeClient = Struct.new(:api)

  class FakeApi
    attr_reader :calls
    attr_accessor :updates, :raise_on_get_updates, :file

    def initialize(updates: [])
      @updates = updates
      @calls = []
    end

    def get_updates(params)
      @calls << [ :get_updates, params ]
      raise @raise_on_get_updates if @raise_on_get_updates

      @updates
    end

    def send_message(params)
      @calls << [ :send_message, params ]
      { "ok" => true, "result" => { "message_id" => 1 } }
    end

    def edit_message_reply_markup(params)
      @calls << [ :edit_message_reply_markup, params ]
      true
    end

    def answer_callback_query(params)
      @calls << [ :answer_callback_query, params ]
      true
    end

    def set_my_commands(params)
      @calls << [ :set_my_commands, params ]
      true
    end

    def get_file(params)
      @calls << [ :get_file, params ]
      file
    end
  end

  FakeHttpResponse = Struct.new(:status, :body, keyword_init: true)

  FakeHttp = Struct.new(:responses, :calls, :raise_on_get, keyword_init: true) do
    def get(url)
      calls << url
      raise raise_on_get if raise_on_get

      responses.shift
    end
  end

  def logger
    @logger ||= StubLogger.new
  end

  def telegram(api, poll_health: nil)
    kwargs = { token: "token", logger: logger, client: FakeClient.new(api) }
    kwargs[:poll_health] = poll_health if poll_health
    Hive::Bot::Telegram.new(**kwargs)
  end

  def telegram_with_http(api, http)
    Hive::Bot::Telegram.new(token: "token", logger: logger, client: FakeClient.new(api),
                            base_url: "https://telegram.test", http_client: http)
  end

  def fixture(name)
    JSON.parse(File.read(File.expand_path("../../fixtures/telegram_fixtures/#{name}", __dir__)))
  end

  def response_error
    response = Struct.new(:body, :status).new(
      JSON.generate(error_code: 429, description: "Too Many Requests"),
      429
    )
    ::Telegram::Bot::Exceptions::ResponseError.new(response: response)
  end

  def test_poll_updates_parses_message_and_callback_records
    api = FakeApi.new(updates: fixture("get_updates.json"))
    updates = telegram(api).poll_updates(timeout: 25, since_update_id: 1000)

    assert_equal [ 1001, 1002 ], updates.map(&:update_id)
    assert_equal [ 12345, 12345 ], updates.map(&:chat_id)
    assert updates.first.message?
    assert updates.first.text?
    assert_equal "/status", updates.first.text
    assert updates.last.callback_query?
    assert_equal "approve:plan:hive:slug-260514-abcd:2-brainstorm", updates.last.callback_data
    assert_equal 1000, api.calls.first.last[:offset]
    assert_equal 25, api.calls.first.last[:timeout]
  end

  def test_poll_updates_logs_transient_network_error_and_returns_empty
    api = FakeApi.new
    api.raise_on_get_updates = Faraday::ConnectionFailed.new("offline")

    updates = telegram(api).poll_updates(timeout: 25, since_update_id: nil)

    assert_equal [], updates
    assert_equal :poll_failure, logger.events.first.first
    assert_match(/ConnectionFailed/, logger.events.first.last[:error_class])
    assert_equal :debug, logger.events.first.last[:level]
    assert_equal :noise, logger.events.first.last[:category]
  end

  def test_poll_updates_logs_net_read_timeout_as_debug_noise
    api = FakeApi.new
    api.raise_on_get_updates = Net::ReadTimeout.new("slow")

    updates = telegram(api).poll_updates(timeout: 25, since_update_id: nil)

    assert_equal [], updates
    assert_equal :poll_failure, logger.events.first.first
    assert_match(/Net::ReadTimeout/, logger.events.first.last[:error_class])
    assert_equal :debug, logger.events.first.last[:level]
    assert_equal :noise, logger.events.first.last[:category]
  end

  def test_poll_updates_skips_malformed_update
    api = FakeApi.new(updates: [ { "update_id" => 12, "message" => { "text" => "bad" } } ])

    assert_equal [], telegram(api).poll_updates(timeout: 25, since_update_id: nil)
    assert_equal :poll_failure, logger.events.first.first
    assert_equal "MalformedUpdate", logger.events.first.last[:error_class]
  end

  def test_send_message_with_inline_keyboard_uses_gem_markup_shape
    api = FakeApi.new
    keyboard = [
      [ { text: "Approve", callback_data: "approve:plan:p:s:2-brainstorm" } ],
      [ { text: "Open laptop", callback_data: "open_laptop:p:s" } ]
    ]

    telegram(api).send_message(chat_id: 12345, text: "hello", reply_markup: keyboard)

    _, params = api.calls.last
    assert_equal :send_message, api.calls.last.first
    assert_equal 12345, params[:chat_id]
    refute params.key?(:parse_mode), "parse_mode should default to plain text to avoid entity-parse rejections"
    assert_instance_of Telegram::Bot::Types::InlineKeyboardMarkup, params[:reply_markup]
    hash = params[:reply_markup].to_compact_hash
    assert_equal "Approve", hash[:inline_keyboard].first.first[:text]
  end

  def test_send_message_splits_long_text
    api = FakeApi.new
    text = "x" * (Hive::Bot::Telegram::MAX_MESSAGE_CHARS + 10)

    telegram(api).send_message(chat_id: 12345, text: text)

    sends = api.calls.select { |kind, _| kind == :send_message }
    assert_equal 2, sends.size
    assert_equal Hive::Bot::Telegram::MAX_MESSAGE_CHARS, sends.first.last[:text].length
    assert_equal 10, sends.last.last[:text].length
  end

  def test_edit_message_reply_markup
    api = FakeApi.new

    telegram(api).edit_message_reply_markup(
      chat_id: 12345,
      message_id: 50,
      reply_markup: [ [ { text: "Done", callback_data: "done" } ] ]
    )

    _, params = api.calls.last
    assert_equal :edit_message_reply_markup, api.calls.last.first
    assert_equal 50, params[:message_id]
    assert_instance_of Telegram::Bot::Types::InlineKeyboardMarkup, params[:reply_markup]
  end

  def test_poll_updates_logs_generic_error_and_returns_empty
    api = FakeApi.new
    api.raise_on_get_updates = RuntimeError.new("boom")

    updates = telegram(api).poll_updates(timeout: 25, since_update_id: nil)

    assert_equal [], updates
    assert_equal :poll_failure, logger.events.first.first
    assert_equal "RuntimeError", logger.events.first.last[:error_class]
    assert_equal "boom", logger.events.first.last[:message]
    refute logger.events.first.last.key?(:level)
    refute logger.events.first.last.key?(:category)
  end

  def test_poll_updates_logs_telegram_response_error_as_warning_default
    api = FakeApi.new
    api.raise_on_get_updates = response_error

    updates = telegram(api).poll_updates(timeout: 25, since_update_id: nil)

    assert_equal [], updates
    assert_equal :poll_failure, logger.events.first.first
    assert_equal "Telegram::Bot::Exceptions::ResponseError", logger.events.first.last[:error_class]
    assert_match(/error_code/, logger.events.first.last[:message])
    refute logger.events.first.last.key?(:level), "real logger map supplies the warn level"
    refute logger.events.first.last.key?(:category)
  end

  def test_poll_updates_emits_poll_unhealthy_after_sustained_failures
    api = FakeApi.new
    api.raise_on_get_updates = Faraday::TimeoutError.new("slow")
    now = Time.utc(2026, 6, 24, 12, 0, 0)
    health = Hive::Bot::PollHealth.new(now: -> { now }, max_consecutive: 2, max_silence_sec: 60)
    bot = telegram(api, poll_health: health)

    assert_equal [], bot.poll_updates(timeout: 25, since_update_id: nil)
    assert_equal [], bot.poll_updates(timeout: 25, since_update_id: nil)
    assert_equal [], bot.poll_updates(timeout: 25, since_update_id: nil)

    unhealthy_events = logger.events.select { |name, _attrs| name == :poll_unhealthy }
    assert_equal 1, unhealthy_events.size
    attrs = unhealthy_events.first.last
    assert_equal :warn, attrs[:level]
    assert_equal 2, attrs[:consecutive_failures]
    # 0 because the injected clock is frozen across all three polls — this
    # escalation is driven by the consecutive-failure threshold, not silence,
    # so the elapsed-silence value is incidental here (the meaningful
    # seconds_since_success == 11 assertion lives in the silence test below).
    assert_equal 0, attrs[:seconds_since_success]
    assert_equal "consecutive", attrs[:reason]
  end

  def test_poll_updates_emits_poll_unhealthy_after_sustained_generic_errors
    # The generic `rescue StandardError` arm also drives escalation; a
    # copy-paste regression dropping `emit_poll_unhealthy_if_needed` from
    # only that arm would otherwise go unnoticed.
    api = FakeApi.new
    api.raise_on_get_updates = RuntimeError.new("boom")
    now = Time.utc(2026, 6, 24, 12, 0, 0)
    health = Hive::Bot::PollHealth.new(now: -> { now }, max_consecutive: 2, max_silence_sec: 60)
    bot = telegram(api, poll_health: health)

    assert_equal [], bot.poll_updates(timeout: 25, since_update_id: nil)
    assert_equal [], bot.poll_updates(timeout: 25, since_update_id: nil)
    assert_equal [], bot.poll_updates(timeout: 25, since_update_id: nil)

    unhealthy_events = logger.events.select { |name, _attrs| name == :poll_unhealthy }
    assert_equal 1, unhealthy_events.size
    attrs = unhealthy_events.first.last
    assert_equal :warn, attrs[:level]
    assert_equal 2, attrs[:consecutive_failures]
    assert_equal "consecutive", attrs[:reason]
  end

  def test_poll_updates_re_arms_escalation_after_a_successful_poll
    # Cross-layer wiring for the re-arm seam: a successful get_updates calls
    # @poll_health.record_success, which clears the unhealthy latch so a SECOND
    # sustained outage escalates again. Without record_success in poll_updates,
    # the first episode would latch poll_unhealthy off forever.
    api = FakeApi.new
    api.raise_on_get_updates = Faraday::TimeoutError.new("slow")
    now = Time.utc(2026, 6, 24, 12, 0, 0)
    health = Hive::Bot::PollHealth.new(now: -> { now }, max_consecutive: 2, max_silence_sec: 60)
    bot = telegram(api, poll_health: health)

    # First outage: second failure escalates.
    2.times { bot.poll_updates(timeout: 25, since_update_id: nil) }

    # A successful poll re-arms escalation.
    api.raise_on_get_updates = nil
    bot.poll_updates(timeout: 25, since_update_id: nil)

    # Second outage: must escalate again, not stay latched off.
    api.raise_on_get_updates = Faraday::TimeoutError.new("slow")
    2.times { bot.poll_updates(timeout: 25, since_update_id: nil) }

    unhealthy_events = logger.events.select { |name, _attrs| name == :poll_unhealthy }
    assert_equal 2, unhealthy_events.size,
                 "a successful poll must re-arm escalation so a second outage escalates again"
  end

  def test_poll_updates_emits_poll_unhealthy_with_silence_reason
    # Silence escalation (no successful poll for max_silence_sec) is the other
    # PollHealth reason; pin its Telegram-layer emission with an injected clock.
    api = FakeApi.new
    api.raise_on_get_updates = Faraday::TimeoutError.new("slow")
    now = Time.utc(2026, 6, 24, 12, 0, 0)
    health = Hive::Bot::PollHealth.new(now: -> { now }, max_consecutive: 99, max_silence_sec: 10)
    bot = telegram(api, poll_health: health)

    now += 11
    assert_equal [], bot.poll_updates(timeout: 25, since_update_id: nil)

    unhealthy_events = logger.events.select { |name, _attrs| name == :poll_unhealthy }
    assert_equal 1, unhealthy_events.size
    attrs = unhealthy_events.first.last
    assert_equal "silence", attrs[:reason]
    assert_equal 1, attrs[:consecutive_failures]
    assert_equal 11, attrs[:seconds_since_success]
  end

  def test_build_update_parse_failures_never_escalate_poll_health
    # A per-update parse failure happens AFTER a successful get_updates fetch,
    # so it must NOT count toward poll-health (see the deliberate comment in
    # Telegram#build_update's rescue). Inject a low threshold + frozen clock and
    # feed several malformed updates in ONE poll: if a refactor ever routed the
    # build_update rescue through emit_poll_unhealthy_if_needed, the 2nd failure
    # would trip max_consecutive and page. Pin that it never does while
    # poll_failure is still logged per malformed update.
    exploding = Class.new do
      def update_id
        raise RuntimeError, "cannot decode"
      end
    end
    api = FakeApi.new(updates: [ exploding.new, exploding.new, exploding.new ])
    now = Time.utc(2026, 6, 24, 12, 0, 0)
    health = Hive::Bot::PollHealth.new(now: -> { now }, max_consecutive: 2, max_silence_sec: 60)

    assert_equal [], telegram(api, poll_health: health).poll_updates(timeout: 25, since_update_id: nil)

    assert_equal %i[poll_failure poll_failure poll_failure], logger.events.map(&:first),
                 "each malformed update must log poll_failure"
    assert_empty logger.events.select { |name, _attrs| name == :poll_unhealthy },
                 "build_update parse failures must never escalate poll-health, even past max_consecutive"
  end

  def test_poll_updates_accepts_object_shaped_updates
    chat = Struct.new(:id).new(12345)
    from = Struct.new(:id).new(54321)
    message = Struct.new(:chat, :from, :message_id, :text).new(chat, from, 88, "hello")
    raw = Struct.new(:update_id, :message).new(2001, message)
    api = FakeApi.new(updates: [ raw ])

    update = telegram(api).poll_updates(timeout: 25, since_update_id: nil).first

    assert_equal 2001, update.update_id
    assert_equal 12345, update.chat_id
    assert_equal 54321, update.from_id
    assert_equal 88, update.message_id
    assert_equal "hello", update.text
    assert_equal [], update.entities
  end

  def test_poll_updates_parses_largest_photo_caption_and_album_id
    api = FakeApi.new(updates: [
      {
        "update_id" => 3001,
        "message" => {
          "message_id" => 42,
          "chat" => { "id" => 12345 },
          "from" => { "id" => 54321 },
          "caption" => "/idea fix login",
          "media_group_id" => "album-1",
          "photo" => [
            { "file_id" => "small", "file_unique_id" => "us", "file_size" => 100, "width" => 90, "height" => 90 },
            { "file_id" => "large", "file_unique_id" => "ul", "file_size" => 900, "width" => 900, "height" => 900 }
          ]
        }
      }
    ])

    update = telegram(api).poll_updates(timeout: 25, since_update_id: nil).first

    assert update.media?
    refute update.text?
    assert_equal "large", update.photo.fetch(:file_id)
    assert_nil update.document
    assert_equal "/idea fix login", update.caption
    assert_equal "/idea fix login", update.effective_text
    assert_equal "album-1", update.media_group_id
  end

  def test_poll_updates_parses_document_metadata
    api = FakeApi.new(updates: [
      {
        "update_id" => 3002,
        "message" => {
          "message_id" => 43,
          "chat" => { "id" => 12345 },
          "document" => {
            "file_id" => "doc-file",
            "file_unique_id" => "doc-unique",
            "file_name" => "notes.pdf",
            "mime_type" => "application/pdf",
            "file_size" => 1234
          }
        }
      }
    ])

    update = telegram(api).poll_updates(timeout: 25, since_update_id: nil).first

    assert update.media?
    assert_equal "notes.pdf", update.document.fetch(:file_name)
    assert_equal "application/pdf", update.document.fetch(:mime_type)
    assert_equal 1234, update.document.fetch(:file_size)
    assert_nil update.caption
  end

  def test_poll_updates_parses_voice_note_metadata
    api = FakeApi.new(updates: [
      {
        "update_id" => 3004,
        "message" => {
          "message_id" => 45,
          "chat" => { "id" => 12345 },
          "voice" => {
            "file_id" => "voice-file",
            "file_unique_id" => "voice-unique",
            "duration" => 7,
            "mime_type" => "audio/ogg",
            "file_size" => 4321
          }
        }
      }
    ])

    update = telegram(api).poll_updates(timeout: 25, since_update_id: nil).first

    assert update.voice?
    refute update.media?
    assert_equal "voice-file", update.voice.fetch(:file_id)
    assert_equal "voice-unique", update.voice.fetch(:file_unique_id)
    assert_equal 7, update.voice.fetch(:duration)
    assert_equal "audio/ogg", update.voice.fetch(:mime_type)
    assert_equal 4321, update.voice.fetch(:file_size)
  end

  def test_poll_updates_ignores_audio_messages
    api = FakeApi.new(updates: [
      {
        "update_id" => 3005,
        "message" => {
          "message_id" => 46,
          "chat" => { "id" => 12345 },
          "audio" => {
            "file_id" => "song-file",
            "mime_type" => "audio/mpeg",
            "file_size" => 123_456
          }
        }
      }
    ])

    update = telegram(api).poll_updates(timeout: 25, since_update_id: nil).first

    refute update.voice?
    refute update.media?
    assert_nil update.voice
  end

  def test_callback_updates_do_not_inherit_media_from_source_message
    api = FakeApi.new(updates: [
      {
        "update_id" => 3003,
        "callback_query" => {
          "id" => "cbq-1",
          "data" => "reject:anything",
          "from" => { "id" => 54321 },
          "message" => {
            "message_id" => 44,
            "chat" => { "id" => 12345 },
            "caption" => "caption",
            "photo" => [ { "file_id" => "photo" } ]
          }
        }
      }
    ])

    update = telegram(api).poll_updates(timeout: 25, since_update_id: nil).first

    refute update.media?
    assert_nil update.caption
    assert_nil update.effective_text
    assert_nil update.voice
  end

  def test_get_file_returns_path_and_size
    api = FakeApi.new
    api.file = Struct.new(:file_path, :file_size).new("photos/file.jpg", 123)

    result = telegram(api).get_file(file_id: "abc")

    assert_equal({ file_path: "photos/file.jpg", file_size: 123 }, result)
    assert_equal [ :get_file, { file_id: "abc" } ], api.calls.last
  end

  def test_get_file_wraps_faraday_errors
    api = FakeApi.new
    api.define_singleton_method(:get_file) do |params|
      calls << [ :get_file, params ]
      raise Faraday::TimeoutError, "slow"
    end

    assert_raises(Hive::Bot::Telegram::DownloadError) do
      telegram(api).get_file(file_id: "abc")
    end
  end

  def test_download_file_returns_raw_bytes
    api = FakeApi.new
    http = FakeHttp.new(responses: [ FakeHttpResponse.new(status: 200, body: "bytes") ], calls: [])

    bytes = telegram_with_http(api, http).download_file(file_path: "photos/file one.jpg")

    assert_equal "bytes", bytes
    assert_equal [ "https://telegram.test/file/bottoken/photos/file+one.jpg" ], http.calls
  end

  def test_download_file_raises_download_error_on_non_200
    api = FakeApi.new
    http = FakeHttp.new(responses: [ FakeHttpResponse.new(status: 500, body: "no") ], calls: [])

    assert_raises(Hive::Bot::Telegram::DownloadError) do
      telegram_with_http(api, http).download_file(file_path: "docs/file.pdf")
    end
  end

  def test_download_file_wraps_timeout
    api = FakeApi.new
    http = FakeHttp.new(responses: [], calls: [], raise_on_get: Faraday::TimeoutError.new("slow"))

    assert_raises(Hive::Bot::Telegram::DownloadError) do
      telegram_with_http(api, http).download_file(file_path: "docs/file.pdf")
    end
  end

  def test_poll_updates_logs_build_update_backtrace_once_per_error_class
    exploding = Class.new do
      def update_id
        raise RuntimeError, "cannot decode"
      end
    end
    api = FakeApi.new(updates: [ exploding.new, exploding.new ])

    updates = telegram(api).poll_updates(timeout: 25, since_update_id: nil)

    assert_equal [], updates
    assert_equal [ :poll_failure, :poll_failure ], logger.events.map(&:first)
    first_attrs = logger.events.first.last
    second_attrs = logger.events.last.last
    assert_equal "RuntimeError", first_attrs[:error_class]
    assert_match(/cannot decode/, first_attrs[:message])
    assert first_attrs[:backtrace].to_s.include?("update_id")
    refute second_attrs.key?(:backtrace)
  end

  def test_send_message_accepts_parse_mode_variants
    api = FakeApi.new
    bot = telegram(api)

    bot.send_message(chat_id: 12345, text: "markdown", parse_mode: :markdown)
    bot.send_message(chat_id: 12345, text: "markdown v2", parse_mode: :markdown_v2)
    bot.send_message(chat_id: 12345, text: "html", parse_mode: :html)
    bot.send_message(chat_id: 12345, text: "custom", parse_mode: "Custom")

    parse_modes = api.calls.filter_map do |kind, params|
      params[:parse_mode] if kind == :send_message
    end
    assert_equal %w[Markdown MarkdownV2 HTML Custom], parse_modes
  end

  def test_send_message_handles_empty_text_and_newline_splitting
    api = FakeApi.new
    bot = telegram(api)

    bot.send_message(chat_id: 12345, text: "")
    newline_text = "a" * 10 + "\n" + "b" * Hive::Bot::Telegram::MAX_MESSAGE_CHARS
    bot.send_message(chat_id: 12345, text: newline_text)

    sends = api.calls.select { |kind, _| kind == :send_message }
    assert_equal "", sends.first.last[:text]
    assert_equal "a" * 10, sends[1].last[:text]
    assert_equal "b" * Hive::Bot::Telegram::MAX_MESSAGE_CHARS, sends[2].last[:text]
  end

  def test_edit_message_reply_markup_can_remove_markup
    api = FakeApi.new

    telegram(api).edit_message_reply_markup(chat_id: 12345, message_id: 50)

    _, params = api.calls.last
    assert_equal :edit_message_reply_markup, api.calls.last.first
    assert_equal({ chat_id: 12345, message_id: 50 }, params)
  end

  def test_set_my_commands_forwards_commands_list_to_api
    api = FakeApi.new
    commands = [
      { command: "idea", description: "Capture a new idea" },
      { command: "status", description: "Show active tasks" }
    ]

    telegram(api).set_my_commands(commands: commands)

    assert_equal :set_my_commands, api.calls.last.first
    assert_equal commands, api.calls.last.last[:commands]
  end

  def test_answer_callback_query_silent_ack
    api = FakeApi.new

    telegram(api).answer_callback_query(callback_query_id: "cbq-1")

    assert_equal :answer_callback_query, api.calls.last.first
    params = api.calls.last.last
    assert_equal "cbq-1", params[:callback_query_id]
    refute params.key?(:text),
           "silent ack must omit :text so Telegram clears the spinner with no toast"
    refute params.key?(:show_alert)
  end

  def test_answer_callback_query_with_toast_truncates_to_200_chars_and_marks_show_alert
    api = FakeApi.new
    long_text = "x" * 250

    telegram(api).answer_callback_query(callback_query_id: "cbq-2",
                                        text: long_text, show_alert: true)

    params = api.calls.last.last
    assert_equal 200, params[:text].length,
                 "toast text must be truncated to Telegram's 200-char limit"
    assert_equal true, params[:show_alert]
  end

  def test_value_returns_nil_for_unsupported_objects
    object = Object.new

    assert_nil telegram(FakeApi.new).send(:value, object, :missing)
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
end
