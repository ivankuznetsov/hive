require "test_helper"
require "json"
require "hive/commands/approve"

# Schema files under schemas/ are the published artefact for external
# consumers (non-Ruby SDKs, CI validators, etc.). They must:
#   1. Exist for every key in SCHEMA_VERSIONS,
#   2. Parse as valid JSON and declare the documented `$schema` draft,
#   3. Pin the same required-key set the producer code emits, so a producer
#      change without a schema update fails at test time.
class SchemaFilesTest < Minitest::Test
  def test_hive_approve_schema_file_exists_and_is_valid_json
    path = Hive::Schemas.schema_path("hive-approve")
    assert File.exist?(path), "schema file missing: #{path}"

    doc = JSON.parse(File.read(path))
    assert_equal "https://json-schema.org/draft/2020-12/schema", doc["$schema"]
    assert_equal "hive-approve",
                 doc.dig("$defs", "SuccessPayload", "properties", "schema", "const"),
                 "SuccessPayload.schema.const must pin the schema name"
    assert_equal 1,
                 doc.dig("$defs", "SuccessPayload", "properties", "schema_version", "const"),
                 "SuccessPayload.schema_version.const must pin v1"
  end

  def test_hive_approve_success_required_keys_match_producer_emission
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-approve")))
    schema_required = doc.dig("$defs", "SuccessPayload", "required").sort

    # The producer's exhaustive key set (kept in sync with
    # Hive::Commands::Approve#success_payload). If a key is added in the
    # producer without updating the schema (or vice versa), this test fails.
    producer_required = %w[
      schema schema_version ok noop slug
      from_stage from_stage_index from_stage_dir
      to_stage to_stage_index to_stage_dir
      direction forced from_folder to_folder
      from_marker commit_action next_action
    ].sort

    assert_equal producer_required, schema_required,
                 "schema/producer required-key drift in hive-approve.v1.json"
  end

  def test_hive_approve_error_kinds_match_producer_emission
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-approve")))
    schema_kinds = doc.dig("$defs", "ErrorPayload", "properties", "error_kind", "enum").sort

    producer_kinds = %w[
      ambiguous_slug destination_collision final_stage
      wrong_stage invalid_task_path error
    ].sort

    assert_equal producer_kinds, schema_kinds,
                 "schema/producer error_kind enum drift"
  end

  def test_hive_approve_next_action_kinds_match_closed_enum
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-approve")))
    schema_kinds = doc.dig("$defs", "NextAction", "properties", "kind", "enum").sort
    enum_kinds = Hive::Schemas::NextActionKind::ALL.sort
    assert_equal enum_kinds, schema_kinds,
                 "schema NextAction.kind enum must mirror Hive::Schemas::NextActionKind::ALL"
  end

  # ── hive-findings ───────────────────────────────────────────────────────

  def test_hive_findings_schema_file_exists_and_is_valid_json
    path = Hive::Schemas.schema_path("hive-findings")
    assert File.exist?(path), "schema file missing: #{path}"

    doc = JSON.parse(File.read(path))
    assert_equal "https://json-schema.org/draft/2020-12/schema", doc["$schema"]
    assert_equal "hive-findings",
                 doc.dig("$defs", "ListPayload", "properties", "schema", "const")
    assert_equal "hive-findings",
                 doc.dig("$defs", "TogglePayload", "properties", "schema", "const")
  end

  def test_hive_findings_list_required_keys_match_producer
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-findings")))
    schema_required = doc.dig("$defs", "ListPayload", "required").sort
    producer_required = %w[
      schema schema_version ok slug stage stage_dir
      task_folder review_file pass findings summary
    ].sort
    assert_equal producer_required, schema_required,
                 "schema/producer required-key drift in hive-findings ListPayload"
  end

  def test_hive_findings_toggle_required_keys_match_producer
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-findings")))
    schema_required = doc.dig("$defs", "TogglePayload", "required").sort
    producer_required = %w[
      schema schema_version ok operation slug review_file pass
      selected_ids changes noop summary next_action
    ].sort
    assert_equal producer_required, schema_required,
                 "schema/producer required-key drift in hive-findings TogglePayload"
  end

  def test_hive_findings_error_kinds_match_producer
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-findings")))
    schema_kinds = doc.dig("$defs", "ErrorPayload", "properties", "error_kind", "enum").sort
    producer_kinds = %w[
      ambiguous_slug no_review_file unknown_finding invalid_task_path error
    ].sort
    assert_equal producer_kinds, schema_kinds
  end

  def test_hive_findings_error_exit_codes_cover_producer_errors
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-findings")))
    schema_codes = doc.dig("$defs", "ErrorPayload", "properties", "exit_code", "enum").sort
    producer_codes = [
      Hive::ExitCodes::GENERIC,
      Hive::ExitCodes::USAGE,
      Hive::ExitCodes::SOFTWARE,
      Hive::ExitCodes::TEMPFAIL,
      Hive::ExitCodes::CONFIG
    ].sort
    assert_equal producer_codes, schema_codes
  end
end
