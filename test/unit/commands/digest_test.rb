require "test_helper"
require "json_schemer"
require "hive/commands/digest"

class HiveCommandsDigestTest < Minitest::Test
  Runner = Struct.new(:calls, :result) do
    def run(date:, dry_run:)
      calls << { date: date, dry_run: dry_run }
      result
    end
  end

  MergedRunner = Struct.new(:calls, :result) do
    def run(date:, dry_run:, repos:)
      calls << { date: date, dry_run: dry_run, repos: repos }
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

  def test_blank_date_defers_default_to_the_runner
    # With no --date the command must pass `date: nil` so Hive::Digest.run
    # owns the single "local day that just ended" default — it must NOT
    # compute its own default here (that duplication is what we removed).
    output = StringIO.new
    runner = Runner.new([], result(status: :empty, message: "Nothing shipped today 🌙"))

    Hive::Commands::Digest.new(date: nil, dry_run: true, runner: runner, output: output).call

    assert_nil runner.calls.first.fetch(:date),
               "a blank --date must defer the default to the runner, not be computed in the command"
  end

  def test_invalid_date_raises_config_error
    command = Hive::Commands::Digest.new(date: "13-06-2026", dry_run: true, runner: Runner.new([], nil))

    error = assert_raises(Hive::ConfigError) { command.call }
    assert_match(/YYYY-MM-DD/, error.message)
  end

  def test_json_emits_error_envelope_on_bad_date_then_reraises
    output = StringIO.new
    command = Hive::Commands::Digest.new(
      date: "13-06-2026", json: true, runner: Runner.new([], nil), output: output
    )

    assert_raises(Hive::ConfigError) { command.call }

    payload = JSON.parse(output.string)
    assert_equal false, payload.fetch("ok")
    assert_equal "hive-digest", payload.fetch("schema")
    assert_equal "config", payload.fetch("error_kind")
    assert_equal "ConfigError", payload.fetch("error_class")
    assert_equal Hive::ExitCodes::CONFIG, payload.fetch("exit_code")
    assert_match(/YYYY-MM-DD/, payload.fetch("message"))
  end

  def test_bad_date_without_json_emits_no_envelope
    output = StringIO.new
    command = Hive::Commands::Digest.new(date: "13-06-2026", runner: Runner.new([], nil), output: output)

    assert_raises(Hive::ConfigError) { command.call }
    assert_equal "", output.string,
                 "without --json the command must not print a JSON envelope (bare stderr only)"
  end

  def test_json_payload_includes_resolved_chat_id
    output = StringIO.new
    delivery = Hive::Digest::Sender::SendResult.new(
      chat_id: 4242, responses: [], dry_run: false, text: "body"
    )
    runner = Runner.new(
      [], Hive::Digest::Result.new(status: :sent, date: Date.new(2026, 6, 13), message: "body", delivery: delivery)
    )

    Hive::Commands::Digest.new(date: "2026-06-13", json: true, runner: runner, output: output).call

    assert_equal 4242, JSON.parse(output.string).fetch("chat_id"),
                 "the --json envelope must surface the resolved chat_id for post-send auditability"
  end

  def test_well_formed_but_impossible_date_raises_config_error
    # Passes the YYYY-MM-DD shape check but Window.parse_date raises a
    # Date::Error (an ArgumentError subclass) the command must translate.
    command = Hive::Commands::Digest.new(date: "2026-13-45", dry_run: true, runner: Runner.new([], nil))

    error = assert_raises(Hive::ConfigError) { command.call }
    assert_match(/YYYY-MM-DD/, error.message)
  end

  def test_plain_output_prints_status_and_date
    output = StringIO.new
    runner = Runner.new([], result(status: :sent, message: "digest body"))

    Hive::Commands::Digest.new(
      date: "2026-06-13",
      runner: runner,
      output: output
    ).call

    assert_equal false, runner.calls.first.fetch(:dry_run)
    assert_equal "hive digest: sent for 2026-06-13\n", output.string
  end

  def test_source_omitted_uses_shipped_digest_runner_unchanged
    output = StringIO.new
    runner = Runner.new([], result(status: :empty, message: "Nothing shipped today 🌙"))
    merged = MergedRunner.new([], nil)

    Hive::Commands::Digest.new(
      date: "2026-06-13",
      dry_run: true,
      runner: runner,
      merged_runner: merged,
      output: output
    ).call

    assert_equal [ { date: Date.new(2026, 6, 13), dry_run: true } ], runner.calls
    assert_empty merged.calls
  end

  def test_source_merged_prs_dispatches_to_merged_runner
    output = StringIO.new
    runner = Runner.new([], nil)
    merged = MergedRunner.new([], merged_result)

    Hive::Commands::Digest.new(
      date: "2026-06-13",
      dry_run: true,
      source: "merged-prs",
      repos: [ "owner/repo" ],
      runner: runner,
      merged_runner: merged,
      output: output
    ).call

    assert_empty runner.calls
    assert_equal [ { date: Date.new(2026, 6, 13), dry_run: true, repos: [ "owner/repo" ] } ], merged.calls
    assert_includes output.string, "Merged PR digest"
  end

  def test_repo_without_source_implies_merged_prs
    output = StringIO.new
    merged = MergedRunner.new([], merged_result)

    Hive::Commands::Digest.new(
      date: "2026-06-13",
      dry_run: true,
      repos: [ "owner/repo" ],
      runner: Runner.new([], nil),
      merged_runner: merged,
      output: output
    ).call

    assert_equal [ { date: Date.new(2026, 6, 13), dry_run: true, repos: [ "owner/repo" ] } ], merged.calls
  end

  def test_unknown_source_raises_config_error_and_json_uses_shipped_schema
    output = StringIO.new
    command = Hive::Commands::Digest.new(
      date: "2026-06-13",
      source: "unknown",
      json: true,
      runner: Runner.new([], nil),
      output: output
    )

    error = assert_raises(Hive::ConfigError) { command.call }

    assert_match(/--source must be 'merged-prs'/, error.message)
    payload = JSON.parse(output.string)
    assert_equal "hive-digest", payload.fetch("schema")
    assert_equal "config", payload.fetch("error_kind")
  end

  def test_merged_pr_json_payload_validates_against_schema
    output = StringIO.new
    delivery = Hive::Digest::Sender::SendResult.new(
      chat_id: 4242, responses: [], dry_run: false, text: "body"
    )
    merged = MergedRunner.new([], merged_result(delivery: delivery))

    Hive::Commands::Digest.new(
      date: "2026-06-13",
      source: "merged-prs",
      json: true,
      merged_runner: merged,
      output: output
    ).call

    payload = JSON.parse(output.string)
    assert_equal "hive-merged-pr-digest", payload.fetch("schema")
    assert_equal "merged-prs", payload.fetch("source")
    assert_nil payload.fetch("message")
    assert_equal 4242, payload.fetch("chat_id")
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-merged-pr-digest"))))
    assert_empty schema.validate(payload).map { |e| e["error"] }
  end

  def test_merged_pr_dry_run_json_payload_validates_against_schema
    # The dry-run envelope (message set, chat_id null) is a distinct shape from
    # the real-send one above; validate it against the schema file too so the
    # inverted message/chat_id nullability can't silently drift out of contract.
    output = StringIO.new
    merged = MergedRunner.new([], merged_result(delivery: nil))

    Hive::Commands::Digest.new(
      date: "2026-06-13",
      dry_run: true,
      source: "merged-prs",
      json: true,
      merged_runner: merged,
      output: output
    ).call

    payload = JSON.parse(output.string)
    assert_equal true, payload.fetch("dry_run")
    assert_nil payload.fetch("chat_id")
    assert_equal "Merged PR digest — 2026-06-13\n\nTotal: 1 PR", payload.fetch("message")
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-merged-pr-digest"))))
    assert_empty schema.validate(payload).map { |e| e["error"] }
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

  def merged_result(delivery: nil)
    pr = Hive::Digest::MergedPr::PullRequest.new(
      repo: "owner/repo",
      number: 1,
      title: "Title",
      url: "https://github.com/owner/repo/pull/1",
      mergedAt: "2026-06-13T12:00:00Z",
      author: "alice",
      authorIsBot: false,
      headRefName: "feature",
      isCrossRepository: false,
      hive_slug: nil,
      hive_stage: nil
    )
    Hive::Digest::MergedPr::Result.new(
      date: Date.new(2026, 6, 13),
      repos: [ "owner/repo" ],
      prs: [ pr ],
      count: 1,
      dry_run: delivery.nil?,
      warnings: [],
      message: "Merged PR digest — 2026-06-13\n\nTotal: 1 PR",
      delivery: delivery
    )
  end
end
