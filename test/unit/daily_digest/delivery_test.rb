require "test_helper"
require "hive/daily_digest/delivery"

class DailyDigestDeliveryTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.iso8601("2026-08-31T09:00:00Z")

  FakeReader = Struct.new(:record) do
    def read(date:)
      raise "wrong date" unless date == record.fetch("local_date")

      JSON.parse(JSON.generate(record))
    end
  end

  class FakeTelegram
    attr_reader :messages

    def initialize(error: nil)
      @error = error
      @messages = []
    end

    def send_message(**message)
      raise @error if @error

      @messages << message
      [ { "message_id" => 1 } ]
    end
  end

  class FakeLogger
    attr_reader :events

    def initialize = @events = []
    def event(name, **attributes) = @events << [ name, attributes ]
  end

  class DefiniteTelegramError < StandardError; end

  def test_sends_one_html_recap_to_only_the_first_private_allowlisted_chat
    with_tmp_dir do |dir|
      telegram = FakeTelegram.new
      delivery, ledger = build_delivery(dir, telegram: telegram)

      result = delivery.deliver(date: DATE)

      assert_equal "sent", result.outcome
      assert_equal false, result.deduplicated
      assert_equal 1, telegram.messages.length
      assert_equal 12_345, telegram.messages.first.fetch(:chat_id)
      assert_equal :html, telegram.messages.first.fetch(:parse_mode)
      refute_includes telegram.messages.first.fetch(:text), "PRIVATE QUESTION"
      assert_equal "sent", ledger.read(DATE).fetch("outcome")

      duplicate = delivery.deliver(date: DATE)
      assert_equal "sent", duplicate.outcome
      assert_equal true, duplicate.deduplicated
      assert_equal 1, telegram.messages.length
    end
  end

  def test_complete_empty_is_suppressed_without_transport
    with_tmp_dir do |dir|
      telegram = FakeTelegram.new
      token_calls = 0
      delivery, ledger = build_delivery(
        dir, telegram: telegram,
        record: record.merge(
          "content" => "empty", "effective_content" => "empty", "items" => [], "attention" => []
        ),
        token_loader: -> { token_calls += 1; raise "token must not be loaded" }
      )

      result = delivery.deliver(date: DATE)

      assert_equal "suppressed_empty", result.outcome
      assert_equal 0, token_calls
      assert_empty telegram.messages
      assert_equal "suppressed_empty", ledger.read(DATE).fetch("outcome")
    end
  end

  def test_partial_unknown_record_sends_with_incomplete_label
    with_tmp_dir do |dir|
      telegram = FakeTelegram.new
      partial = record.merge(
        "completeness" => "partial", "effective_completeness" => "partial",
        "content" => "unknown", "effective_content" => "unknown", "items" => [],
        "effective_gaps" => [ gap ]
      )
      delivery, = build_delivery(dir, telegram: telegram, record: partial)

      assert_equal "sent", delivery.deliver(date: DATE).outcome
      assert_includes telegram.messages.first.fetch(:text), "Incomplete data"
    end
  end

  def test_ambiguous_failure_is_unknown_and_never_automatically_resent
    with_tmp_dir do |dir|
      telegram = FakeTelegram.new(error: IOError.new("socket closed"))
      delivery, ledger = build_delivery(dir, telegram: telegram)

      result = delivery.deliver(date: DATE)
      assert_equal "unknown", result.outcome
      assert_equal 1, ledger.read(DATE).fetch("attempt")

      second = delivery.deliver(date: DATE)
      assert_equal "unknown", second.outcome
      refute second.deduplicated
      assert_equal 1, ledger.read(DATE).fetch("attempt")
    end
  end

  def test_explicit_retry_rearms_unknown_delivery
    with_tmp_dir do |dir|
      failing = FakeTelegram.new(error: IOError.new("timeout"))
      delivery, ledger = build_delivery(dir, telegram: failing)
      assert_equal "unknown", delivery.deliver(date: DATE).outcome

      working = FakeTelegram.new
      retry_delivery, = build_delivery(dir, telegram: working, ledger: ledger)
      result = retry_delivery.deliver(date: DATE, retry_requested: true)

      assert_equal "sent", result.outcome
      assert_equal 2, result.attempt
      assert_equal 1, working.messages.length
    end
  end

  def test_definite_failures_retry_only_to_the_ledger_bound
    with_tmp_dir do |dir|
      telegram = FakeTelegram.new(error: DefiniteTelegramError.new)
      delivery, ledger = build_delivery(dir, telegram: telegram)

      2.times do
        assert_raises(Hive::DailyDigest::Delivery::DeliveryFailed) do
          delivery.deliver(date: DATE)
        end
      end
      terminal = delivery.deliver(date: DATE)
      assert_equal "failed", terminal.outcome
      assert_equal 3, terminal.attempt
      assert_equal "failed", ledger.read(DATE).fetch("outcome")
      assert_equal "failed", delivery.deliver(date: DATE).outcome
      assert_equal 3, ledger.read(DATE).fetch("attempt")
    end
  end

  def test_destination_and_record_validation_happen_before_ledger_or_transport
    with_tmp_dir do |dir|
      telegram = FakeTelegram.new
      delivery, ledger = build_delivery(
        dir, telegram: telegram, bot: bot_config.merge("chat_id_allowlist" => [ -123, 12_345 ])
      )
      assert_raises(Hive::DailyDigest::Delivery::DestinationError) do
        delivery.deliver(date: DATE)
      end
      assert_nil ledger.read(DATE)
      assert_empty telegram.messages

      open_delivery, = build_delivery(
        File.join(dir, "open"), telegram: telegram, record: record.merge("lifecycle" => "open")
      )
      assert_raises(Hive::DailyDigest::Delivery::NotClosed) do
        open_delivery.deliver(date: DATE)
      end
    end
  end

  def test_missing_token_leaves_a_resumable_prepared_intent
    with_tmp_dir do |dir|
      telegram = FakeTelegram.new
      delivery, ledger = build_delivery(
        dir, telegram: telegram,
        token_loader: -> { raise Hive::ConfigError, "Telegram token missing" }
      )

      assert_raises(Hive::ConfigError) { delivery.deliver(date: DATE) }
      prepared = ledger.read(DATE)
      assert_equal "prepared", prepared.fetch("outcome")
      assert_equal 1, prepared.fetch("attempt")

      resumed, = build_delivery(dir, telegram: telegram, ledger: ledger)
      assert_equal "sent", resumed.deliver(date: DATE).outcome
      assert_equal 1, ledger.read(DATE).fetch("attempt")
      assert_equal 1, telegram.messages.length
    end
  end

  def test_live_delivery_owner_is_reported_without_loading_credentials
    with_tmp_dir do |dir|
      ledger = Hive::DailyDigest::DeliveryLedger.new(
        root: File.join(dir, "deliveries"),
        process_identity: -> { [ 321, "start-321" ] },
        process_alive: ->(_pid, _start) { true }
      )
      rendered = Hive::DailyDigest::TelegramRenderer.new(
        web_origin: "https://hive.example"
      ).render(record)
      ledger.prepare(
        local_date: DATE, record_id: "a" * 64,
        amendment_frontier: rendered.amendment_frontier,
        payload_hash: rendered.payload_hash,
        destination_chat_id: 12_345, now: NOW
      )
      ledger.mark_sending(DATE, attempt: 1, now: NOW)
      token_calls = 0
      delivery, = build_delivery(
        dir, telegram: FakeTelegram.new, ledger: ledger,
        token_loader: -> { token_calls += 1; "test-token" }
      )

      assert_raises(Hive::DailyDigest::Delivery::InFlight) do
        delivery.deliver(date: DATE)
      end
      assert_equal 0, token_calls
      assert_equal "sending", ledger.read(DATE).fetch("outcome")
    end
  end

  def test_default_clock_logger_transport_and_error_classifier_boundaries
    delivery = Hive::DailyDigest::Delivery.new
    assert_instance_of Time, delivery.instance_variable_get(:@clock).call
    assert_nil delivery.send(:delivery_logger)

    with_tmp_dir do |dir|
      logger = delivery.send(
        :delivery_logger,
        { "log_file" => File.join(dir, "daily-digest.log") }
      )
      assert_instance_of Hive::Bot::Logger, logger
      telegram = delivery.send(:build_telegram, token: "token", logger: logger)
      assert_instance_of Hive::Bot::Telegram, telegram
    end

    assert_equal false, delivery.send(:telegram_definite_failure?, IOError.new("offline"))
    response_error = ::Telegram::Bot::Exceptions::ResponseError.allocate
    assert_equal true, delivery.send(:telegram_definite_failure?, response_error)
  end

  private

  DATE = "2026-08-30".freeze

  def build_delivery(dir, telegram:, record: self.record, ledger: nil, bot: bot_config,
                     token_loader: -> { "test-token" })
    ledger ||= Hive::DailyDigest::DeliveryLedger.new(root: File.join(dir, "deliveries"))
    logger = FakeLogger.new
    env_loader = Object.new
    env_loader.define_singleton_method(:load!) { true }
    delivery = Hive::DailyDigest::Delivery.new(
      reader: FakeReader.new(record), ledger: ledger,
      bot_config_loader: -> { bot },
      web_config_loader: -> { { "origin" => "https://hive.example" } },
      env_loader: env_loader,
      token_loader: token_loader,
      telegram_factory: ->(token:, logger:) {
        raise "wrong token" unless token == "test-token"
        raise "wrong logger" unless logger

        telegram
      },
      definite_failure: ->(error) { error.is_a?(DefiniteTelegramError) },
      logger: logger, clock: -> { NOW }
    )
    [ delivery, ledger ]
  end

  def bot_config
    {
      "chat_id_allowlist" => [ 12_345, 67_890 ],
      "log_file" => File::NULL
    }
  end

  def record
    {
      "reader_status" => "ok", "local_date" => DATE, "record_id" => "a" * 64,
      "lifecycle" => "closed", "completeness" => "complete", "content" => "non_empty",
      "effective_completeness" => "complete", "effective_content" => "non_empty",
      "items" => [ {
        "fact_id" => "fact-one", "kind" => "stage_transition",
        "project" => "demo", "summary" => "Task advanced"
      } ],
      "attention" => [ {
        "attention_id" => "attention-one", "kind" => "unanswered",
        "project" => "demo", "task_slug" => "task", "stage" => "2-brainstorm",
        "state" => "waiting", "question" => "PRIVATE QUESTION"
      } ],
      "effective_gaps" => [], "amendments" => []
    }
  end

  def gap
    { "gap_id" => "gap-one", "source" => "github", "scope" => "demo" }
  end
end
