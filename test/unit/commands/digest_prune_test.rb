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

    error = assert_raises(Hive::UsageError) do
      Hive::Commands::DigestPrune.new(
        before: "2026-08-30", dry_run: true, confirm: true
      ).call!
    end
    assert_match(/either --dry-run or --yes/, error.message)
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

  def test_unexpected_json_error_is_wrapped
    pruner = Object.new
    pruner.define_singleton_method(:call) { |**| raise "boom" }
    output = StringIO.new
    assert_raises(Hive::InternalError) do
      Hive::Commands::DigestPrune.new(
        before: "2026-08-30", dry_run: true, json: true,
        pruner: pruner, stdout: output
      ).call!
    end
    assert_equal "internal", JSON.parse(output.string).fetch("error_kind")
  end

  def test_error_kinds_and_epipe_cover_every_prune_boundary
    command = Hive::Commands::DigestPrune.new(before: "2026-08-30", dry_run: true)
    cases = {
      Hive::DailyDigest::Pruner::ConfirmationRequired.new("confirm") => "confirmation_required",
      Hive::DailyDigest::InvalidRecord.new("invalid") => "invalid_date",
      Hive::DailyDigest::MissingRecord.new("missing") => "missing",
      Hive::DailyDigest::Store::ImmutableRecord.new("open") => "immutable",
      Hive::ConfigError.new("config") => "config",
      Hive::InternalError.new("internal") => "internal",
      Hive::DailyDigest::Error.new("digest") => "digest_error"
    }
    cases.each { |error, kind| assert_equal kind, command.send(:error_kind, error) }

    output = Object.new
    output.define_singleton_method(:puts) { |_value| raise Errno::EPIPE }
    broken = Hive::Commands::DigestPrune.new(
      before: "2026-08-30", dry_run: true, stdout: output
    )
    broken.send(:emit_error, Hive::ConfigError.new("config"))
    assert_equal true, broken.instance_variable_get(:@emitted)
  end
end
