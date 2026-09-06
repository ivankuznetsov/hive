require "test_helper"
require "json_schemer"
require "hive/commands/digest_refresh"

class DigestRefreshCommandTest < Minitest::Test
  def test_delegates_the_explicit_date_and_emits_json
    coordinator = Object.new
    calls = []
    coordinator.define_singleton_method(:refresh) do |**args|
      calls << args
      [ { "local_date" => "2026-08-30", "status" => "closed" } ]
    end
    output = StringIO.new

    result = Hive::Commands::DigestRefresh.new(
      date: "2026-08-30", json: true, coordinator: coordinator, stdout: output
    ).call!

    assert_equal [ { date: "2026-08-30" } ], calls
    emitted = JSON.parse(output.string)
    assert_equal result, emitted
    assert_empty refresh_schema.validate(emitted).to_a
  end

  def test_json_errors_use_the_refresh_contract
    coordinator = Object.new
    coordinator.define_singleton_method(:refresh) do |**|
      raise Hive::DailyDigest::Coordinator::Disabled, "daily digest is disabled"
    end
    output = StringIO.new

    assert_raises(Hive::DailyDigest::Coordinator::Disabled) do
      Hive::Commands::DigestRefresh.new(
        json: true, coordinator: coordinator, stdout: output
      ).call!
    end

    payload = JSON.parse(output.string)
    assert_equal "hive-digest-refresh", payload.fetch("schema")
    assert_equal false, payload.fetch("ok")
    assert_equal "disabled", payload.fetch("error_kind")
    assert_empty refresh_schema.validate(payload).to_a
  end

  def test_text_output_and_unexpected_json_errors_are_bounded
    coordinator = Object.new
    coordinator.define_singleton_method(:refresh) do |**|
      [ { "local_date" => "2026-08-30", "status" => "open" } ]
    end
    output = StringIO.new
    Hive::Commands::DigestRefresh.new(coordinator: coordinator, stdout: output).call
    assert_equal "2026-08-30 open\n", output.string

    exploding = Object.new
    exploding.define_singleton_method(:refresh) { |**| raise "boom" }
    output = StringIO.new
    assert_raises(Hive::InternalError) do
      Hive::Commands::DigestRefresh.new(
        json: true, coordinator: exploding, stdout: output
      ).call
    end
    assert_equal "internal", JSON.parse(output.string).fetch("error_kind")
  end

  def test_error_kinds_and_epipe_cover_all_refresh_outcomes
    command = Hive::Commands::DigestRefresh.new
    cases = {
      Hive::DailyDigest::Coordinator::NotInitialized.new("missing") => "not_initialized",
      Hive::DailyDigest::Coordinator::FutureDate.new("future") => "future_date",
      Hive::DailyDigest::MissingRecord.new("missing") => "missing",
      Hive::DailyDigest::InvalidRecord.new("invalid") => "invalid_date",
      Hive::ConfigError.new("config") => "config",
      Hive::InternalError.new("internal") => "internal",
      Hive::DailyDigest::Error.new("digest") => "digest_error"
    }
    cases.each { |error, kind| assert_equal kind, command.send(:error_kind, error) }

    output = Object.new
    output.define_singleton_method(:puts) { |_value| raise Errno::EPIPE }
    broken = Hive::Commands::DigestRefresh.new(stdout: output)
    broken.send(:emit_error, Hive::ConfigError.new("config"))
    assert_equal true, broken.instance_variable_get(:@emitted)
  end


  private

  def refresh_schema
    @refresh_schema ||= JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-digest-refresh")))
    )
  end
end
