require "test_helper"
require "hive/attempts/evidence_channel"

class AttemptsEvidenceChannelTest < Minitest::Test
  ROUTE = {
    "route_id" => "account-a/model-a", "provider_account_id" => "account-a",
    "adapter" => "codex", "launch_binding_id" => "default",
    "model" => "model-a", "effort" => "high"
  }.freeze
  SIGNAL = {
    "failure_class" => "model_capacity",
    "scope" => {
      "kind" => "model", "provider_account_id" => "account-a", "model" => "model-a"
    },
    "provenance" => "codex_jsonl_transport",
    "reset_hint_seconds" => 30
  }.freeze

  def test_write_once_round_trip_is_strict_and_bounded
    reader, writer_io = IO.pipe
    writer = Hive::Attempts::EvidenceChannel::Writer.new(io: writer_io, route: ROUTE)

    assert writer.write(SIGNAL)
    refute writer.write(SIGNAL)
    assert_equal SIGNAL, Hive::Attempts::EvidenceChannel.read(reader, route: ROUTE)
  end

  def test_empty_malformed_duplicate_and_raw_field_payloads_are_ignored
    [ "", "{\n", "{}\n{}\n", JSON.generate(SIGNAL.merge("message" => "secret-canary")) + "\n" ].each do |payload|
      reader, writer = IO.pipe
      writer.write(payload)
      writer.close
      assert_nil Hive::Attempts::EvidenceChannel.read(reader, route: ROUTE)
    end
  end

  def test_route_mismatch_and_broken_pipe_cannot_publish
    reader, writer_io = IO.pipe
    reader.close
    writer = Hive::Attempts::EvidenceChannel::Writer.new(io: writer_io, route: ROUTE)
    refute writer.write(SIGNAL)

    mismatch = Marshal.load(Marshal.dump(SIGNAL))
    mismatch["scope"]["model"] = "other"
    reader, writer_io = IO.pipe
    writer = Hive::Attempts::EvidenceChannel::Writer.new(io: writer_io, route: ROUTE)
    assert_raises(Hive::Attempts::StoreError) { writer.write(mismatch) }
  ensure
    reader&.close unless reader&.closed?
    writer_io&.close unless writer_io&.closed?
  end

  def test_materialized_evidence_fingerprints_only_safe_fields
    record = Object.new
    routing = { "mode" => "explicit", "route" => ROUTE }
    record.define_singleton_method(:fetch) { |key| key == "routing" ? routing : raise(KeyError) }
    record.define_singleton_method(:attempt_id) { "attempt-1" }
    reference = { "path" => "logs/attempt.frames", "size" => 1, "sha256" => "a" * 64 }

    evidence = Hive::Attempts::EvidenceChannel.materialize(
      SIGNAL, record: record, source_reference: reference
    )

    assert_equal "model_capacity", evidence.fetch("failure_class")
    assert_equal reference, evidence.fetch("source_reference")
    refute_includes JSON.generate(evidence), "message"
  end
end
