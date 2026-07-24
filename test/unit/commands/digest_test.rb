require "test_helper"
require "hive/commands/digest"

class HiveCommandsDigestTest < Minitest::Test
  Runner = Struct.new(:calls, :result, :error) do
    def run(date:, dry_run:, repos:)
      calls << { date: date, dry_run: dry_run, repos: repos }
      raise error if error

      result
    end
  end

  def test_forwards_date_dry_run_and_registered_filters_without_rendering
    output = StringIO.new
    payload = success_payload.merge("status" => "dry_run", "chunks" => [ "one", "two" ])
    runner = Runner.new([], result(payload: payload), nil)

    Hive::Commands::Digest.new(
      date: "2026-06-13",
      dry_run: true,
      repos: [ "owner/one", "owner/two" ],
      runner: runner,
      output: output
    ).call

    assert_equal [
      {
        date: "2026-06-13",
        dry_run: true,
        repos: [ "owner/one", "owner/two" ]
      }
    ], runner.calls
    assert_equal "one\n\ntwo\n", output.string
  end

  def test_json_is_the_prdigest_result_without_a_hive_wrapper
    payload = success_payload.merge(
      "delivery" => {
        "accepted_chunks" => 3,
        "total_chunks" => 3,
        "status" => "completed"
      }
    )
    output = StringIO.new

    Hive::Commands::Digest.new(
      date: "2026-06-13",
      json: true,
      runner: Runner.new([], result(payload: payload), nil),
      output: output
    ).call

    assert_equal payload, JSON.parse(output.string)
    refute JSON.parse(output.string).key?("ok")
    refute_includes output.string, "hive-digest"
  end

  def test_human_success_reports_prdigest_settlement
    output = StringIO.new
    Hive::Commands::Digest.new(
      runner: Runner.new([], result, nil),
      output: output
    ).call

    assert_equal "hive digest: prdigest success; settled=1\n", output.string
  end

  def test_child_failure_emits_its_payload_once_and_preserves_exit
    payload = failure_payload("telegram_permanent", "Telegram rejected HTML")
    child_result = result(payload: payload, exit_code: 4)
    error = Hive::Prdigest::InvocationError.new(child_result)
    output = StringIO.new

    raised = assert_raises(Hive::Prdigest::InvocationError) do
      Hive::Commands::Digest.new(
        json: true,
        runner: Runner.new([], nil, error),
        output: output
      ).call
    end

    assert_equal 4, raised.exit_code
    assert_equal payload, JSON.parse(output.string)
    assert_equal 1, output.string.lines.length
  end

  def test_adapter_setup_failure_uses_prdigest_shape
    output = StringIO.new
    command = Hive::Commands::Digest.new(
      date: "2026-06-13",
      json: true,
      runner: Runner.new([], nil, Hive::ConfigError.new("prdigest is missing")),
      output: output
    )

    assert_raises(Hive::ConfigError) { command.call }
    payload = JSON.parse(output.string)
    assert_equal "prdigest-result", payload.fetch("schema")
    assert_equal 1, payload.fetch("schema_version")
    assert_equal "explicit_date_replay", payload.fetch("mode")
    assert_equal "config", payload.dig("error", "kind")
    assert_nil payload.fetch("delivery")
  end

  def test_unexpected_adapter_failure_is_wrapped_without_duplicate_output
    output = StringIO.new
    command = Hive::Commands::Digest.new(
      json: true,
      runner: Runner.new([], nil, RuntimeError.new("boom")),
      output: output
    )

    error = assert_raises(Hive::InternalError) { command.call }
    assert_match(/internal adapter error/, error.message)
    assert_equal "internal", JSON.parse(output.string).dig("error", "kind")
    assert_equal 1, output.string.lines.length
  end

  def test_broken_pipe_does_not_replace_the_digest_result
    output = Object.new
    output.define_singleton_method(:puts) { |_value| raise Errno::EPIPE }
    expected = result

    actual = Hive::Commands::Digest.new(
      json: true,
      runner: Runner.new([], expected, nil),
      output: output
    ).call

    assert_same expected, actual
  end

  private

  def result(payload: success_payload, exit_code: 0)
    Hive::Prdigest::Result.new(
      payload: payload,
      exit_code: exit_code,
      repositories: [ "owner/repo" ],
      argv: [ "prdigest", "run" ]
    )
  end

  def success_payload
    {
      "schema" => "prdigest-result",
      "schema_version" => 1,
      "status" => "success",
      "mode" => "explicit_date_replay",
      "requested_days" => [ "2026-06-13" ],
      "settled_days" => [ "2026-06-13" ],
      "skipped_days" => [],
      "failed_date" => nil,
      "remaining_days" => [],
      "error" => nil,
      "chunks" => [],
      "delivery" => nil
    }
  end

  def failure_payload(kind, message)
    success_payload.merge(
      "status" => "failure",
      "settled_days" => [],
      "failed_date" => "2026-06-13",
      "remaining_days" => [ "2026-06-13" ],
      "error" => { "kind" => kind, "message" => message }
    )
  end
end
