require "test_helper"
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
    assert_equal result, JSON.parse(output.string)
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
  end
end
