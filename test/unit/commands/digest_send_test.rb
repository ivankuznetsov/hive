require "test_helper"
require "json_schemer"
require "hive/commands/digest_send"

class DigestSendCommandTest < Minitest::Test
  FakeDelivery = Struct.new(:result, :error, :calls) do
    def deliver(**options)
      calls << options
      raise error if error

      result
    end
  end

  def test_json_success_is_schema_valid_and_forwards_explicit_retry
    output = StringIO.new
    delivery = FakeDelivery.new(result, nil, [])
    payload = Hive::Commands::DigestSend.new(
      date: "2026-08-30", retry: true, json: true,
      output: output, delivery: delivery
    ).call

    assert_equal [ { date: "2026-08-30", retry_requested: true } ], delivery.calls
    assert_equal payload, JSON.parse(output.string)
    assert_empty schema.validate(payload).to_a
    refute payload.key?("chat_id")
    refute payload.key?("message")
  end

  def test_text_distinguishes_suppression_unknown_and_deduplication
    {
      "suppressed_empty" => /suppressed/,
      "unknown" => /outcome is unknown/,
      "failed" => /bounded retry limit/,
      "sent" => /already sent/
    }.each do |outcome, expected|
      output = StringIO.new
      value = result(outcome: outcome, deduplicated: outcome == "sent")
      Hive::Commands::DigestSend.new(
        date: "2026-08-30", output: output,
        delivery: FakeDelivery.new(value, nil, [])
      ).call
      assert_match expected, output.string
    end
  end

  def test_text_covers_fresh_send_and_unknown_transport_outcome
    {
      "sent" => /Sent digest/,
      "queued" => /delivery outcome: queued/
    }.each do |outcome, expected|
      output = StringIO.new
      Hive::Commands::DigestSend.new(
        date: "2026-08-30", output: output,
        delivery: FakeDelivery.new(result(outcome: outcome), nil, [])
      ).call
      assert_match expected, output.string
    end
  end

  def test_missing_date_and_typed_delivery_errors_emit_stable_error_envelopes
    output = StringIO.new
    command = Hive::Commands::DigestSend.new(
      json: true, output: output,
      delivery: FakeDelivery.new(result, nil, [])
    )
    assert_raises(Hive::UsageError) { command.call }
    error = JSON.parse(output.string)
    assert_equal "usage", error.fetch("error_kind")
    assert_empty schema.validate(error).to_a

    output = StringIO.new
    failure = Hive::DailyDigest::Delivery::NotClosed.new("still open")
    command = Hive::Commands::DigestSend.new(
      date: "2026-08-30", json: true, output: output,
      delivery: FakeDelivery.new(nil, failure, [])
    )
    assert_raises(Hive::DailyDigest::Delivery::NotClosed) { command.call }
    assert_equal "not_closed", JSON.parse(output.string).fetch("error_kind")
  end

  def test_invalid_date_and_unexpected_error_are_typed
    assert_raises(Hive::UsageError) do
      Hive::Commands::DigestSend.new(
        date: "not-a-date", delivery: FakeDelivery.new(result, nil, [])
      ).call
    end

    output = StringIO.new
    assert_raises(Hive::InternalError) do
      Hive::Commands::DigestSend.new(
        date: "2026-08-30", json: true, output: output,
        delivery: FakeDelivery.new(nil, RuntimeError.new("boom"), [])
      ).call
    end
    assert_equal "internal", JSON.parse(output.string).fetch("error_kind")
  end

  def test_error_kinds_and_epipe_cover_every_delivery_boundary
    command = Hive::Commands::DigestSend.new(date: "2026-08-30")
    cases = {
      Hive::DailyDigest::MissingRecord.new("missing") => "missing",
      Hive::DailyDigest::PrunedRecord.new("pruned") => "pruned",
      Hive::DailyDigest::Delivery::DeliveryFailed.new("failed") => "delivery_failed",
      Hive::ConfigError.new("config") => "config",
      Hive::DailyDigest::Error.new("digest") => "digest_error",
      RuntimeError.new("other") => "internal"
    }
    cases.each { |error, kind| assert_equal kind, command.send(:error_kind, error) }

    output = Object.new
    output.define_singleton_method(:puts) { |_value| raise Errno::EPIPE }
    broken = Hive::Commands::DigestSend.new(date: "2026-08-30", output: output)
    broken.send(:emit, { "ok" => true })
    assert_equal true, broken.instance_variable_get(:@emitted)
  end

  private

  def result(outcome: "sent", deduplicated: false)
    Hive::DailyDigest::Delivery::Result.new(
      local_date: "2026-08-30", record_id: "a" * 64,
      amendment_frontier: "b" * 64, payload_hash: "c" * 64,
      web_url: "https://hive.example/digests/2026-08-30",
      outcome: outcome, attempt: 1, deduplicated: deduplicated,
      retry_requested: false
    )
  end

  def schema
    @schema ||= JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-digest-send")))
    )
  end
end
