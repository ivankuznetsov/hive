require "test_helper"
require "json"
require "hive/attempts/record_migration"

class AttemptsRecordMigrationTest < Minitest::Test
  NOW = Time.utc(2026, 8, 10, 12, 0, 0)

  def test_valid_v3_converts_once_to_a_v4_legacy_attempt_without_mutating_source
    source = v3_attempt
    before = JSON.parse(JSON.generate(source))

    converted = Hive::Attempts::RecordMigration.convert_v3(source)

    assert_equal before, source
    assert_equal 4, converted.fetch("schema_version")
    assert_equal({ "mode" => "legacy" }, converted.fetch("routing"))
    assert_equal converted, Hive::Attempts::Record.new(converted).to_h
    assert_equal converted,
                 Hive::Attempts::RecordMigration.current_or_convert(converted)
  end

  def test_invalid_or_raw_augmented_v3_documents_fail_closed
    malformed = v3_attempt.merge("stdout" => "secret-canary")
    wrong_version = v3_attempt.merge("schema_version" => 2)

    [ malformed, wrong_version, [ "not-an-attempt" ] ].each do |document|
      assert_raises(Hive::Attempts::InvalidRecord) do
        Hive::Attempts::RecordMigration.convert_v3(document)
      end
    end
  end

  def test_non_json_safe_recursive_input_is_rejected_before_schema_interpretation
    recursive = []
    recursive << recursive

    error = assert_raises(Hive::Attempts::InvalidRecord) do
      Hive::Attempts::RecordMigration.convert_v3(recursive)
    end
    assert_includes error.message, "not JSON-safe"
  end

  private

  def v3_attempt
    data = Hive::Attempts::Record.launching(
      attempt_id: "attempt-v3", request_id: "request-v3",
      predecessor_attempt_id: nil, task_id: "42", project: "demo",
      task_slug: "durable-task", intended_stage: "4-execute",
      task_generation: "task-generation-v3", progress_token: "progress-v3",
      provider: "codex", worker_argv: [ "hive", "run", "durable-task" ],
      claim_capability_digest: Hive::Attempts::Capability.digest("c" * 64),
      starting_revision: nil, retry_charge: 0, inherited_outputs: [],
      launch_timeout_sec: 30, now: NOW
    ).to_h
    data["schema_version"] = 3
    data.delete("routing")
    data
  end
end
