require "test_helper"
require "json"
require "telegram/bot"
require "hive/bot/telegram"

class HiveBotTelegramTest < Minitest::Test
  include HiveTestHelper

  FakeClient = Struct.new(:api)

  class FakeApi
    attr_reader :calls
    attr_accessor :updates, :raise_on_get_updates

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
  end

  def logger
    @logger ||= StubLogger.new
  end

  def telegram(api)
    Hive::Bot::Telegram.new(token: "token", logger: logger, client: FakeClient.new(api))
  end

  def fixture(name)
    JSON.parse(File.read(File.expand_path("../../fixtures/telegram_fixtures/#{name}", __dir__)))
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
    bot.send_message(chat_id: 12345, text: "markdown_v2", parse_mode: :markdown_v2)
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
