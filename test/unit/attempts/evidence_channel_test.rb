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
    assert_raises(Hive::Attempts::RepositoryError) { writer.write(mismatch) }
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

  def test_descriptor_factory_and_close_are_capability_bounded
    reader, raw_writer = IO.pipe
    raw_writer.autoclose = false
    writer = Hive::Attempts::EvidenceChannel::Writer.for_fd(
      raw_writer.fileno, route: ROUTE
    )
    assert writer.write(SIGNAL)
    assert_equal SIGNAL, Hive::Attempts::EvidenceChannel.read(reader, route: ROUTE)
    assert_nil writer.close

    assert_raises(Hive::Attempts::RepositoryError) do
      Hive::Attempts::EvidenceChannel::Writer.for_fd("invalid", route: ROUTE)
    end

    failing_io = Object.new
    failing_io.define_singleton_method(:closed?) { false }
    failing_io.define_singleton_method(:close) { raise IOError, "close failed" }
    assert_nil Hive::Attempts::EvidenceChannel::Writer.new(
      io: failing_io, route: ROUTE
    ).close
  ensure
    raw_writer&.close unless raw_writer&.closed?
  end

  def test_account_signal_and_invalid_class_provenance_hint_and_scope_fail_closed
    account_signal = SIGNAL.merge(
      "failure_class" => "provider_outage",
      "scope" => {
        "kind" => "provider_account", "provider_account_id" => "account-a", "model" => nil
      }
    )
    assert_equal account_signal, Hive::Attempts::EvidenceChannel.validate_signal(
      account_signal, route: ROUTE
    )

    invalid = [
      SIGNAL.merge("failure_class" => "authentication"),
      SIGNAL.merge("provenance" => "stdout"),
      SIGNAL.merge("reset_hint_seconds" => -1),
      SIGNAL.merge("scope" => { "kind" => "model" })
    ]
    invalid.each do |signal|
      assert_raises(Hive::Attempts::RepositoryError) do
        Hive::Attempts::EvidenceChannel.validate_signal(signal, route: ROUTE)
      end
    end
    assert_raises(Hive::Attempts::RepositoryError) do
      Hive::Attempts::EvidenceChannel.validate_signal(
        SIGNAL, route: ROUTE.reject { |key, _| key == "model" }
      )
    end
  end

  def test_materialize_uses_record_index_access_when_available
    routing = { "mode" => "explicit", "route" => ROUTE }
    record = Object.new
    record.define_singleton_method(:[]) { |key| key == "routing" ? routing : nil }
    record.define_singleton_method(:attempt_id) { "attempt-1" }
    reference = { "path" => "logs/attempt.frames", "size" => 1, "sha256" => "a" * 64 }

    evidence = Hive::Attempts::EvidenceChannel.materialize(
      SIGNAL, record: record, source_reference: reference
    )
    assert_equal "model_capacity", evidence.fetch("failure_class")
  end

  def test_scope_route_and_materialization_identity_errors_are_typed
    invalid_scope = SIGNAL.merge(
      "scope" => {
        "kind" => "future", "provider_account_id" => "account-a", "model" => "model-a"
      }
    )
    assert_raises(Hive::Attempts::RepositoryError) do
      Hive::Attempts::EvidenceChannel.validate_signal(invalid_scope, route: ROUTE)
    end
    assert_raises(Hive::Attempts::RepositoryError) do
      Hive::Attempts::EvidenceChannel.validate_signal(
        SIGNAL, route: ROUTE.merge("route_id" => "")
      )
    end

    record = Object.new
    record.define_singleton_method(:[]) { |_key| {} }
    assert_raises(Hive::Attempts::RepositoryError) do
      Hive::Attempts::EvidenceChannel.materialize(
        SIGNAL, record: record,
        source_reference: { "path" => "log", "size" => 1, "sha256" => "a" * 64 }
      )
    end
  end
end
