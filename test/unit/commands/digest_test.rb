require "test_helper"
require "hive/commands/digest"

class HiveCommandsDigestTest < Minitest::Test
  Runner = Struct.new(:calls, :result) do
    def run(date:, dry_run:)
      calls << { date: date, dry_run: dry_run }
      result
    end
  end

  def test_dry_run_prints_composed_message
    output = StringIO.new
    runner = Runner.new([], result(status: :empty, message: "Nothing shipped today 🌙"))

    Hive::Commands::Digest.new(
      date: "2026-06-13",
      dry_run: true,
      runner: runner,
      output: output
    ).call

    assert_equal Date.new(2026, 6, 13), runner.calls.first.fetch(:date)
    assert_equal true, runner.calls.first.fetch(:dry_run)
    assert_equal "Nothing shipped today 🌙\n", output.string
  end

  def test_json_output_includes_status_and_message_for_dry_run
    output = StringIO.new
    runner = Runner.new([], result(status: :sent, message: "digest body"))

    Hive::Commands::Digest.new(
      date: "2026-06-13",
      dry_run: true,
      json: true,
      runner: runner,
      output: output
    ).call

    payload = JSON.parse(output.string)
    assert_equal true, payload.fetch("ok")
    assert_equal "hive-digest", payload.fetch("schema")
    assert_equal "2026-06-13", payload.fetch("date")
    assert_equal "sent", payload.fetch("status")
    assert_equal "digest body", payload.fetch("message")
  end

  def test_json_ok_is_false_for_failed_notice
    output = StringIO.new
    runner = Runner.new([], result(status: :failed_notice, message: "fail"))

    Hive::Commands::Digest.new(
      date: "2026-06-13",
      json: true,
      runner: runner,
      output: output
    ).call

    payload = JSON.parse(output.string)
    assert_equal false, payload.fetch("ok"), "a failed digest must report ok=false"
    assert_equal "failed_notice", payload.fetch("status")
  end

  def test_invalid_date_raises_config_error
    command = Hive::Commands::Digest.new(date: "13-06-2026", dry_run: true, runner: Runner.new([], nil))

    error = assert_raises(Hive::ConfigError) { command.call }
    assert_match(/YYYY-MM-DD/, error.message)
  end

  private

  def result(status:, message:)
    Hive::Digest::Result.new(
      status: status,
      date: Date.new(2026, 6, 13),
      message: message,
      delivery: nil
    )
  end
end
