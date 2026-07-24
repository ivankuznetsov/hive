require "test_helper"
require "delegate"
require "stringio"
require "json"
require "logger"
require "hive/bot/logger"
require "hive/bot/telegram"
require "hive/digest/sender"
require "hive/paths"

class HiveDigestSenderTest < Minitest::Test
  include HiveTestHelper

  def test_resolve_chat_id_uses_first_allowlist_entry
    cfg = { "bot" => { "chat_id_allowlist" => [ 456, 789 ] } }

    assert_equal 456, Hive::Digest::Sender.resolve_chat_id(cfg)
  end

  def test_resolve_chat_id_raises_clear_config_error_when_missing
    error = assert_raises(Hive::ConfigError) do
      Hive::Digest::Sender.resolve_chat_id({ "bot" => { "chat_id_allowlist" => [] } })
    end

    assert_match(/chat_id_allowlist/, error.message)
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
    sender = Hive::Digest::Sender.new(cfg: { "bot" => { "chat_id_allowlist" => [ 123 ] } })

    with_env("HIVE_TELEGRAM_BOT_TOKEN" => nil) do
      assert_raises(Hive::ConfigError) { sender.preflight! }
    end
  end

  def test_preflight_passes_when_recipient_and_token_present
    with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") do
      sender = Hive::Digest::Sender.new(cfg: { "bot" => { "chat_id_allowlist" => [ 123 ] } })

      assert_nil sender.preflight!
    end
  end

  def test_partial_chunk_failure_records_send_failure_event_and_raises
    with_tmp_dir do |dir|
      delivered = []
      client = Object.new
      client.define_singleton_method(:message_chunks) do |_text, parse_mode:|
        raise "wrong parse mode" unless parse_mode == :markdown_v2

        %w[chunk-a chunk-b]
      end
      server_error = telegram_response_error(500, "Internal Server Error")
      client.define_singleton_method(:send_message) do |chat_id:, text:, parse_mode:|
        raise server_error if text == "chunk-b"

        delivered << text
        [ { "message_id" => 1 } ]
      end
      # Use the REAL bot logger (closed #event enum, no #error). A stdlib
      # Logger would have masked the production NoMethodError this guards:
      # the digest sender is wired with a Hive::Bot::Logger in production.
      logger = Hive::Bot::Logger.new(path: File.join(dir, "bot.log"))

      with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") do
        sender = Hive::Digest::Sender.new(
          cfg: { "bot" => { "chat_id_allowlist" => [ 123 ] } },
          telegram_factory: ->(token:, logger:) { client },
          logger: logger,
          checkpoint_root: File.join(dir, "deliveries")
        )

        assert_raises(::Telegram::Bot::Exceptions::ResponseError) do
          sender.deliver("ignored", dry_run: false, digest_date: Date.new(2026, 7, 23))
        end
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

    with_tmp_dir do |dir|
      with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") do
        sender = Hive::Digest::Sender.new(
          cfg: { "bot" => { "chat_id_allowlist" => [ 123 ] } },
          telegram_factory: factory,
          logger: Object.new,
          checkpoint_root: File.join(dir, "deliveries")
        )
        result = sender.deliver(
          "hello", dry_run: false, digest_date: Date.new(2026, 7, 23)
        )

        assert_equal 123, result.chat_id
      end
    end

    assert_equal "token", factory_calls.first.fetch(:token)
    assert_equal({ chat_id: 123, text: "hello", parse_mode: :markdown_v2 }, sends.last)
  end

  def test_real_send_redacts_again_at_the_telegram_boundary
    sends = []
    client = Object.new
    client.define_singleton_method(:send_message) do |chat_id:, text:, parse_mode:|
      sends << { chat_id: chat_id, text: text, parse_mode: parse_mode }
      [ { "message_id" => 1 } ]
    end
    token = "ghp_#{'t' * 36}"
    with_tmp_dir do |dir|
      with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") do
        sender = Hive::Digest::Sender.new(
          cfg: { "bot" => { "chat_id_allowlist" => [ 123 ] } },
          telegram_factory: ->(**) { client }, logger: Object.new,
          checkpoint_root: File.join(dir, "deliveries")
        )
        result = sender.deliver(
          "Rendered #{token}", dry_run: false, digest_date: Date.new(2026, 7, 23)
        )

        refute_includes result.text, token
        assert_includes result.text, "\\[REDACTED:github_token\\]"
        assert_equal result.text, sends.first.fetch(:text)
      end
    end
  end

  def test_unverifiable_delivery_redaction_fails_before_telegram_send
    redactor = Object.new
    redactor.define_singleton_method(:redact) { |text| text }
    redactor.define_singleton_method(:scan) { |_text| [ { name: :github_token } ] }
    calls = []
    sender = Hive::Digest::Sender.new(
      cfg: { "bot" => { "chat_id_allowlist" => [ 123 ] } },
      telegram_factory: ->(**) { calls << :client; Object.new },
      logger: Object.new,
      redactor: redactor
    )

    assert_raises(Hive::ConfigError) do
      sender.deliver("unsafe", dry_run: false, digest_date: Date.new(2026, 7, 23))
    end
    assert_empty calls
  end

  def test_delivery_redaction_runtime_errors_fail_before_telegram_send
    broken = Object.new
    broken.define_singleton_method(:redact) { |_text| raise EncodingError, "invalid" }
    broken.define_singleton_method(:scan) { |_text| [] }
    calls = []
    sender = Hive::Digest::Sender.new(
      cfg: { "bot" => { "chat_id_allowlist" => [ 123 ] } },
      telegram_factory: ->(**) { calls << :client; Object.new },
      logger: Object.new,
      redactor: broken
    )

    error = assert_raises(Hive::ConfigError) do
      sender.deliver("unsafe", dry_run: false, digest_date: Date.new(2026, 7, 23))
    end
    assert_match(/delivery redaction failed/, error.message)
    assert_empty calls
  end

  def test_retry_uses_stable_payload_and_resumes_at_next_unsent_chunk
    with_tmp_dir do |dir|
      checkpoint_root = File.join(dir, "deliveries")
      first_sends = []
      first_client = chunk_client(
        chunks: %w[chunk-a chunk-b chunk-c],
        sends: first_sends,
        failure: lambda { |text|
          raise telegram_response_error(500, "Internal Server Error") if text == "chunk-b"
        }
      )

      with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") do
        first_sender = sender_for(
          first_client, checkpoint_root: checkpoint_root,
          logger: Hive::Bot::Logger.new(path: File.join(dir, "first.log"))
        )
        assert_raises(::Telegram::Bot::Exceptions::ResponseError) do
          first_sender.deliver(
            "first rendered payload", dry_run: false,
            digest_date: Date.new(2026, 7, 23)
          )
        end

        resumed_sends = []
        resumed_client = chunk_client(
          chunks: %w[regenerated-a regenerated-b],
          sends: resumed_sends
        )
        resumed_sender = sender_for(
          resumed_client, checkpoint_root: checkpoint_root, logger: Object.new
        )
        result = resumed_sender.deliver(
          "different regenerated payload", dry_run: false,
          digest_date: Date.new(2026, 7, 23)
        )

        assert_equal %w[chunk-a chunk-b], first_sends
        assert_equal %w[chunk-b chunk-c], resumed_sends
        assert_equal "first rendered payload", result.text,
                     "the retry must use the payload persisted by the first attempt"

        final_sends = []
        final_sender = sender_for(
          chunk_client(chunks: [ "new-again" ], sends: final_sends),
          checkpoint_root: checkpoint_root,
          logger: Object.new
        )
        final_result = final_sender.deliver(
          "third generated payload", dry_run: false,
          digest_date: Date.new(2026, 7, 23)
        )

        assert_empty final_sends,
                     "a fully accepted checkpoint must return success without resending"
        assert_equal "first rendered payload", final_result.text
      end

      checkpoint = JSON.parse(
        File.read(File.join(checkpoint_root, "2026-07-23.json"))
      )
      assert_equal 3, checkpoint.fetch("next_chunk")
      assert_equal 3, checkpoint.fetch("total_chunks")
      assert checkpoint.key?("completed_at")
      assert_equal 0o600, File.stat(File.join(checkpoint_root, "2026-07-23.json")).mode & 0o777
    end
  end

  def test_telegram_markdown_parse_error_is_permanent_and_keeps_partial_context
    with_tmp_dir do |dir|
      sends = []
      response = Struct.new(:body, :status).new(
        JSON.generate(
          error_code: 400,
          description: "Bad Request: can't parse entities: Can't find end of Italic entity"
        ),
        400
      )
      parse_error = ::Telegram::Bot::Exceptions::ResponseError.new(response: response)
      client = chunk_client(
        chunks: %w[chunk-a chunk-b], sends: sends,
        failure: ->(text) { raise parse_error if text == "chunk-b" }
      )
      logger = Hive::Bot::Logger.new(path: File.join(dir, "bot.log"))

      with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") do
        sender = sender_for(
          client, checkpoint_root: File.join(dir, "deliveries"), logger: logger
        )
        error = assert_raises(Hive::Digest::PermanentDeliveryError) do
          sender.deliver(
            "rendered", dry_run: false, digest_date: Date.new(2026, 7, 23)
          )
        end

        assert_equal Hive::ExitCodes::SOFTWARE, error.exit_code
      end
      logger.close

      assert_equal %w[chunk-a chunk-b], sends
      event = JSON.parse(
        File.readlines(File.join(dir, "bot.log")).find { |line| line.include?("send_failure") }
      )
      assert_equal 1, event.fetch("accepted_chunks")
      assert_equal 2, event.fetch("total_chunks")
      assert_equal 2, event.fetch("failed_chunk")
      checkpoint = JSON.parse(
        File.read(File.join(dir, "deliveries", "2026-07-23.json"))
      )
      assert_equal 1, checkpoint.fetch("next_chunk")
      assert_equal "Telegram::Bot::Exceptions::ResponseError",
                   checkpoint.dig("permanent_failure", "error_class")

      retry_sends = []
      with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") do
        parked_sender = sender_for(
          chunk_client(chunks: [ "replacement" ], sends: retry_sends),
          checkpoint_root: File.join(dir, "deliveries"),
          logger: Object.new
        )
        assert_raises(Hive::Digest::PermanentDeliveryError) do
          parked_sender.deliver(
            "new payload", dry_run: false, digest_date: Date.new(2026, 7, 23)
          )
        end
      end
      assert_empty retry_sends, "a parked checkpoint must never attempt Telegram again"
    end
  end

  def test_markdown_parse_error_retries_failed_chunk_once_as_html
    with_tmp_dir do |dir|
      calls = []
      response = Struct.new(:body, :status).new(
        JSON.generate(
          error_code: 400,
          description: "Bad Request: can't parse entities: Can't find end of Italic entity"
        ),
        400
      )
      parse_error = ::Telegram::Bot::Exceptions::ResponseError.new(response: response)
      client = Object.new
      client.define_singleton_method(:message_chunks) do |text, parse_mode:|
        raise "wrong parse mode" unless parse_mode == :markdown_v2

        [ text ]
      end
      client.define_singleton_method(:markdown_v2_to_html) do |_text|
        "<b>formatted</b> <a href=\"https://example.com\">link</a>"
      end
      client.define_singleton_method(:send_message) do |chat_id:, text:, parse_mode:|
        calls << { chat_id: chat_id, text: text, parse_mode: parse_mode }
        raise parse_error if parse_mode == :markdown_v2

        [ { "message_id" => 9 } ]
      end
      logger = Hive::Bot::Logger.new(path: File.join(dir, "bot.log"))

      with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") do
        result = sender_for(
          client, checkpoint_root: File.join(dir, "deliveries"), logger: logger
        ).deliver(
          "*formatted* [link](https://example.com)",
          dry_run: false,
          digest_date: Date.new(2026, 7, 23)
        )

        assert_equal 1, result.responses.size
      end
      logger.close

      assert_equal [ :markdown_v2, :html ], calls.map { |call| call.fetch(:parse_mode) }
      assert_equal "<b>formatted</b> <a href=\"https://example.com\">link</a>",
                   calls.last.fetch(:text)
      event = JSON.parse(
        File.readlines(File.join(dir, "bot.log")).find { |line| line.include?("send_failure") }
      )
      assert_equal 0, event.fetch("accepted_chunks")
      assert_equal 1, event.fetch("total_chunks")
      assert_equal 1, event.fetch("failed_chunk")
      assert_equal "html", event.fetch("fallback_parse_mode")
      assert_equal true, event.fetch("recovered")
      checkpoint = JSON.parse(
        File.read(File.join(dir, "deliveries", "2026-07-23.json"))
      )
      assert_equal 1, checkpoint.fetch("next_chunk")
      assert checkpoint.key?("completed_at")
      refute checkpoint.key?("permanent_failure")
    end
  end

  def test_html_fallback_parse_error_is_permanent
    with_tmp_dir do |dir|
      parse_error = telegram_parse_error
      calls = []
      client = fallback_client(calls: calls, markdown_error: parse_error, html_error: parse_error)

      with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") do
        error = assert_raises(Hive::Digest::PermanentDeliveryError) do
          sender_for(
            client,
            checkpoint_root: File.join(dir, "deliveries"),
            logger: Hive::Bot::Logger.new(path: File.join(dir, "bot.log"))
          ).deliver(
            "*formatted*", dry_run: false, digest_date: Date.new(2026, 7, 23)
          )
        end
        assert_match(/permanently rejected/, error.message)
      end

      assert_equal [ :markdown_v2, :html ], calls
      checkpoint = JSON.parse(
        File.read(File.join(dir, "deliveries", "2026-07-23.json"))
      )
      assert checkpoint.key?("permanent_failure")
    end
  end

  def test_transient_html_fallback_failure_remains_retryable
    with_tmp_dir do |dir|
      calls = []
      client = fallback_client(
        calls: calls,
        markdown_error: telegram_parse_error,
        html_error: telegram_response_error(500, "Internal Server Error")
      )
      checkpoint_root = File.join(dir, "deliveries")

      with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") do
        error = assert_raises(::Telegram::Bot::Exceptions::ResponseError) do
          sender_for(
            client,
            checkpoint_root: checkpoint_root,
            logger: Hive::Bot::Logger.new(path: File.join(dir, "bot.log"))
          ).deliver(
            "*formatted*", dry_run: false, digest_date: Date.new(2026, 7, 23)
          )
        end
        assert_equal 500, error.error_code
      end

      assert_equal [ :markdown_v2, :html ], calls
      checkpoint = JSON.parse(
        File.read(File.join(checkpoint_root, "2026-07-23.json"))
      )
      refute checkpoint.key?("permanent_failure")
      assert_equal 0, checkpoint.fetch("next_chunk")
      assert_equal "html", checkpoint.dig("pending_variant", "parse_mode")
      refute checkpoint.key?("in_flight")

      retry_calls = []
      retry_client = fallback_client(
        calls: retry_calls,
        markdown_error: RuntimeError.new("MarkdownV2 must not be retried"),
        html_error: nil
      )
      with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") do
        sender_for(
          retry_client, checkpoint_root: checkpoint_root, logger: Object.new
        ).deliver(
          "*different regenerated text*",
          dry_run: false,
          digest_date: Date.new(2026, 7, 23)
        )
      end
      assert_equal [ :html ], retry_calls
    end
  end

  def test_unknown_transport_outcome_is_parked_and_never_replayed
    with_tmp_dir do |dir|
      checkpoint_root = File.join(dir, "deliveries")
      sends = []
      client = chunk_client(
        chunks: [ "chunk-a" ],
        sends: sends,
        failure: ->(_text) { raise Net::ReadTimeout, "response lost" }
      )

      with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") do
        error = assert_raises(Hive::Digest::AmbiguousDeliveryError) do
          sender_for(
            client,
            checkpoint_root: checkpoint_root,
            logger: Hive::Bot::Logger.new(path: File.join(dir, "bot.log"))
          ).deliver(
            "payload", dry_run: false, digest_date: Date.new(2026, 7, 23)
          )
        end
        assert_match(/outcome.*unknown/, error.message)
      end

      assert_equal [ "chunk-a" ], sends
      checkpoint = JSON.parse(
        File.read(File.join(checkpoint_root, "2026-07-23.json"))
      )
      assert_equal 0, checkpoint.fetch("next_chunk")
      assert_equal 0, checkpoint.dig("in_flight", "chunk_index")
      assert_equal "Hive::Digest::AmbiguousDeliveryError",
                   checkpoint.dig("permanent_failure", "error_class")

      retry_sends = []
      with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") do
        assert_raises(Hive::Digest::PermanentDeliveryError) do
          sender_for(
            chunk_client(chunks: [ "replacement" ], sends: retry_sends),
            checkpoint_root: checkpoint_root,
            logger: Object.new
          ).deliver(
            "replacement", dry_run: false, digest_date: Date.new(2026, 7, 23)
          )
        end
      end
      assert_empty retry_sends
    end
  end

  def test_restart_with_an_in_flight_checkpoint_parks_without_sending
    with_tmp_dir do |dir|
      checkpoint_root = File.join(dir, "deliveries")
      store = Hive::Digest::DeliveryCheckpointStore.new(root: checkpoint_root)
      store.synchronize("2026-07-23") do |key|
        checkpoint = store.create(
          key: key, chat_id: 123, payload: "body", chunks: [ "body" ]
        )
        store.begin_attempt(
          checkpoint,
          chunk_index: 0,
          payload: "body",
          parse_mode: :markdown_v2
        )
      end
      sends = []

      with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") do
        assert_raises(Hive::Digest::AmbiguousDeliveryError) do
          sender_for(
            chunk_client(chunks: [ "body" ], sends: sends),
            checkpoint_root: checkpoint_root,
            logger: Object.new
          ).deliver(
            "body", dry_run: false, digest_date: Date.new(2026, 7, 23)
          )
        end
      end
      assert_empty sends
    end
  end

  def test_checkpoint_accept_failure_after_send_is_ambiguous
    with_tmp_dir do |dir|
      checkpoint_root = File.join(dir, "deliveries")
      real_store = Hive::Digest::DeliveryCheckpointStore.new(root: checkpoint_root)
      failing_store = Class.new(SimpleDelegator) do
        def accept(_checkpoint, next_chunk:)
          raise Hive::Digest::DeliveryCheckpointError,
                "simulated failure after accepting chunk #{next_chunk}"
        end
      end.new(real_store)
      sends = []

      with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") do
        sender = Hive::Digest::Sender.new(
          cfg: { "bot" => { "chat_id_allowlist" => [ 123 ] } },
          telegram_factory: ->(**) { chunk_client(chunks: [ "body" ], sends: sends) },
          logger: Object.new,
          checkpoint_store: failing_store
        )
        assert_raises(Hive::Digest::AmbiguousDeliveryError) do
          sender.deliver(
            "body", dry_run: false, digest_date: Date.new(2026, 7, 23)
          )
        end
      end

      assert_equal [ "body" ], sends
      checkpoint = real_store.load("2026-07-23")
      assert_equal 0, checkpoint.fetch("next_chunk")
      assert checkpoint.key?("in_flight")
      assert checkpoint.key?("permanent_failure")
    end
  end

  def test_non_parse_telegram_400_is_permanent
    with_tmp_dir do |dir|
      calls = []
      error_400 = telegram_response_error(400, "Bad Request: chat not found")
      client = chunk_client(
        chunks: [ "body" ],
        sends: calls,
        failure: ->(_text) { raise error_400 }
      )

      with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") do
        assert_raises(Hive::Digest::PermanentDeliveryError) do
          sender_for(
            client,
            checkpoint_root: File.join(dir, "deliveries"),
            logger: Hive::Bot::Logger.new(path: File.join(dir, "bot.log"))
          ).deliver(
            "body", dry_run: false, digest_date: Date.new(2026, 7, 23)
          )
        end
      end
      assert_equal [ "body" ], calls
      checkpoint = JSON.parse(
        File.read(File.join(dir, "deliveries", "2026-07-23.json"))
      )
      assert checkpoint.key?("permanent_failure")
      refute checkpoint.key?("in_flight")
    end
  end

  def test_large_html_fallback_is_one_exact_telegram_request
    with_tmp_dir do |dir|
      calls = []
      parse_error = telegram_parse_error
      api = Object.new
      api.define_singleton_method(:send_message) do |params|
        calls << params
        raise parse_error if params[:parse_mode] == "MarkdownV2"

        { "message_id" => 42 }
      end
      raw_client = Struct.new(:api).new(api)
      telegram = Hive::Bot::Telegram.new(
        token: "token", logger: Object.new, client: raw_client
      )
      markdown = "*#{'&' * 4_094}*"

      with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") do
        result = sender_for(
          telegram,
          checkpoint_root: File.join(dir, "deliveries"),
          logger: Hive::Bot::Logger.new(path: File.join(dir, "bot.log"))
        ).deliver(
          markdown, dry_run: false, digest_date: Date.new(2026, 7, 23)
        )
        assert_equal [ { "message_id" => 42 } ], result.responses
      end

      assert_equal 2, calls.size
      html_call = calls.last
      assert_equal "HTML", html_call.fetch(:parse_mode)
      assert_operator html_call.fetch(:text).length, :>, Hive::Bot::Telegram::MAX_MESSAGE_CHARS
      assert_equal "<b>", html_call.fetch(:text)[0, 3]
      assert_equal "</b>", html_call.fetch(:text)[-4, 4]
    end
  end

  def test_pre_send_checkpoint_failure_remains_retryable
    with_tmp_dir do |dir|
      real_store = Hive::Digest::DeliveryCheckpointStore.new(
        root: File.join(dir, "deliveries")
      )
      failing_store = Class.new(SimpleDelegator) do
        def begin_attempt(_checkpoint, **)
          raise Hive::Digest::DeliveryCheckpointError, "temporary disk outage"
        end
      end.new(real_store)
      sends = []

      with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") do
        sender = Hive::Digest::Sender.new(
          cfg: { "bot" => { "chat_id_allowlist" => [ 123 ] } },
          telegram_factory: ->(**) { chunk_client(chunks: [ "body" ], sends: sends) },
          logger: Object.new,
          checkpoint_store: failing_store
        )
        assert_raises(Hive::Digest::DeliveryCheckpointError) do
          sender.deliver(
            "body", dry_run: false, digest_date: Date.new(2026, 7, 23)
          )
        end
      end
      assert_empty sends
    end
  end

  def test_html_fallback_pre_send_checkpoint_failure_remains_retryable
    with_tmp_dir do |dir|
      checkpoint_root = File.join(dir, "deliveries")
      real_store = Hive::Digest::DeliveryCheckpointStore.new(root: checkpoint_root)
      failing_store = Class.new(SimpleDelegator) do
        def begin_attempt(checkpoint, **kwargs)
          @begin_attempts = @begin_attempts.to_i + 1
          if @begin_attempts == 2
            raise Hive::Digest::DeliveryCheckpointError,
                  "temporary disk outage before HTML send"
          end

          __getobj__.begin_attempt(checkpoint, **kwargs)
        end
      end.new(real_store)
      calls = []

      with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") do
        sender = Hive::Digest::Sender.new(
          cfg: { "bot" => { "chat_id_allowlist" => [ 123 ] } },
          telegram_factory: lambda { |**|
            fallback_client(
              calls: calls,
              markdown_error: telegram_parse_error,
              html_error: nil
            )
          },
          logger: Hive::Bot::Logger.new(path: File.join(dir, "bot.log")),
          checkpoint_store: failing_store
        )
        assert_raises(Hive::Digest::DeliveryCheckpointError) do
          sender.deliver(
            "*body*", dry_run: false, digest_date: Date.new(2026, 7, 23)
          )
        end
      end

      assert_equal [ :markdown_v2 ], calls
      checkpoint = real_store.load("2026-07-23")
      assert_equal "html", checkpoint.dig("pending_variant", "parse_mode")
      refute checkpoint.key?("in_flight")
    end
  end

  def test_local_html_conversion_failure_is_permanent
    with_tmp_dir do |dir|
      calls = []
      client = fallback_client(
        calls: calls,
        markdown_error: telegram_parse_error,
        html_error: nil
      )
      client.define_singleton_method(:markdown_v2_to_html) do |_text|
        raise Hive::Bot::Telegram::MarkdownV2SplitError,
              "HTML conversion could not preserve the entity"
      end

      with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") do
        assert_raises(Hive::Digest::PermanentDeliveryError) do
          sender_for(
            client,
            checkpoint_root: File.join(dir, "deliveries"),
            logger: Hive::Bot::Logger.new(path: File.join(dir, "bot.log"))
          ).deliver(
            "*body*", dry_run: false, digest_date: Date.new(2026, 7, 23)
          )
        end
      end

      assert_equal [ :markdown_v2 ], calls
    end
  end

  def test_unknown_html_fallback_transport_outcome_is_parked
    with_tmp_dir do |dir|
      calls = []
      client = fallback_client(
        calls: calls,
        markdown_error: telegram_parse_error,
        html_error: RuntimeError.new("connection dropped after HTML send")
      )

      with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") do
        assert_raises(Hive::Digest::AmbiguousDeliveryError) do
          sender_for(
            client,
            checkpoint_root: File.join(dir, "deliveries"),
            logger: Hive::Bot::Logger.new(path: File.join(dir, "bot.log"))
          ).deliver(
            "*body*", dry_run: false, digest_date: Date.new(2026, 7, 23)
          )
        end
      end

      assert_equal [ :markdown_v2, :html ], calls
      checkpoint = JSON.parse(
        File.read(File.join(dir, "deliveries", "2026-07-23.json"))
      )
      assert_equal "html", checkpoint.dig("in_flight", "parse_mode")
      assert checkpoint.key?("permanent_failure")
    end
  end

  def test_failed_fallback_checkpoint_transition_is_permanent
    with_tmp_dir do |dir|
      real_store = Hive::Digest::DeliveryCheckpointStore.new(
        root: File.join(dir, "deliveries")
      )
      failing_store = Class.new(SimpleDelegator) do
        def prepare_fallback(_checkpoint, **)
          raise Hive::Digest::DeliveryCheckpointError,
                "cannot replace rejected Markdown attempt"
        end
      end.new(real_store)
      calls = []

      with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") do
        sender = Hive::Digest::Sender.new(
          cfg: { "bot" => { "chat_id_allowlist" => [ 123 ] } },
          telegram_factory: lambda { |**|
            fallback_client(
              calls: calls,
              markdown_error: telegram_parse_error,
              html_error: nil
            )
          },
          logger: Hive::Bot::Logger.new(path: File.join(dir, "bot.log")),
          checkpoint_store: failing_store
        )
        assert_raises(Hive::Digest::PermanentDeliveryCheckpointError) do
          sender.deliver(
            "*body*", dry_run: false, digest_date: Date.new(2026, 7, 23)
          )
        end
      end

      assert_equal [ :markdown_v2 ], calls
    end
  end

  def test_failed_rejection_checkpoint_transition_is_permanent
    with_tmp_dir do |dir|
      real_store = Hive::Digest::DeliveryCheckpointStore.new(
        root: File.join(dir, "deliveries")
      )
      failing_store = Class.new(SimpleDelegator) do
        def reject_attempt(_checkpoint)
          raise Hive::Digest::DeliveryCheckpointError,
                "cannot clear rejected attempt"
        end
      end.new(real_store)
      calls = []
      server_error = telegram_response_error(500, "Internal Server Error")

      with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") do
        sender = Hive::Digest::Sender.new(
          cfg: { "bot" => { "chat_id_allowlist" => [ 123 ] } },
          telegram_factory: lambda { |**|
            chunk_client(
              chunks: [ "body" ],
              sends: calls,
              failure: ->(_text) { raise server_error }
            )
          },
          logger: Hive::Bot::Logger.new(path: File.join(dir, "bot.log")),
          checkpoint_store: failing_store
        )
        assert_raises(Hive::Digest::PermanentDeliveryCheckpointError) do
          sender.deliver(
            "body", dry_run: false, digest_date: Date.new(2026, 7, 23)
          )
        end
      end

      assert_equal [ "body" ], calls
    end
  end

  def test_failed_permanent_checkpoint_write_stays_permanent
    with_tmp_dir do |dir|
      real_store = Hive::Digest::DeliveryCheckpointStore.new(
        root: File.join(dir, "deliveries")
      )
      failing_store = Class.new(SimpleDelegator) do
        def mark_permanent(_checkpoint, **)
          raise Hive::Digest::DeliveryCheckpointError,
                "cannot record permanent rejection"
        end
      end.new(real_store)
      calls = []
      error_400 = telegram_response_error(400, "Bad Request: chat not found")

      with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") do
        sender = Hive::Digest::Sender.new(
          cfg: { "bot" => { "chat_id_allowlist" => [ 123 ] } },
          telegram_factory: lambda { |**|
            chunk_client(
              chunks: [ "body" ],
              sends: calls,
              failure: ->(_text) { raise error_400 }
            )
          },
          logger: Hive::Bot::Logger.new(path: File.join(dir, "bot.log")),
          checkpoint_store: failing_store
        )
        assert_raises(Hive::Digest::PermanentDeliveryCheckpointError) do
          sender.deliver(
            "body", dry_run: false, digest_date: Date.new(2026, 7, 23)
          )
        end
      end

      assert_equal [ "body" ], calls
    end
  end

  def test_markdown_split_failure_is_permanent_before_any_send
    with_tmp_dir do |dir|
      client = Object.new
      client.define_singleton_method(:message_chunks) do |_text, parse_mode:|
        raise Hive::Bot::Telegram::MarkdownV2SplitError, "unclosed bold"
      end
      client.define_singleton_method(:send_message) { |**| flunk "must not send" }

      with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") do
        error = assert_raises(Hive::Digest::PermanentDeliveryError) do
          sender_for(
            client, checkpoint_root: File.join(dir, "deliveries"), logger: Object.new
          ).deliver(
            "*broken", dry_run: false, digest_date: Date.new(2026, 7, 23)
          )
        end
        assert_match(/unclosed bold/, error.message)
      end

      refute File.exist?(File.join(dir, "deliveries", "2026-07-23.json"))
    end
  end

  def test_checkpoint_for_a_different_chat_fails_closed
    with_tmp_dir do |dir|
      checkpoint_root = File.join(dir, "deliveries")
      with_env("HIVE_TELEGRAM_BOT_TOKEN" => "token") do
        sender_for(
          chunk_client(chunks: [ "body" ], sends: []),
          checkpoint_root: checkpoint_root,
          logger: Object.new
        ).deliver("body", dry_run: false, digest_date: Date.new(2026, 7, 23))

        sends = []
        sender = Hive::Digest::Sender.new(
          cfg: { "bot" => { "chat_id_allowlist" => [ 456 ] } },
          telegram_factory: ->(**) { chunk_client(chunks: [ "body" ], sends: sends) },
          logger: Object.new,
          checkpoint_root: checkpoint_root
        )
        error = assert_raises(Hive::Digest::PermanentDeliveryCheckpointError) do
          sender.deliver("body", dry_run: false, digest_date: Date.new(2026, 7, 23))
        end
        assert_match(/recipient differs/, error.message)
        assert_empty sends
      end
    end
  end

  def test_malformed_response_error_is_not_parse_but_is_still_a_permanent_400
    error = telegram_parse_error
    error.define_singleton_method(:error_code) { 400 }
    error.define_singleton_method(:data) { raise JSON::ParserError, "malformed response" }
    sender = Hive::Digest::Sender.new(cfg: {})

    refute sender.send(:telegram_parse_error?, error)
    assert sender.send(:permanent_telegram_response_error?, error)
  end

  def test_unreadable_response_error_code_is_not_assumed_permanent
    error = telegram_parse_error
    error.define_singleton_method(:error_code) do
      raise JSON::ParserError, "malformed response"
    end
    sender = Hive::Digest::Sender.new(cfg: {})

    refute sender.send(:permanent_telegram_response_error?, error)
  end

  private

  def sender_for(client, checkpoint_root:, logger:)
    Hive::Digest::Sender.new(
      cfg: { "bot" => { "chat_id_allowlist" => [ 123 ] } },
      telegram_factory: ->(**) { client },
      logger: logger,
      checkpoint_root: checkpoint_root
    )
  end

  def chunk_client(chunks:, sends:, failure: nil)
    Object.new.tap do |client|
      client.define_singleton_method(:message_chunks) do |_text, parse_mode:|
        raise "wrong parse mode" unless parse_mode == :markdown_v2

        chunks
      end
      client.define_singleton_method(:send_message) do |chat_id:, text:, parse_mode:|
        raise "wrong chat" unless chat_id == 123
        raise "wrong parse mode" unless parse_mode == :markdown_v2

        sends << text
        failure&.call(text)
        [ { "message_id" => sends.size } ]
      end
    end
  end

  def telegram_parse_error
    telegram_response_error(
      400,
      "Bad Request: can't parse entities: Can't find end of Italic entity"
    )
  end

  def telegram_response_error(code, description)
    response = Struct.new(:body, :status).new(
      JSON.generate(error_code: code, description: description),
      code
    )
    ::Telegram::Bot::Exceptions::ResponseError.new(response: response)
  end

  def fallback_client(calls:, markdown_error:, html_error:)
    Object.new.tap do |client|
      client.define_singleton_method(:message_chunks) do |text, parse_mode:|
        [ text ]
      end
      client.define_singleton_method(:markdown_v2_to_html) { |_text| "<b>formatted</b>" }
      client.define_singleton_method(:send_message) do |chat_id:, text:, parse_mode:|
        calls << parse_mode
        raise markdown_error if parse_mode == :markdown_v2 && markdown_error
        raise html_error if parse_mode == :html && html_error

        [ { "message_id" => calls.size } ]
      end
    end
  end
end
