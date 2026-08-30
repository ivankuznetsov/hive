require "test_helper"
require "hive/commands/digest_prune"

class DigestPruneCommandTest < Minitest::Test
  def test_dry_run_and_confirmed_prune_delegate_without_touching_other_evidence
    calls = []
    pruner = Object.new
    pruner.define_singleton_method(:call) do |**options|
      calls << options
      {
        "before" => options.fetch(:before), "dry_run" => options.fetch(:dry_run),
        "eligible" => [ "2026-08-01" ],
        "pruned" => options.fetch(:confirm) ? [ "2026-08-01" ] : []
      }
    end

    output = StringIO.new
    payload = Hive::Commands::DigestPrune.new(
      before: "2026-08-30", dry_run: true, confirm: false,
      json: true, pruner: pruner, stdout: output
    ).call!
    assert_equal({ before: "2026-08-30", dry_run: true, confirm: false }, calls.last)
    assert_equal payload, JSON.parse(output.string)

    Hive::Commands::DigestPrune.new(
      before: "2026-08-30", dry_run: false, confirm: true,
      pruner: pruner, stdout: StringIO.new
    ).call!
    assert_equal({ before: "2026-08-30", dry_run: false, confirm: true }, calls.last)
  end

  def test_requires_before_and_an_explicit_mode
    error = assert_raises(Hive::UsageError) do
      Hive::Commands::DigestPrune.new(before: nil, dry_run: true).call!
    end
    assert_match(/--before/, error.message)

    error = assert_raises(Hive::UsageError) do
      Hive::Commands::DigestPrune.new(before: "2026-08-30").call!
    end
    assert_match(/--dry-run or --yes/, error.message)
  end

  def test_json_errors_use_the_prune_contract
    output = StringIO.new
    error = assert_raises(Hive::UsageError) do
      Hive::Commands::DigestPrune.new(
        before: "2026-08-30", json: true, stdout: output
      ).call!
    end

    payload = JSON.parse(output.string)
    assert_equal "hive-digest-prune", payload.fetch("schema")
    assert_equal false, payload.fetch("ok")
    assert_equal "usage", payload.fetch("error_kind")
    assert_equal error.message, payload.fetch("message")
  end
end
