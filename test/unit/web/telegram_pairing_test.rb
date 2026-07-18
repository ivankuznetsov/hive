require "test_helper"
require "hive/web/telegram_pairing"

class WebTelegramPairingTest < Minitest::Test
  def test_pending_returns_the_shared_command_json_payload
    calls = []
    command_class = command_factory(calls) do |subcommand, kwargs|
      assert_equal "list", subcommand
      kwargs.fetch(:output).puts JSON.generate(
        "schema" => "hive-pairing-list",
        "pending" => [ { "code" => "ABCDEFGH", "chat_id" => 123 } ]
      )
      []
    end

    pending = Hive::Web::TelegramPairing.new(command_class: command_class).pending

    assert_equal [ { "code" => "ABCDEFGH", "chat_id" => 123 } ], pending
    assert_equal true, calls.first.last.fetch(:json)
  end

  def test_approve_delegates_to_the_atomic_pairing_command
    calls = []
    expected = { "chat_id" => 123, "reloaded" => false, "notice_queued" => true }
    command_class = command_factory(calls) { |_subcommand, _kwargs| expected }

    result = Hive::Web::TelegramPairing.new(command_class: command_class).approve("abcdefgh")

    assert_equal expected, result
    subcommand, kwargs = calls.fetch(0)
    assert_equal "approve", subcommand
    assert_equal %w[telegram abcdefgh], kwargs.fetch(:args)
    assert_equal true, kwargs.fetch(:json)
  end

  def test_pending_maps_malformed_command_output_to_a_typed_error
    command_class = command_factory([]) do |_subcommand, kwargs|
      kwargs.fetch(:output).write("not-json")
      []
    end

    error = assert_raises(Hive::Error) do
      Hive::Web::TelegramPairing.new(command_class: command_class).pending
    end
    assert_match(/could not read pending Telegram pairings/, error.message)
  end

  private

  def command_factory(calls, &response)
    Object.new.tap do |factory|
      factory.define_singleton_method(:new) do |subcommand, **kwargs|
        calls << [ subcommand, kwargs ]
        Object.new.tap do |command|
          command.define_singleton_method(:call) { response.call(subcommand, kwargs) }
        end
      end
    end
  end
end
