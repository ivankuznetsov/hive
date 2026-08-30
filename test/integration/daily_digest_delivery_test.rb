require "test_helper"
require "hive/daily_digest/delivery"

class DailyDigestDeliveryIntegrationTest < Minitest::Test
  include HiveTestHelper

  DATE = "2026-08-30".freeze
  NOW = Time.iso8601("2026-08-31T09:00:00Z")

  class FakeTelegram
    attr_reader :messages

    def initialize(error: nil)
      @error = error
      @messages = []
    end

    def send_message(**message)
      @messages << message
      raise @error if @error

      [ { "message_id" => 1 } ]
    end
  end

  def test_sent_record_is_not_resent_for_amendments_and_pruning_keeps_receipt
    with_tmp_dir do |dir|
      store = build_store(dir)
      ledger = Hive::DailyDigest::DeliveryLedger.new(root: File.join(dir, "deliveries"))
      first_transport = FakeTelegram.new
      first = delivery(store:, ledger:, telegram: first_transport).deliver(date: DATE)
      persisted = ledger.read(DATE)

      assert_equal "sent", first.outcome
      assert_equal 1, first_transport.messages.length
      store.append_amendment(DATE, amendment)

      second_transport = FakeTelegram.new
      second = delivery(store:, ledger:, telegram: second_transport).deliver(date: DATE)
      assert_equal "sent", second.outcome
      assert_equal true, second.deduplicated
      assert_empty second_transport.messages,
                   "late amendments remain visible but never trigger an implicit second recap"
      assert_equal persisted.fetch("amendment_frontier"), second.amendment_frontier

      store.prune(DATE, pruned_at: NOW + 60, reason: "operator_confirmed")
      assert_equal "pruned", store.read(DATE).fetch("lifecycle")
      assert_equal "sent", ledger.read(DATE).fetch("outcome")
      assert_equal persisted.fetch("receipt_id"), ledger.read(DATE).fetch("receipt_id")
    end
  end

  def test_restart_promotes_interrupted_send_to_unknown_before_loading_token
    with_tmp_dir do |dir|
      store = build_store(dir)
      ledger = Hive::DailyDigest::DeliveryLedger.new(root: File.join(dir, "deliveries"))
      interrupted = FakeTelegram.new(error: Interrupt.new("terminated after dispatch"))

      assert_raises(Interrupt) do
        delivery(store:, ledger:, telegram: interrupted).deliver(date: DATE)
      end
      assert_equal "sending", ledger.read(DATE).fetch("outcome")

      token_calls = 0
      restarted = delivery(
        store:, ledger:, telegram: FakeTelegram.new,
        token_loader: -> { token_calls += 1; raise "must not load a token for unknown" }
      )
      result = restarted.deliver(date: DATE)

      assert_equal "unknown", result.outcome
      assert_equal 0, token_calls
      assert_equal "interrupted_send", ledger.read(DATE).fetch("reason_code")
      assert_equal "unknown", restarted.deliver(date: DATE).outcome
      assert_equal 0, token_calls
    end
  end

  private

  def build_store(dir)
    store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
    store.write_base(record)
    store
  end

  def delivery(store:, ledger:, telegram:, token_loader: -> { "test-token" })
    logger = Object.new
    logger.define_singleton_method(:event) { |_name, **_attributes| true }
    env = Object.new
    env.define_singleton_method(:load!) { true }
    reader = Hive::DailyDigest::Reader.new(
      store: store,
      config_loader: -> { { "coverage_started_at" => "2026-08-30T00:00:00Z" } },
      clock: -> { NOW }
    )
    Hive::DailyDigest::Delivery.new(
      reader: reader, ledger: ledger,
      bot_config_loader: -> {
        { "chat_id_allowlist" => [ 12_345, 67_890 ], "log_file" => File::NULL }
      },
      web_config_loader: -> { { "origin" => "https://hive.example" } },
      env_loader: env, token_loader: token_loader,
      telegram_factory: ->(token:, logger:) {
        raise "wrong token" unless token == "test-token"
        raise "missing logger" unless logger

        telegram
      },
      logger: logger, clock: -> { NOW }
    )
  end

  def record
    {
      "schema" => "hive-digest-record", "schema_version" => 1,
      "local_date" => DATE, "sequence" => 1, "time_zone" => "UTC",
      "starts_at" => "2026-08-30T00:00:00.000000Z",
      "ends_at" => "2026-08-31T00:00:00.000000Z",
      "boundary_kind" => "calendar_day", "lifecycle" => "closed",
      "closed_at" => "2026-08-31T00:00:01.000000Z",
      "completeness" => "complete", "content" => "non_empty",
      "last_materialized_at" => "2026-08-31T00:00:01.000000Z",
      "projects" => [ { "project_id" => "project-1", "name" => "demo" } ],
      "items" => [ {
        "fact_id" => "fact:created", "kind" => "task_created",
        "project_id" => "project-1", "project" => "demo", "task_slug" => "task",
        "summary" => "Task created", "occurred_at" => "2026-08-30T10:00:00Z",
        "observed_at" => "2026-08-30T10:00:00Z"
      } ],
      "attention" => [], "gaps" => [], "source_frontiers" => {}
    }
  end

  def amendment
    {
      "amendment_id" => "late:fact:merged", "kind" => "late_fact", "source" => "github",
      "event_at" => "2026-08-30T20:00:00Z", "observed_at" => "2026-08-31T10:00:00Z",
      "amended_at" => "2026-08-31T10:00:01Z",
      "items" => [ {
        "fact_id" => "fact:merged", "kind" => "pr_merged", "project_id" => "project-1",
        "project" => "demo", "task_slug" => "task", "summary" => "PR merged",
        "occurred_at" => "2026-08-30T20:00:00Z", "observed_at" => "2026-08-31T10:00:00Z"
      } ],
      "resolved_gap_ids" => []
    }
  end
end
