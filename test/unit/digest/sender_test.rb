require "test_helper"
require "stringio"
require "json"
require "logger"
require "hive/bot/logger"
require "hive/bot/telegram"
require "hive/digest/sender"
require "hive/paths"

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

  def test_send_result_guard_rejects_chat_id_on_a_dry_run
    assert_raises(ArgumentError) do
      Hive::Digest::Sender::SendResult.new(chat_id: 123, responses: [], dry_run: true, text: "x")
    end
  end

  def test_send_result_guard_rejects_a_real_send_without_a_chat_id
    error = assert_raises(ArgumentError) do
      Hive::Digest::Sender::SendResult.new(chat_id: nil, responses: [], dry_run: false, text: "x")
    end
    assert_match(/must carry a chat_id/, error.message)
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

  def test_partial_chunk_failure_records_send_failure_event_and_raises
    with_tmp_dir do |dir|
      delivered = []
      client = Object.new
      client.define_singleton_method(:message_chunks) { |_text| %w[chunk-a chunk-b] }
      client.define_singleton_method(:send_message) do |chat_id:, text:, parse_mode:|
        raise "boom on second chunk" if text == "chunk-b"

        delivered << text
        [ { "message_id" => 1 } ]
      end
      # Use the REAL bot logger (closed #event enum, no #error). A stdlib
      # Logger would have masked the production NoMethodError this guards:
      # the digest sender is wired with a Hive::Bot::Logger in production.
      logger = Hive::Bot::Logger.new(path: File.join(dir, "bot.log"))

      with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") do
        sender = Hive::Digest::Sender.new(
          cfg: { "bot" => { "digest_chat_id" => 123 } },
          telegram_factory: ->(token:, logger:) { client },
          logger: logger
        )

        assert_raises(RuntimeError) { sender.deliver("ignored", dry_run: false) }
      end
      logger.close

      assert_equal [ "chunk-a" ], delivered,
                   "the already-accepted chunk must not be resent in this attempt"
      line = File.read(File.join(dir, "bot.log")).lines.find { |l| l.include?("send_failure") }
      refute_nil line, "a :send_failure event must be recorded for the partial delivery"
      event = JSON.parse(line)
      assert_equal "digest", event["context"]
      assert_equal 1, event["accepted_chunks"]
      assert_equal 2, event["total_chunks"]
      assert_equal 2, event["failed_chunk"]
    end
  end

  def test_default_telegram_factory_builds_a_real_telegram_client
    # With no telegram_factory injected, the sender's default seam must build
    # a real Hive::Bot::Telegram (construction only — no network call here).
    sender = Hive::Digest::Sender.new(cfg: {})

    client = sender.send(:build_telegram, token: "token", logger: Object.new)

    assert_instance_of Hive::Bot::Telegram, client
  end

  def test_default_log_path_falls_back_to_state_home_when_unconfigured
    sender = Hive::Digest::Sender.new(cfg: {})

    assert_equal File.join(Hive::Paths.state_home, "logs", "bot.log"),
                 sender.send(:default_log_path),
                 "an unconfigured bot.log_file must fall back to the state-home default"
  end

  def test_default_log_path_honours_configured_bot_log_file
    sender = Hive::Digest::Sender.new(cfg: { "bot" => { "log_file" => "/var/log/hive/bot.log" } })

    assert_equal "/var/log/hive/bot.log", sender.send(:default_log_path)
  end

  def test_lazy_logger_uses_the_default_log_path_when_none_injected
    with_tmp_dir do |dir|
      sender = Hive::Digest::Sender.new(cfg: { "bot" => { "log_file" => File.join(dir, "bot.log") } })

      logger = sender.send(:logger)

      assert_instance_of Hive::Bot::Logger, logger
      logger.close if logger.respond_to?(:close)
    end
  end

  def test_send_uses_telegram_markdown_v2
    # Keep the two captured concerns distinct: factory wiring (token/logger)
    # vs. the actual send args. The previous single `sent` array conflated
    # them and relied on first/last ordering.
    sends = []
    factory_calls = []
    telegram = Struct.new(:sends) do
      def send_message(chat_id:, text:, parse_mode:)
        sends << { chat_id: chat_id, text: text, parse_mode: parse_mode }
        [ { "message_id" => 1 } ]
      end
    end
    factory = lambda { |token:, logger:|
      factory_calls << { token: token, logger: logger }
      telegram.new(sends)
    }

    with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") do
      sender = Hive::Digest::Sender.new(
        cfg: { "bot" => { "digest_chat_id" => 123 } },
        telegram_factory: factory,
        logger: Object.new
      )
      result = sender.deliver("hello", dry_run: false)

      assert_equal 123, result.chat_id
    end

    assert_equal "token", factory_calls.first.fetch(:token)
    assert_equal({ chat_id: 123, text: "hello", parse_mode: :markdown_v2 }, sends.last)
  end
end
