require "test_helper"
require "json"
require "json_schemer"
require "hive/task_closure"
require "hive/task_closure_result"

class TaskClosureResultTest < Minitest::Test
  def test_failures_classify_every_closure_and_command_error_inside_the_closed_schema
    preview = { "schema" => "hive-task-closure-input", "ok" => false, "errors" => [], "blockers" => [] }
    {
      Hive::UsageError.new("bad flag") => "usage",
      Hive::AmbiguousSlug.new("two tasks", slug: "task", candidates: [ "a", "b" ]) => "usage",
      Hive::WrongStage.new("moved", current_stage: "9-done", target_stage: "4-execute") => "wrong_stage",
      Hive::TaskClosure::InvalidInput.new("bad input") => "usage",
      Hive::TaskClosure::Unauthorized.new("not confirmed") => "unauthorized",
      Hive::TaskClosure::VerificationFailed.new("blocked") => "verification_failed",
      Hive::TaskClosure::StalePreview.new("changed") => "stale_preview",
      Hive::TaskClosure::InvalidReceipt.new("quarantined") => "invalid_receipt",
      Hive::ConfigError.new("config") => "config",
      Hive::ConcurrentRunError.new("busy") => "concurrent_run",
      Hive::InternalError.new("boom") => "internal",
      Hive::CommandConflict.new => "command_conflict",
      Hive::Error.new("other") => "error"
    }.each do |error, kind|
      %w[preview apply].each do |mode|
        payload = Hive::TaskClosureResult.failed(error, mode: mode, preview: preview)

        assert_equal kind, payload.fetch("error_kind"), error.class.name
        assert_equal false, payload.fetch("ok")
        assert_equal mode, payload.fetch("mode")
        refute payload.key?("applied"), "a failure must never claim an applied closure"
        assert_empty schemer.validate(payload).to_a, "#{error.class}: #{payload.inspect}"
      end
    end
  end

  def test_failed_rejects_an_unknown_mode
    assert_raises(ArgumentError) do
      Hive::TaskClosureResult.failed(Hive::UsageError.new("x"), mode: "dry-run")
    end
  end

  def test_applied_hoists_the_receipt_identity_and_validates
    receipt = {
      "schema" => "hive-task-closure", "schema_version" => 1, "status" => "confirmed",
      "reason" => "superseded",
      "task" => { "project" => "app", "slug" => "task", "id" => nil, "workflow" => "coding" },
      "preview_digest" => "c" * 64, "receipt_digest" => "d" * 64
    }

    payload = Hive::TaskClosureResult.applied(receipt)

    assert_equal true, payload.fetch("applied")
    assert_equal "apply", payload.fetch("mode")
    assert_equal "d" * 64, payload.fetch("receipt_digest")
    assert_equal receipt, payload.fetch("receipt")
    assert_empty schemer.validate(payload).to_a
  end

  def test_applied_payload_cannot_masquerade_as_a_preview_and_vice_versa
    preview = Hive::TaskClosureResult.preview({ "ok" => true }, next_command: "hive archive t --yes --json")
    input_schema = JSON.parse(File.read(Hive::Schemas.schema_path("hive-task-closure-input")))

    assert_equal({ "const" => false }, input_schema.dig("properties", "applied").slice("const"))
    assert_equal false, preview.fetch("applied")
    assert_equal "preview", preview.fetch("mode")
    refute schemer.valid?(preview.merge("schema" => "hive-task-closure-result", "schema_version" => 1))
  end

  private

  def schemer
    @schemer ||= JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path(Hive::TaskClosureResult::SCHEMA)))
    )
  end
end
