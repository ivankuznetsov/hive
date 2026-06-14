require "test_helper"
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
