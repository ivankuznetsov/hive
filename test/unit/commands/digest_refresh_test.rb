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
end
