require "test_helper"
require "stringio"
require "logger"
require "hive/digest/sender"

class HiveDigestSenderTest < Minitest::Test
  include HiveTestHelper

  def test_resolve_chat_id_prefers_digest_chat_id
    cfg = { "bot" => { "digest_chat_id" => 123, "chat_id_allowlist" => [ 456 ] } }

    assert_equal 123, Hive::Digest::Sender.resolve_chat_id(cfg)
  end

  def test_resolve_chat_id_falls_back_to_first_allowlist_entry
    cfg = { "bot" => { "chat_id_allowlist" => [ 456, 789 ] } }

    assert_equal 456, Hive::Digest::Sender.resolve_chat_id(cfg)
  end

  def test_resolve_chat_id_raises_clear_config_error_when_missing
    error = assert_raises(Hive::ConfigError) do
      Hive::Digest::Sender.resolve_chat_id({ "bot" => { "chat_id_allowlist" => [] } })
    end

    assert_match(/digest_chat_id/, error.message)
  end

  def test_dry_run_returns_text_without_token_or_chat
    sender = Hive::Digest::Sender.new(cfg: {})

    result = sender.deliver("hello", dry_run: true)

    assert result.dry_run
    assert_equal "hello", result.text
  end

  def test_preflight_raises_before_any_send_when_recipient_missing
    sender = Hive::Digest::Sender.new(cfg: { "bot" => { "chat_id_allowlist" => [] } })

    assert_raises(Hive::ConfigError) { sender.preflight! }
  end

  def test_preflight_raises_when_token_missing
    sender = Hive::Digest::Sender.new(cfg: { "bot" => { "digest_chat_id" => 123 } })

    with_env("HIVE_TELEGRAM_BOT_TOKEN" => nil) do
      assert_raises(Hive::ConfigError) { sender.preflight! }
    end
  end

  def test_preflight_passes_when_recipient_and_token_present
    with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") do
      sender = Hive::Digest::Sender.new(cfg: { "bot" => { "digest_chat_id" => 123 } })

      assert_nil sender.preflight!
    end
  end

  def test_partial_chunk_failure_logs_delivered_count_and_raises
    delivered = []
    client = Object.new
    client.define_singleton_method(:message_chunks) { |_text| %w[chunk-a chunk-b] }
    client.define_singleton_method(:send_message) do |chat_id:, text:, parse_mode:|
      raise "boom on second chunk" if text == "chunk-b"

      delivered << text
      [ { "message_id" => 1 } ]
    end
    buf = StringIO.new

    with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") do
      sender = Hive::Digest::Sender.new(
        cfg: { "bot" => { "digest_chat_id" => 123 } },
        telegram_factory: ->(token:, logger:) { client },
        logger: Logger.new(buf)
      )

      assert_raises(RuntimeError) { sender.deliver("ignored", dry_run: false) }
    end

    assert_equal [ "chunk-a" ], delivered, "the already-accepted chunk must not be resent in this attempt"
    assert_includes buf.string, "partial delivery"
  end

  def test_send_uses_telegram_markdown_v2
    sent = []
    telegram = Struct.new(:sent) do
      def send_message(chat_id:, text:, parse_mode:)
        sent << { chat_id: chat_id, text: text, parse_mode: parse_mode }
        [ { "message_id" => 1 } ]
      end
    end
    factory = lambda { |token:, logger:|
      sent << { token: token, logger: logger }
      telegram.new(sent)
    }

    with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") do
      sender = Hive::Digest::Sender.new(
        cfg: { "bot" => { "digest_chat_id" => 123 } },
        telegram_factory: factory,
        logger: Object.new
      )
      result = sender.deliver("hello", dry_run: false)

      assert_equal 123, result.chat_id
      assert_equal({ chat_id: 123, text: "hello", parse_mode: :markdown_v2 }, sent.last)
      assert_equal "token", sent.first.fetch(:token)
    end
  end
end
