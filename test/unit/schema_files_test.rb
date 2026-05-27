require "test_helper"
require "json"
require "json_schemer"
require "hive/commands/approve"
require "hive/commands/daemon"
require "hive/commands/drop"
require "hive/commands/forget"
require "hive/commands/init"
require "hive/commands/prune"
require "hive/commands/run"
require "hive/commands/stage_action"
require "hive/commands/status"
require "hive/tui/snapshot"

# Schema files under schemas/ are the published artefact for external
# consumers (non-Ruby SDKs, CI validators, etc.). They must:
#   1. Exist for every key in SCHEMA_VERSIONS,
#   2. Parse as valid JSON and declare the documented `$schema` draft,
#   3. Pin the same required-key set the producer code emits, so a producer
#      change without a schema update fails at test time.
class SchemaFilesTest < Minitest::Test
  def test_hive_approve_v2_schema_file_exists_and_is_valid_json
    path = Hive::Schemas.schema_path("hive-approve")
    assert File.exist?(path), "schema file missing: #{path}"

    doc = JSON.parse(File.read(path))
    assert_equal "https://json-schema.org/draft/2020-12/schema", doc["$schema"]
    assert_equal "hive-approve",
                 doc.dig("$defs", "SuccessPayload", "properties", "schema", "const"),
                 "SuccessPayload.schema.const must pin the schema name"
    assert_equal 2,
                 doc.dig("$defs", "SuccessPayload", "properties", "schema_version", "const"),
                 "SuccessPayload.schema_version.const must pin v2 (current)"
  end

  # v1 (the original 6-stage schema) is preserved for external validators
  # pinned to the pre-6-review release. Loading by explicit version: must
  # still resolve.
  def test_hive_approve_v1_schema_file_remains_for_back_compat
    path = Hive::Schemas.schema_path("hive-approve", version: 1)
    assert File.exist?(path), "v1 schema file missing: #{path}"

    doc = JSON.parse(File.read(path))
    assert_equal 1,
                 doc.dig("$defs", "SuccessPayload", "properties", "schema_version", "const"),
                 "v1 schema must still declare schema_version: 1"
    # The original v1 enum had no `review` and ended at `6-done`.
    v1_dirs = doc.dig("$defs", "SuccessPayload", "properties", "from_stage_dir", "enum")
    assert_includes v1_dirs, "5-pr",
                    "v1 must keep its original enum (5-pr / 6-done) for pinned consumers"
    refute_includes v1_dirs, "6-review",
                    "v1 enum must NOT include the v2-introduced 6-review stage"
  end

  def test_hive_approve_v2_includes_current_stage_dirs
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-approve")))
    v2_dirs = doc.dig("$defs", "SuccessPayload", "properties", "from_stage_dir", "enum")
    assert_includes v2_dirs, "5-open-pr"
    assert_includes v2_dirs, "6-review"
    assert_includes v2_dirs, "7-artifacts",
                    "v2 widens the enum to include 7-artifacts (plan U1; ADR-029)"
    assert_includes v2_dirs, "8-finalize"
    assert_includes v2_dirs, "9-done"
    refute_includes v2_dirs, "5-pr", "v2 retires the legacy 5-pr enum value"
    refute_includes v2_dirs, "7-finalize",
                    "v2 retires the pre-renumber 7-finalize enum value"
    refute_includes v2_dirs, "8-done",
                    "v2 retires the pre-renumber 8-done enum value"
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
                 "schema/producer required-key drift in hive-approve.v2.json"
  end

  def test_hive_approve_error_kinds_match_producer_emission
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-approve")))
    schema_kinds = doc.dig("$defs", "ErrorPayload", "properties", "error_kind", "enum").sort

    producer_kinds = %w[
      ambiguous_slug destination_collision final_stage
      wrong_stage rollback_failed invalid_task_path error
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

  # ── hive-status ────────────────────────────────────────────────────────

  def test_hive_status_schema_file_exists_and_is_valid_json
    path = Hive::Schemas.schema_path("hive-status")
    assert File.exist?(path), "schema file missing: #{path}"

    doc = JSON.parse(File.read(path))
    assert_equal "https://json-schema.org/draft/2020-12/schema", doc["$schema"]
    assert_equal "hive-status",
                 doc.dig("$defs", "SuccessPayload", "properties", "schema", "const")
    assert_equal 2,
                 doc.dig("$defs", "SuccessPayload", "properties", "schema_version", "const")
  end

  def test_hive_status_v1_schema_remains_for_back_compat
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-status", version: 1)))
    assert_equal 1, doc.dig("$defs", "SuccessPayload", "properties", "schema_version", "const")
    assert_includes doc.dig("$defs", "Task", "properties", "stage", "enum"), "6-pr"
    assert_includes doc.dig("$defs", "Task", "properties", "action", "enum"), "ready_for_pr"
  end

  def test_hive_status_required_keys_match_producer_emission
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-status")))
    schema_required = doc.dig("$defs", "SuccessPayload", "required").sort
    assert_equal %w[generated_at ok projects schema schema_version].sort, schema_required

    row = {
      stage: "1-inbox",
      slug: "probe",
      folder: "/tmp/probe",
      state_file: "/tmp/probe/idea.md",
      marker_name: :waiting,
      marker_attrs: {},
      mtime: Time.now,
      claude_pid: nil,
      claude_pid_alive: nil,
      action_key: Hive::Schemas::TaskActionKind::READY_TO_BRAINSTORM,
      action_label: "Ready to brainstorm",
      suggested_command: "hive brainstorm probe --from 1-inbox",
      diagnostic: nil
    }
    producer_keys = Hive::Commands::Status.new.task_payload(row).keys.sort
    schema_task_required = doc.dig("$defs", "Task", "required").sort
    assert_equal producer_keys, schema_task_required,
                 "schema/producer required-key drift in hive-status Task"
  end

  def test_hive_status_task_enums_match_closed_sets
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-status")))

    assert_equal Hive::Stages::DIRS.sort,
                 doc.dig("$defs", "Task", "properties", "stage", "enum").sort
    assert_equal Hive::Commands::Status::ICON.keys.map(&:to_s).sort,
                 doc.dig("$defs", "Task", "properties", "marker", "enum").sort
    assert_equal Hive::Schemas::TaskActionKind::ALL.sort,
                 doc.dig("$defs", "Task", "properties", "action", "enum").sort
  end

  def test_hive_status_schema_matches_tui_snapshot_row_keys
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-status")))
    schema_properties = doc.dig("$defs", "Task", "properties").keys
    snapshot_row_keys = Hive::Tui::Snapshot::Row.members.map(&:to_s) - [ "project_name" ]
    snapshot_row_keys = snapshot_row_keys.map { |key| key == "action_key" ? "action" : key }

    assert_empty snapshot_row_keys - schema_properties,
                 "Snapshot::Row must not consume fields absent from hive-status schema"
  end

  # ErrorPayload arm: the schema's error_kind enum must mirror StatusErrorKind::ALL.
  def test_hive_status_error_kinds_match_closed_enum
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-status")))
    schema_kinds = doc.dig("$defs", "ErrorPayload", "properties", "error_kind", "enum").sort
    assert_equal Hive::Schemas::StatusErrorKind::ALL.sort, schema_kinds,
                 "schema ErrorPayload.error_kind enum must mirror Hive::Schemas::StatusErrorKind::ALL"
  end

  # Round-trip: every kind in StatusErrorKind::ALL must validate.
  def test_hive_status_error_payload_validates_for_every_kind
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-status"))))
    error = Hive::ConfigError.new("HIVE_HOME unreadable")
    Hive::Schemas::StatusErrorKind::ALL.each do |kind|
      payload = Hive::Schemas::ErrorEnvelope.build(
        schema: "hive-status",
        error: error,
        error_kind: kind
      )
      assert schemer.valid?(payload),
             "hive-status ErrorPayload arm must accept error_kind=#{kind.inspect} (validation errors: #{schemer.validate(payload).map { |e| e['error'] }.inspect})"
    end
  end

  # Negative-case: out-of-enum kind must be rejected.
  def test_hive_status_error_payload_rejects_unknown_kind
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-status"))))
    payload = {
      "schema" => "hive-status",
      "schema_version" => 1,
      "ok" => false,
      "error_class" => "MysteryError",
      "error_kind" => "made_up_kind",
      "exit_code" => 1,
      "message" => "nope"
    }
    refute schemer.valid?(payload),
           "schema must reject error_kind values outside StatusErrorKind::ALL"
  end

  # Round-trip: a SuccessPayload with `legacy_stage_dirs` populated must
  # validate against the published schema. Without this, an additive
  # field could land in the producer (Hive::Commands::Status#project_payload)
  # without the schema declaring it — and `additionalProperties: false`
  # on the Project def would reject the payload at runtime for external
  # consumers (TUI, daemon, bots).
  def test_hive_status_success_payload_with_legacy_stage_dirs_validates_against_published_schema
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-status"))))
    payload = {
      "schema" => "hive-status",
      "schema_version" => 2,
      "ok" => true,
      "generated_at" => "2026-05-19T00:00:00Z",
      "projects" => [
        {
          "name" => "alpha",
          "path" => "/tmp/alpha",
          "hive_state_path" => "/tmp/alpha/.hive-state",
          "tasks" => [],
          "legacy_stage_dirs" => [
            { "stage_dir" => "5-review", "task_count" => 2 },
            { "stage_dir" => "6-pr",     "task_count" => 1 }
          ],
          # Machine-readable recovery hint; siblings legacy_stage_dirs.
          # Issue #94.
          "legacy_migrate_command" => "hive migrate"
        },
        {
          # Clean project: explicit empty array still validates, and
          # legacy_migrate_command is explicitly null.
          "name" => "beta",
          "path" => "/tmp/beta",
          "hive_state_path" => "/tmp/beta/.hive-state",
          "tasks" => [],
          "legacy_stage_dirs" => [],
          "legacy_migrate_command" => nil
        }
      ]
    }
    errors = schemer.validate(payload).map { |e| e["error"] }
    assert_empty errors,
                 "hive-status SuccessPayload with legacy_stage_dirs must validate " \
                 "(errors: #{errors.inspect})"
  end

  # `legacy_migrate_command` accepts either "hive migrate" (when
  # legacy_stage_dirs is non-empty) or `null` (when clean); any other
  # JSON type (e.g. a boolean or a number) must be rejected. Issue #94.
  def test_hive_status_legacy_migrate_command_rejects_non_string_non_null
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-status"))))
    payload = {
      "schema" => "hive-status",
      "schema_version" => 2,
      "ok" => true,
      "generated_at" => "2026-05-19T00:00:00Z",
      "projects" => [
        {
          "name" => "alpha",
          "path" => "/tmp/alpha",
          "hive_state_path" => "/tmp/alpha/.hive-state",
          "tasks" => [],
          "legacy_stage_dirs" => [],
          "legacy_migrate_command" => false # not a string and not null
        }
      ]
    }
    refute schemer.valid?(payload),
           "legacy_migrate_command must reject values that aren't string-or-null"
  end

  # Negative case: a legacy_stage_dirs entry missing `stage_dir` or with
  # `task_count` below the schema minimum must be rejected — pins
  # additionalProperties: false on the entry shape.
  def test_hive_status_legacy_stage_dirs_entry_shape_is_enforced
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-status"))))
    base = {
      "schema" => "hive-status",
      "schema_version" => 2,
      "ok" => true,
      "generated_at" => "2026-05-19T00:00:00Z",
      "projects" => [
        {
          "name" => "alpha",
          "path" => "/tmp/alpha",
          "hive_state_path" => "/tmp/alpha/.hive-state",
          "tasks" => [],
          "legacy_stage_dirs" => [ { "stage_dir" => "6-pr" } ] # missing task_count
        }
      ]
    }
    refute schemer.valid?(base),
           "legacy_stage_dirs entry without task_count must be rejected"
  end

  # ── hive-status-diagnose ───────────────────────────────────────────────

  def test_hive_status_diagnose_schema_file_exists_and_is_valid_json
    path = Hive::Schemas.schema_path("hive-status-diagnose")
    assert File.exist?(path), "schema file missing: #{path}"

    doc = JSON.parse(File.read(path))
    assert_equal "https://json-schema.org/draft/2020-12/schema", doc["$schema"]
    assert_equal "hive-status-diagnose",
                 doc.dig("$defs", "SuccessPayload", "properties", "schema", "const")
    assert_equal 1,
                 doc.dig("$defs", "SuccessPayload", "properties", "schema_version", "const")
  end

  def test_hive_status_diagnose_schema_is_self_contained_for_jsonschemer
    # The schema must validate without an external ref registry —
    # JSONSchemer raises UnknownRef on `urn:` refs unless callers pre-
    # register the referenced schema, which agent consumers and CI
    # validators don't. Pinning this guards against a future edit
    # reintroducing the cross-schema $ref that broke validation in
    # PR #84's first push.
    schemer = JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-status-diagnose")))
    )
    # Minimal-but-real success payload with a Diagnostic block; if any
    # ref doesn't resolve inside the file, schemer.validate raises.
    payload = {
      "schema" => "hive-status-diagnose",
      "schema_version" => 1,
      "ok" => true,
      "slug" => "probe",
      "task_folder" => "/tmp/probe",
      "path" => nil,
      "diagnostic" => {
        "summary" => "REVIEW_ERROR phase=fix pass=1",
        "detail" => "fix failed",
        "source" => "marker",
        "source_path" => nil,
        "artifact_paths" => [],
        "generated_by" => "local",
        "marker_signature" => Digest::SHA256.hexdigest("review_error\npass=1\nphase=fix"),
        "suggested_next_action" => {
          "kind" => "retry",
          "command" => "hive markers clear /tmp/probe --name REVIEW_ERROR --match-attr pass=1 && hive run /tmp/probe"
        },
        "updated_at" => "2026-05-16T00:00:00Z"
      }
    }
    errors = schemer.validate(payload).map { |e| e["error"] }
    assert_empty errors,
                 "hive-status-diagnose success payload must validate without external refs"
  end

  def test_hive_status_diagnose_accepts_null_diagnostic_for_non_red_rows
    schemer = JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-status-diagnose")))
    )
    payload = {
      "schema" => "hive-status-diagnose",
      "schema_version" => 1,
      "ok" => true,
      "slug" => "probe",
      "task_folder" => "/tmp/probe",
      "diagnostic" => nil,
      "path" => nil
    }
    assert schemer.valid?(payload),
           "non-red --diagnose target must validate with diagnostic: null " \
           "(errors: #{schemer.validate(payload).map { |e| e['error'] }.inspect})"
  end

  def test_hive_status_diagnose_error_envelope_validates
    schemer = JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-status-diagnose")))
    )
    error = Hive::AmbiguousSlug.new(
      "ambig", slug: "probe",
      candidates: [ { project: "alpha", stage: "6-review", folder: "/tmp/alpha/probe" } ]
    )
    payload = Hive::Schemas::ErrorEnvelope.build(
      schema: "hive-status-diagnose",
      error: error,
      error_kind: Hive::Schemas::StatusErrorKind::ERROR
    )
    errors = schemer.validate(payload).map { |e| e["error"] }
    assert_empty errors, "diagnose error envelope must validate (errors: #{errors.inspect})"
  end

  # Diagnose-specific error_kind enum: must mirror StatusDiagnoseErrorKind::ALL.
  # Adding a kind to the producer (Hive::Commands::Status#diagnose_error_kind_for)
  # without updating the schema fails here. See PR #84 review row 4.
  def test_hive_status_diagnose_error_kinds_match_closed_enum
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-status-diagnose")))
    schema_kinds = doc.dig("$defs", "ErrorPayload", "properties", "error_kind", "enum").sort
    assert_equal Hive::Schemas::StatusDiagnoseErrorKind::ALL.sort, schema_kinds,
                 "schema ErrorPayload.error_kind enum must mirror " \
                 "Hive::Schemas::StatusDiagnoseErrorKind::ALL"
  end

  def test_hive_status_diagnose_error_payload_validates_for_every_kind
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-status-diagnose"))))
    require "hive/diagnosis_agent"
    error = Hive::ConfigError.new("HIVE_HOME unreadable")
    Hive::Schemas::StatusDiagnoseErrorKind::ALL.each do |kind|
      payload = Hive::Schemas::ErrorEnvelope.build(
        schema: "hive-status-diagnose",
        error: error,
        error_kind: kind
      )
      assert schemer.valid?(payload),
             "hive-status-diagnose ErrorPayload arm must accept error_kind=#{kind.inspect} " \
             "(validation errors: #{schemer.validate(payload).map { |e| e['error'] }.inspect})"
    end
  end

  # Producer-driven dispatch check for the four diagnose-specific kinds.
  # Without this, a contributor could add a constant + schema enum value
  # and never wire it into `Hive::Commands::Status#diagnose_error_kind_for`,
  # silently dropping it from the dispatch path. See PR #84 review row 4.
  def test_hive_status_diagnose_dispatch_routes_every_kind
    require "hive/diagnosis_agent"
    representatives = {
      Hive::Schemas::StatusDiagnoseErrorKind::STALE_MARKER =>
        Hive::DiagnosisAgent::StaleMarker.new("marker rotated"),
      Hive::Schemas::StatusDiagnoseErrorKind::IN_FLIGHT =>
        Hive::DiagnosisAgent::DiagnosisInFlight.new("lock held"),
      Hive::Schemas::StatusDiagnoseErrorKind::AMBIGUOUS_SLUG =>
        Hive::AmbiguousSlug.new("ambig", slug: "p",
                                candidates: [ { project: "a", stage: "6-review", folder: "/x" } ]),
      Hive::Schemas::StatusDiagnoseErrorKind::SLUG_NOT_FOUND =>
        Hive::InvalidTaskPath.new("no such slug"),
      Hive::Schemas::StatusDiagnoseErrorKind::CONFIG => Hive::ConfigError.new("bad config"),
      Hive::Schemas::StatusDiagnoseErrorKind::INTERNAL => Hive::InternalError.new("boom"),
      Hive::Schemas::StatusDiagnoseErrorKind::ERROR => Hive::Error.new("plain")
    }
    missing = Hive::Schemas::StatusDiagnoseErrorKind::ALL - representatives.keys
    assert_empty missing,
                 "every StatusDiagnoseErrorKind value must have a representative exception " \
                 "(missing: #{missing.inspect})"
    status = Hive::Commands::Status.new(diagnose: "any", json: true)
    representatives.each do |expected_kind, exception|
      actual = status.send(:diagnose_error_kind_for, exception)
      assert_equal expected_kind, actual,
                   "Status#diagnose_error_kind_for(#{exception.class}) must return " \
                   "#{expected_kind.inspect}, got #{actual.inspect}"
    end
  end

  # Cross-schema Diagnostic equivalence: the Diagnostic block is inlined
  # in BOTH hive-status.v2.json (the per-task tasks[].diagnostic field)
  # and hive-status-diagnose.v1.json (the --diagnose envelope's
  # diagnostic field). They must agree on required keys, property types,
  # enum values, patterns, and maxItems — descriptions may differ. A
  # contributor changing one without the other silently breaks consumers
  # that switch between the two envelopes. See PR #84 review row 17.
  def test_diagnostic_definition_is_equivalent_across_status_schemas
    v2 = JSON.parse(File.read(Hive::Schemas.schema_path("hive-status")))
    diag = JSON.parse(File.read(Hive::Schemas.schema_path("hive-status-diagnose")))

    v2_diagnostic = v2.dig("$defs", "Diagnostic")
    diag_diagnostic = diag.dig("$defs", "Diagnostic")
    refute_nil v2_diagnostic, "hive-status.v2 must define $defs.Diagnostic"
    refute_nil diag_diagnostic, "hive-status-diagnose must define $defs.Diagnostic"

    # Pinned property names AND required-key sets agree.
    assert_equal v2_diagnostic["required"].sort,
                 diag_diagnostic["required"].sort,
                 "Diagnostic.required must be identical across schemas"
    assert_equal v2_diagnostic["properties"].keys.sort,
                 diag_diagnostic["properties"].keys.sort,
                 "Diagnostic property keys must be identical across schemas"

    # For each property, compare type/enum/pattern/maxItems/maxLength;
    # ignore descriptions (purely documentation). Skip nil-vs-nil
    # comparisons via `assert` on equality so minitest doesn't suggest
    # assert_nil for absent shared keys.
    v2_diagnostic["properties"].each do |key, v2_prop|
      diag_prop = diag_diagnostic["properties"][key]
      %w[type enum pattern maxItems maxLength].each do |attr|
        assert v2_prop[attr] == diag_prop[attr],
               "Diagnostic.#{key}.#{attr} must be identical across schemas " \
               "(v2=#{v2_prop[attr].inspect}, diagnose=#{diag_prop[attr].inspect})"
      end
    end
  end

  # generated_by enum coverage: both schemas declare the same closed
  # Diagnostic.generated_by enum as Hive::Schemas::DIAGNOSTIC_GENERATORS.
  # Custom AgentProfiles are a runtime extension point, but generated_by
  # is a published wire contract and must not expand implicitly.
  def test_hive_status_v2_generated_by_enum_matches_schema_constant
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-status")))
    schema_enum = doc.dig("$defs", "Diagnostic", "properties", "generated_by", "enum").sort
    expected = Hive::Schemas::DIAGNOSTIC_GENERATORS.sort
    assert_equal expected, schema_enum,
                 "hive-status.v2 Diagnostic.generated_by enum must equal " \
                 "Hive::Schemas::DIAGNOSTIC_GENERATORS"
  end

  def test_hive_status_diagnose_generated_by_enum_matches_schema_constant
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-status-diagnose")))
    schema_enum = doc.dig("$defs", "Diagnostic", "properties", "generated_by", "enum").sort
    expected = Hive::Schemas::DIAGNOSTIC_GENERATORS.sort
    assert_equal expected, schema_enum,
                 "hive-status-diagnose.v1 Diagnostic.generated_by enum must equal " \
                 "Hive::Schemas::DIAGNOSTIC_GENERATORS"
  end

  # ── hive-run ───────────────────────────────────────────────────────────

  def test_hive_run_schema_file_exists_and_is_valid_json
    path = Hive::Schemas.schema_path("hive-run")
    assert File.exist?(path), "schema file missing: #{path}"

    doc = JSON.parse(File.read(path))
    assert_equal "https://json-schema.org/draft/2020-12/schema", doc["$schema"]
    assert_equal "hive-run",
                 doc.dig("$defs", "SuccessPayload", "properties", "schema", "const")
    assert_equal 2,
                 doc.dig("$defs", "SuccessPayload", "properties", "schema_version", "const")
  end

  def test_hive_run_v1_schema_remains_for_back_compat
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-run", version: 1)))
    assert_equal 1, doc.dig("$defs", "SuccessPayload", "properties", "schema_version", "const")
    assert_includes doc.dig("$defs", "SuccessPayload", "required"), "rebase"
    assert_includes doc.dig("$defs", "SuccessPayload", "properties", "stage", "enum"), "pr"
  end

  def test_hive_run_required_keys_match_producer_emission
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-run")))
    schema_required = doc.dig("$defs", "SuccessPayload", "required").sort
    # Derive directly from the producer constant so a drift between the
    # emitted hash and the schema can only happen in one place. The
    # constant is the same list `Hive::Commands::Run#report_json` consults
    # to build the JSON envelope (see lib/hive/commands/run.rb).
    producer_required = Hive::Commands::Run::REQUIRED_PAYLOAD_KEYS.sort

    assert_equal producer_required, schema_required,
                 "schema/producer required-key drift in current hive-run schema"
  end

  # OPTIONAL_PAYLOAD_KEYS documents fields that are valid in SuccessPayload
  # but only emitted conditionally (currently `cleanup_instructions`).
  # Without this disjointness check, a contributor could move a key from
  # required to optional without removing it from the required list, or
  # vice versa, and silently break the schema contract.
  def test_hive_run_optional_payload_keys_are_disjoint_from_required
    overlap = Hive::Commands::Run::OPTIONAL_PAYLOAD_KEYS &
              Hive::Commands::Run::REQUIRED_PAYLOAD_KEYS
    assert_empty overlap,
                 "OPTIONAL_PAYLOAD_KEYS and REQUIRED_PAYLOAD_KEYS must be disjoint " \
                 "(overlap: #{overlap.inspect})"
  end

  # The schema must declare every OPTIONAL_PAYLOAD_KEYS field as a property
  # on SuccessPayload (so additionalProperties: false doesn't reject it).
  def test_hive_run_optional_payload_keys_appear_in_schema_properties
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-run")))
    schema_properties = doc.dig("$defs", "SuccessPayload", "properties").keys
    Hive::Commands::Run::OPTIONAL_PAYLOAD_KEYS.each do |key|
      assert_includes schema_properties, key,
                      "OPTIONAL_PAYLOAD_KEYS includes #{key.inspect} but the schema does not " \
                      "declare it as a SuccessPayload property — additionalProperties: false would reject it"
    end
  end

  def test_hive_run_next_action_kinds_match_closed_enum
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-run")))
    schema_kinds = doc.dig("$defs", "SuccessPayload", "properties", "next_action", "properties", "kind", "enum").sort
    assert_equal Hive::Schemas::NextActionKind::ALL.sort, schema_kinds
  end

  # ErrorPayload arm: the schema's error_kind enum must mirror RunErrorKind::ALL.
  # Adding a new kind in lib/hive.rb without updating the schema fails here.
  def test_hive_run_error_kinds_match_closed_enum
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-run")))
    schema_kinds = doc.dig("$defs", "ErrorPayload", "properties", "error_kind", "enum").sort
    assert_equal Hive::Schemas::RunErrorKind::ALL.sort, schema_kinds,
                 "schema ErrorPayload.error_kind enum must mirror Hive::Schemas::RunErrorKind::ALL"
  end

  # Round-trip: every kind in RunErrorKind::ALL must produce a payload that
  # validates against the schema. Drives the producer-driven idiom — a schema
  # that drifts from the envelope shape fails here.
  def test_hive_run_error_payload_validates_for_every_kind
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-run"))))
    error = Hive::ConcurrentRunError.new("stale lock detected")
    Hive::Schemas::RunErrorKind::ALL.each do |kind|
      payload = Hive::Schemas::ErrorEnvelope.build(
        schema: "hive-run",
        error: error,
        error_kind: kind,
        extras: { "slug" => "probe", "stage_filter" => "execute" }
      )
      assert schemer.valid?(payload),
             "hive-run ErrorPayload arm must accept error_kind=#{kind.inspect} (validation errors: #{schemer.validate(payload).map { |e| e['error'] }.inspect})"
    end
  end

  # Producer-routed drift check: every RunErrorKind value MUST be reachable
  # via `Hive::Commands::Run#error_kind_for(<representative-exception>)` AND
  # round-trip through the schema. Without this, a contributor could add a
  # constant to RunErrorKind + schema enum, never wire it into the dispatch,
  # and the round-trip test above would still pass — silent dispatch drift.
  def test_run_error_kind_for_routes_every_kind_through_dispatch
    require "hive/commands/run"
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-run"))))
    representatives = {
      Hive::Schemas::RunErrorKind::CONCURRENT_RUN    => Hive::ConcurrentRunError.new("lock contention"),
      Hive::Schemas::RunErrorKind::TASK_IN_ERROR     => Hive::TaskInErrorState.new("error marker"),
      Hive::Schemas::RunErrorKind::WRONG_STAGE       => Hive::WrongStage.new("wrong stage"),
      Hive::Schemas::RunErrorKind::STAGE             => Hive::StageError.new("stage failed"),
      Hive::Schemas::RunErrorKind::CONFIG            => Hive::ConfigError.new("config bad"),
      Hive::Schemas::RunErrorKind::AGENT             => Hive::AgentError.new("agent died"),
      Hive::Schemas::RunErrorKind::GIT               => Hive::GitError.new("git push failed"),
      Hive::Schemas::RunErrorKind::WORKTREE          => Hive::WorktreeError.new("worktree busy"),
      Hive::Schemas::RunErrorKind::AMBIGUOUS_SLUG    => Hive::AmbiguousSlug.new(
        "ambig", slug: "probe",
        candidates: [ { project: "alpha", stage: "2-brainstorm", folder: "/tmp/probe" } ]
      ),
      Hive::Schemas::RunErrorKind::INVALID_TASK_PATH => Hive::InvalidTaskPath.new("no such slug"),
      Hive::Schemas::RunErrorKind::INTERNAL          => Hive::InternalError.new("internal bug"),
      Hive::Schemas::RunErrorKind::ERROR             => Hive::Error.new("plain")
    }
    missing = Hive::Schemas::RunErrorKind::ALL - representatives.keys
    assert_empty missing,
                 "every RunErrorKind value must have a representative exception in this test " \
                 "(missing: #{missing.inspect}); without one a future kind can be added without dispatch wiring"
    run = Hive::Commands::Run.new("/tmp/dummy")
    representatives.each do |expected_kind, exception|
      actual_kind = run.send(:error_kind_for, exception)
      assert_equal expected_kind, actual_kind,
                   "Run#error_kind_for(#{exception.class}) must return #{expected_kind.inspect}, got #{actual_kind.inspect}"
      payload = Hive::Schemas::ErrorEnvelope.build(
        schema: "hive-run",
        error: exception,
        error_kind: actual_kind,
        extras: { "slug" => "probe", "stage_filter" => nil }.compact
      )
      assert schemer.valid?(payload),
             "round-trip envelope for #{exception.class} (kind=#{actual_kind}) must validate " \
             "(errors: #{schemer.validate(payload).map { |e| e['error'] }.inspect})"
    end
  end

  # Negative-case: a payload whose error_kind is not in the closed enum must
  # be rejected. Without this, a typo in the producer or schema can slip
  # through the round-trip test above.
  def test_hive_run_error_payload_rejects_unknown_kind
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-run"))))
    payload = {
      "schema" => "hive-run",
      "schema_version" => 1,
      "ok" => false,
      "error_class" => "MysteryError",
      "error_kind" => "made_up_kind",
      "exit_code" => 1,
      "message" => "nope"
    }
    refute schemer.valid?(payload),
           "schema must reject error_kind values outside RunErrorKind::ALL"
  end

  # AmbiguousSlug auto-extras `candidates` — the round-trip must still pass.
  # Candidates use the production shape: Array<{project:, stage:, folder:}> per
  # Hive::TaskResolver#find_slug_across_projects, not String array.
  def test_hive_run_error_payload_with_ambiguous_slug_candidates_validates
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-run"))))
    candidates = [
      { project: "alpha", stage: "2-brainstorm", folder: "/tmp/alpha/stages/2-brainstorm/probe" },
      { project: "beta",  stage: "3-plan",       folder: "/tmp/beta/stages/3-plan/probe" }
    ]
    error = Hive::AmbiguousSlug.new("ambiguous", slug: "probe", candidates: candidates)
    payload = Hive::Schemas::ErrorEnvelope.build(
      schema: "hive-run",
      error: error,
      error_kind: Hive::Schemas::RunErrorKind::AMBIGUOUS_SLUG,
      extras: { "slug" => "probe" }
    )
    assert schemer.valid?(payload),
           "hive-run ErrorPayload must accept the AmbiguousSlug envelope shape (errors: #{schemer.validate(payload).map { |e| e['error'] }.inspect})"
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
      ambiguous_slug no_review_file unknown_finding no_selection
      rollback_failed invalid_task_path error
    ].sort
    assert_equal producer_kinds, schema_kinds
  end

  def test_hive_findings_candidates_item_shape_pinned
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-findings")))
    candidates = doc.dig("$defs", "ErrorPayload", "properties", "candidates")
    item_required = candidates.dig("items", "required").sort
    assert_equal %w[folder project stage], item_required,
                 "candidate items must require project/stage/folder, mirroring hive-approve.v1"
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

  # ── hive-stage-action ───────────────────────────────────────────────────

  def test_hive_stage_action_schema_file_exists_and_is_valid_json
    path = Hive::Schemas.schema_path("hive-stage-action")
    assert File.exist?(path), "schema file missing: #{path}"

    doc = JSON.parse(File.read(path))
    assert_equal "https://json-schema.org/draft/2020-12/schema", doc["$schema"]
    assert_equal "hive-stage-action",
                 doc.dig("$defs", "SuccessPayload", "properties", "schema", "const")
    assert_equal 2,
                 doc.dig("$defs", "SuccessPayload", "properties", "schema_version", "const")
  end

  def test_hive_stage_action_v1_schema_remains_for_back_compat
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-stage-action", version: 1)))
    assert_equal 1, doc.dig("$defs", "SuccessPayload", "properties", "schema_version", "const")
    assert_includes doc.dig("$defs", "SuccessPayload", "properties", "verb", "enum"), "pr"
    assert_includes doc.dig("$defs", "NextAction", "properties", "key", "enum"), "ready_for_pr"
  end

  def test_hive_stage_action_success_required_keys_match_producer
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-stage-action")))
    schema_required = doc.dig("$defs", "SuccessPayload", "required").sort
    producer_required = %w[
      schema schema_version ok verb phase noop slug
      from_stage_dir to_stage_dir task_folder marker_after next_action
    ].sort
    assert_equal producer_required, schema_required,
                 "schema/producer required-key drift in hive-stage-action SuccessPayload"
  end

  def test_hive_stage_action_phase_enum_pinned
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-stage-action")))
    schema_phases = doc.dig("$defs", "SuccessPayload", "properties", "phase", "enum").sort
    producer_phases = %w[promoted_and_ran ran noop].sort
    assert_equal producer_phases, schema_phases
  end

  def test_hive_stage_action_verb_enum_matches_workflows
    require "hive/workflows"
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-stage-action")))
    schema_verbs = doc.dig("$defs", "SuccessPayload", "properties", "verb", "enum").sort
    workflow_verbs = Hive::Workflows::VERBS.keys.sort
    assert_equal workflow_verbs, schema_verbs,
                 "schema/Workflows verb-enum drift"
  end

  def test_hive_stage_action_next_action_key_enum_matches_task_action_kind
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-stage-action")))
    schema_keys = doc.dig("$defs", "NextAction", "properties", "key", "enum").sort
    enum_keys = Hive::Schemas::TaskActionKind::ALL.sort
    assert_equal enum_keys, schema_keys,
                 "schema NextAction.key enum must mirror Hive::Schemas::TaskActionKind::ALL"
  end

  def test_hive_stage_action_wrong_stage_error_payload_validates
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-stage-action"))))
    error = Hive::WrongStage.new("wrong stage", current_stage: "1-inbox", target_stage: "2-brainstorm")
    payload = Hive::Schemas::ErrorEnvelope.build(
      schema: "hive-stage-action",
      error: error,
      error_kind: "wrong_stage",
      extras: { "verb" => "brainstorm" }
    )

    assert schemer.valid?(payload),
           "hive-stage-action ErrorPayload must accept WrongStage extras (errors: #{schemer.validate(payload).map { |e| e['error'] }.inspect})"
  end

  def test_shared_lock_error_extras_validate_for_stage_action_and_findings
    error = Hive::ConcurrentRunError.new(
      "lock held",
      holder: { "pid" => 123, "slug" => "task", "stage" => "4-execute" },
      lock_path: "/tmp/task.lock"
    )
    {
      "hive-stage-action" => { "verb" => "develop" },
      "hive-findings" => { "operation" => "accept" }
    }.each do |schema, extras|
      schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path(schema))))
      payload = Hive::Schemas::ErrorEnvelope.build(
        schema: schema,
        error: error,
        error_kind: "error",
        extras: extras
      )
      assert schemer.valid?(payload),
             "#{schema} ErrorPayload must accept shared lock extras (errors: #{schemer.validate(payload).map { |e| e['error'] }.inspect})"
    end
  end

  # ── hive-metrics-rollback-rate ─────────────────────────────────────────

  def test_hive_metrics_rollback_rate_schema_file_exists_and_is_valid_json
    path = Hive::Schemas.schema_path("hive-metrics-rollback-rate")
    assert File.exist?(path), "schema file missing: #{path}"

    doc = JSON.parse(File.read(path))
    assert_equal "https://json-schema.org/draft/2020-12/schema", doc["$schema"]
    assert_equal "hive-metrics-rollback-rate",
                 doc.dig("$defs", "SuccessPayload", "properties", "schema", "const"),
                 "SuccessPayload.schema.const must pin the schema name"
    assert_equal 1,
                 doc.dig("$defs", "SuccessPayload", "properties", "schema_version", "const"),
                 "SuccessPayload.schema_version.const must pin v1"
  end

  def test_hive_metrics_rollback_rate_required_keys_match_producer_emission
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-metrics-rollback-rate")))
    success_required = doc.dig("$defs", "SuccessPayload", "required").sort

    assert_equal %w[projects schema schema_version since].sort, success_required,
                 "schema/producer required-key drift in hive-metrics-rollback-rate.v1.json (envelope)"

    project_required = doc.dig("$defs", "Project", "required").sort
    assert_equal %w[
      by_bias by_phase project project_root reverted_commits rollback_rate total_fix_commits
    ].sort, project_required,
                 "schema/producer required-key drift in hive-metrics-rollback-rate.v1.json (project)"
  end

  # ── hive-init ──────────────────────────────────────────────────────────

  def test_hive_init_schema_file_exists_and_is_valid_json
    path = Hive::Schemas.schema_path("hive-init")
    assert File.exist?(path), "schema file missing: #{path}"

    doc = JSON.parse(File.read(path))
    assert_equal "https://json-schema.org/draft/2020-12/schema", doc["$schema"]
    assert_equal "hive-init",
                 doc.dig("$defs", "SuccessPayload", "properties", "schema", "const")
    assert_equal 1,
                 doc.dig("$defs", "SuccessPayload", "properties", "schema_version", "const")
  end

  def test_hive_init_required_keys_match_producer_emission
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-init")))
    schema_required = doc.dig("$defs", "SuccessPayload", "required").sort
    expected = %w[
      answers budgets claude_mode daemon_autostart_requested daemon_enabled default_branch
      development_agent enabled_reviewers hive_state_path ok path planning_agent
      project schema schema_version timeouts triage_bias worktree_root
    ].sort
    assert_equal expected, schema_required,
                 "schema/producer required-key drift in hive-init.v1.json"

    ops = Struct.new(:default_branch, :hive_state_path).new("main", "/tmp/demo/.hive-state")
    entry = { "name" => "demo", "path" => "/tmp/demo", "hive_state_path" => "/tmp/demo/.hive-state" }
    answers = Hive::Commands::Init::Prompts.new(input: StringIO.new, summary_io: StringIO.new).collect
    producer = Hive::Commands::Init.new("/tmp/demo", json: true).send(
      :success_payload, entry: entry, ops: ops, answers: answers
    )
    assert_equal schema_required, producer.keys.sort,
                 "Init#success_payload must emit exactly the schema's required keys"
  end

  def test_hive_init_success_payload_validates
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-init"))))
    ops = Struct.new(:default_branch, :hive_state_path).new("main", "/tmp/demo/.hive-state")
    entry = { "name" => "demo", "path" => "/tmp/demo", "hive_state_path" => "/tmp/demo/.hive-state" }
    answers = Hive::Commands::Init::Prompts.new(input: StringIO.new, summary_io: StringIO.new).collect
    payload = Hive::Commands::Init.new("/tmp/demo", json: true).send(
      :success_payload, entry: entry, ops: ops, answers: answers
    )

    errors = schemer.validate(payload).map { |e| e["error"] }
    assert_empty errors, "hive-init SuccessPayload must validate (errors: #{errors.inspect})"
  end

  # ── hive-forget ────────────────────────────────────────────────────────

  def test_hive_forget_schema_file_exists_and_is_valid_json
    path = Hive::Schemas.schema_path("hive-forget")
    assert File.exist?(path), "schema file missing: #{path}"

    doc = JSON.parse(File.read(path))
    assert_equal "https://json-schema.org/draft/2020-12/schema", doc["$schema"]
    %w[RemovedSuccessPayload AlreadyAbsentSuccessPayload].each do |def_name|
      assert_equal "hive-forget",
                   doc.dig("$defs", def_name, "properties", "schema", "const")
      assert_equal 1,
                   doc.dig("$defs", def_name, "properties", "schema_version", "const")
    end
  end

  def test_hive_forget_success_payload_variants_match_schema
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-forget")))
    removed_required = doc.dig("$defs", "RemovedSuccessPayload", "required").sort
    absent_required = doc.dig("$defs", "AlreadyAbsentSuccessPayload", "required").sort

    assert_equal %w[hive_state_path name ok path removed schema schema_version].sort,
                 removed_required,
                 "removed success required-key drift in hive-forget.v1.json"
    assert_equal %w[name ok removed schema schema_version].sort,
                 absent_required,
                 "already-absent success required-key drift in hive-forget.v1.json"

    command = Hive::Commands::Forget.new("ghost", json: true)
    removed_payload = command.send(
      :success_payload,
      { "name" => "demo", "path" => "/tmp/hive-demo", "hive_state_path" => "/tmp/hive-demo/.hive-state" }
    )
    absent_payload = command.send(:success_payload, nil)

    assert_equal removed_required, removed_payload.keys.sort,
                 "Forget#success_payload must emit exactly the removed-success schema keys"
    assert_equal absent_required, absent_payload.keys.sort,
                 "Forget#success_payload must emit exactly the already-absent schema keys"

    schemer = JSONSchemer.schema(doc)
    assert schemer.valid?(removed_payload),
           "removed success payload must validate (errors: #{schemer.validate(removed_payload).map { |e| e['error'] }.inspect})"
    assert schemer.valid?(absent_payload),
           "already-absent success payload must validate (errors: #{schemer.validate(absent_payload).map { |e| e['error'] }.inspect})"
  end

  def test_hive_forget_success_payload_schema_rejects_invalid_variants
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-forget"))))
    base = {
      "schema" => "hive-forget",
      "schema_version" => 1,
      "ok" => true,
      "name" => "demo"
    }

    invalid_absent_with_removed_path = base.merge(
      "removed" => false,
      "path" => "/tmp/demo",
      "hive_state_path" => "/tmp/demo/.hive-state"
    )
    invalid_removed_without_paths = base.merge("removed" => true)
    invalid_missing_removed = base.dup

    refute schemer.valid?(invalid_absent_with_removed_path),
           "already-absent success must not accept removed-entry path fields"
    refute schemer.valid?(invalid_removed_without_paths),
           "removed success must require path and hive_state_path"
    refute schemer.valid?(invalid_missing_removed),
           "all hive-forget success variants must require removed"
  end

  def test_hive_forget_error_kinds_match_closed_enum
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-forget")))
    schema_kinds = doc.dig("$defs", "ErrorPayload", "properties", "error_kind", "enum").sort
    assert_equal Hive::Schemas::ForgetErrorKind::ALL.sort, schema_kinds,
                 "schema ErrorPayload.error_kind enum must mirror Hive::Schemas::ForgetErrorKind::ALL"
  end

  def test_hive_forget_error_payload_validates_for_every_kind
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-forget"))))
    cases = {
      Hive::Schemas::ForgetErrorKind::MISSING_NAME =>
        Hive::Commands::Forget::UsageError.new("missing", error_kind: Hive::Schemas::ForgetErrorKind::MISSING_NAME),
      Hive::Schemas::ForgetErrorKind::UNKNOWN_PROJECT =>
        Hive::Commands::Forget::UsageError.new("not found", error_kind: Hive::Schemas::ForgetErrorKind::UNKNOWN_PROJECT),
      Hive::Schemas::ForgetErrorKind::CONFIG => Hive::ConfigError.new("bad config"),
      Hive::Schemas::ForgetErrorKind::INTERNAL => Hive::InternalError.new("boom")
    }
    cases.each do |kind, error|
      payload = Hive::Schemas::ErrorEnvelope.build(
        schema: "hive-forget",
        error: error,
        error_kind: kind
      )
      assert schemer.valid?(payload),
             "hive-forget ErrorPayload arm must accept error_kind=#{kind.inspect} (errors: #{schemer.validate(payload).map { |e| e['error'] }.inspect})"
    end
  end

  def test_hive_forget_error_payload_rejects_unknown_kind
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-forget"))))
    payload = {
      "schema" => "hive-forget",
      "schema_version" => 1,
      "ok" => false,
      "error_class" => "MysteryError",
      "error_kind" => "made_up_kind",
      "exit_code" => 1,
      "message" => "nope"
    }
    refute schemer.valid?(payload),
           "schema must reject error_kind values outside ForgetErrorKind::ALL"
  end

  # ── hive-drop ──────────────────────────────────────────────────────────

  def test_hive_drop_schema_file_exists_and_is_valid_json
    path = Hive::Schemas.schema_path("hive-drop")
    assert File.exist?(path), "schema file missing: #{path}"

    doc = JSON.parse(File.read(path))
    assert_equal "https://json-schema.org/draft/2020-12/schema", doc["$schema"]
    assert_equal "hive-drop",
                 doc.dig("$defs", "SuccessPayload", "properties", "schema", "const")
    assert_equal 1,
                 doc.dig("$defs", "SuccessPayload", "properties", "schema_version", "const")
  end

  def test_hive_drop_required_keys_match_producer_emission
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-drop")))
    schema_required = doc.dig("$defs", "SuccessPayload", "required").sort
    expected = %w[
      agent_kill_skipped_reason agent_killed agent_killed_pids agent_pid
      branch_deleted commit_action from_stages ok pr_closed project schema
      schema_version slug worktree_removed
    ].sort
    assert_equal expected, schema_required,
                 "schema/producer required-key drift in hive-drop.v1.json"

    context = Hive::Commands::Drop::TaskContext.new(
      slug: "demo-260522-aaaa",
      project_name: "demo",
      project_root: "/tmp/demo",
      hive_state_path: "/tmp/demo/.hive-state",
      folders: [],
      from_stages: [ "4-execute" ]
    )
    cleanup = {
      agent: { killed: false, pid: nil, killed_pids: [], skipped_reason: "no_pid" },
      pr_closed: false,
      worktree_removed: false,
      branch_deleted: false
    }
    producer = Hive::Commands::Drop.new("demo-260522-aaaa", json: true).send(
      :success_payload, context, cleanup, "committed"
    )
    assert_equal schema_required, producer.keys.sort,
                 "Drop#success_payload must emit exactly the schema's required keys"
  end

  def test_hive_drop_error_kinds_match_closed_enum
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-drop")))
    schema_kinds = doc.dig("$defs", "ErrorPayload", "properties", "error_kind", "enum").sort
    assert_equal Hive::Schemas::DropErrorKind::ALL.sort, schema_kinds,
                 "schema ErrorPayload.error_kind enum must mirror Hive::Schemas::DropErrorKind::ALL"
  end

  def test_hive_drop_error_payload_validates_for_every_kind
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-drop"))))
    cases = {
      Hive::Schemas::DropErrorKind::ALREADY_ARCHIVED => Hive::Commands::Drop::AlreadyArchived.new("archived"),
      Hive::Schemas::DropErrorKind::AMBIGUOUS_SLUG =>
        Hive::AmbiguousSlug.new("ambiguous", slug: "s", candidates: []),
      Hive::Schemas::DropErrorKind::WRONG_STAGE =>
        Hive::WrongStage.new("wrong", current_stage: "3-plan", target_stage: "2-brainstorm"),
      Hive::Schemas::DropErrorKind::INVALID_TASK_PATH => Hive::InvalidTaskPath.new("missing"),
      Hive::Schemas::DropErrorKind::CONFIG => Hive::ConfigError.new("bad config"),
      Hive::Schemas::DropErrorKind::GIT => Hive::GitError.new("bad git"),
      Hive::Schemas::DropErrorKind::WORKTREE => Hive::WorktreeError.new("bad worktree"),
      Hive::Schemas::DropErrorKind::INTERNAL => Hive::InternalError.new("boom"),
      Hive::Schemas::DropErrorKind::ERROR => Hive::Error.new("generic")
    }
    cases.each do |kind, error|
      payload = Hive::Schemas::ErrorEnvelope.build(
        schema: "hive-drop",
        error: error,
        error_kind: kind
      )
      assert schemer.valid?(payload),
             "hive-drop ErrorPayload arm must accept error_kind=#{kind.inspect} (errors: #{schemer.validate(payload).map { |e| e['error'] }.inspect})"
    end
  end

  def test_hive_drop_success_payload_validates
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-drop"))))
    payload = {
      "schema" => "hive-drop",
      "schema_version" => 1,
      "ok" => true,
      "slug" => "demo-260522-aaaa",
      "project" => "demo",
      "from_stages" => [ "4-execute" ],
      "pr_closed" => false,
      "worktree_removed" => true,
      "branch_deleted" => true,
      "agent_killed" => false,
      "agent_pid" => nil,
      "agent_killed_pids" => [],
      "agent_kill_skipped_reason" => "no_pid",
      "commit_action" => "committed"
    }
    assert schemer.valid?(payload),
           "hive-drop SuccessPayload must validate (errors: #{schemer.validate(payload).map { |e| e['error'] }.inspect})"
  end

  # ── hive-prune ─────────────────────────────────────────────────────────

  def test_hive_prune_schema_file_exists_and_is_valid_json
    path = Hive::Schemas.schema_path("hive-prune")
    assert File.exist?(path), "schema file missing: #{path}"

    doc = JSON.parse(File.read(path))
    assert_equal "https://json-schema.org/draft/2020-12/schema", doc["$schema"]
    assert_equal "hive-prune",
                 doc.dig("$defs", "SuccessPayload", "properties", "schema", "const")
    assert_equal 1,
                 doc.dig("$defs", "SuccessPayload", "properties", "schema_version", "const")
  end

  def test_hive_prune_required_keys_match_producer_emission
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-prune")))
    schema_required = doc.dig("$defs", "SuccessPayload", "required").sort

    assert_equal %w[dry_run kept_count ok removed removed_count schema schema_version].sort,
                 schema_required,
                 "schema/producer required-key drift in hive-prune.v1.json"

    producer = Hive::Commands::Prune.new(json: true).send(:success_payload, [], 0)
    assert_equal schema_required, producer.keys.sort,
                 "Prune#success_payload must emit exactly the schema's required keys"
  end

  def test_hive_prune_error_kinds_match_closed_enum
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-prune")))
    schema_kinds = doc.dig("$defs", "ErrorPayload", "properties", "error_kind", "enum").sort
    assert_equal Hive::Schemas::PruneErrorKind::ALL.sort, schema_kinds,
                 "schema ErrorPayload.error_kind enum must mirror Hive::Schemas::PruneErrorKind::ALL"
  end

  def test_hive_prune_error_payload_validates_for_every_kind
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-prune"))))
    cases = {
      Hive::Schemas::PruneErrorKind::USAGE => Hive::InvalidTaskPath.new("usage"),
      Hive::Schemas::PruneErrorKind::CONFIG => Hive::ConfigError.new("bad config"),
      Hive::Schemas::PruneErrorKind::INTERNAL => Hive::InternalError.new("boom")
    }
    cases.each do |kind, error|
      payload = Hive::Schemas::ErrorEnvelope.build(
        schema: "hive-prune",
        error: error,
        error_kind: kind
      )
      assert schemer.valid?(payload),
             "hive-prune ErrorPayload arm must accept error_kind=#{kind.inspect} (errors: #{schemer.validate(payload).map { |e| e['error'] }.inspect})"
    end
  end

  def test_hive_prune_error_payload_rejects_unknown_kind
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-prune"))))
    payload = {
      "schema" => "hive-prune",
      "schema_version" => 1,
      "ok" => false,
      "error_class" => "MysteryError",
      "error_kind" => "made_up_kind",
      "exit_code" => 1,
      "message" => "nope"
    }
    refute schemer.valid?(payload),
           "schema must reject error_kind values outside PruneErrorKind::ALL"
  end

  # ── hive-daemon-status ─────────────────────────────────────────────────

  def test_hive_daemon_status_schema_file_exists_and_is_valid_json
    path = Hive::Schemas.schema_path("hive-daemon-status")
    assert File.exist?(path), "schema file missing: #{path}"

    doc = JSON.parse(File.read(path))
    assert_equal "https://json-schema.org/draft/2020-12/schema", doc["$schema"]
    assert_equal "hive-daemon-status",
                 doc.dig("$defs", "SuccessPayload", "properties", "schema", "const")
    assert_equal 1,
                 doc.dig("$defs", "SuccessPayload", "properties", "schema_version", "const")
  end

  def test_hive_daemon_status_required_keys_match_producer_emission
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-daemon-status")))
    schema_required = doc.dig("$defs", "SuccessPayload", "required").sort
    # The producer's exhaustive key set (kept in sync with
    # Hive::Commands::Daemon#status_daemon's JSON.generate call).
    producer_required = %w[
      schema schema_version ok running pid uptime_sec pid_file log_file
    ].sort
    assert_equal producer_required, schema_required,
                 "schema/producer required-key drift in hive-daemon-status.v1.json"
  end

  # ── hive-daemon-stop ───────────────────────────────────────────────────

  def test_hive_daemon_stop_schema_file_exists_and_is_valid_json
    path = Hive::Schemas.schema_path("hive-daemon-stop")
    assert File.exist?(path), "schema file missing: #{path}"

    doc = JSON.parse(File.read(path))
    assert_equal "https://json-schema.org/draft/2020-12/schema", doc["$schema"]
    assert_equal "hive-daemon-stop",
                 doc.dig("$defs", "SuccessPayload", "properties", "schema", "const")
    assert_equal 1,
                 doc.dig("$defs", "SuccessPayload", "properties", "schema_version", "const")
  end

  def test_hive_daemon_stop_required_keys_match_producer_emission
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-daemon-stop")))
    schema_required = doc.dig("$defs", "SuccessPayload", "required").sort
    # Producer emits via stop_envelope which calls .compact, so optional
    # keys (stale_pid, reason) may be absent.
    producer_required = %w[schema schema_version ok running was_running].sort
    assert_equal producer_required, schema_required,
                 "schema/producer required-key drift in hive-daemon-stop.v1.json"
  end

  def test_hive_daemon_stop_reason_enum_pinned
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-daemon-stop")))
    schema_reasons = doc.dig("$defs", "SuccessPayload", "properties", "reason", "enum").sort
    # Reasons emitted by the three refusal branches in stop_daemon:
    # pid_reused / unverified (PID-reuse defense), malformed_pid_file
    # (PID file exists but unparseable).
    producer_reasons = %w[pid_reused unverified malformed_pid_file].sort
    assert_equal producer_reasons, schema_reasons
  end

  # ── hive-daemon-reload ─────────────────────────────────────────────────

  def test_hive_daemon_reload_schema_file_exists_and_is_valid_json
    path = Hive::Schemas.schema_path("hive-daemon-reload")
    assert File.exist?(path), "schema file missing: #{path}"

    doc = JSON.parse(File.read(path))
    assert_equal "https://json-schema.org/draft/2020-12/schema", doc["$schema"]
    assert_equal "hive-daemon-reload",
                 doc.dig("$defs", "SuccessPayload", "properties", "schema", "const")
    assert_equal 1,
                 doc.dig("$defs", "SuccessPayload", "properties", "schema_version", "const")
  end

  def test_hive_daemon_reload_required_keys_match_producer_emission
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-daemon-reload")))
    schema_required = doc.dig("$defs", "SuccessPayload", "required").sort
    # Producer emits via reload_envelope which calls .compact; only
    # always-present keys are required. pid/reason are optional.
    producer_required = %w[schema schema_version ok message].sort
    assert_equal producer_required, schema_required,
                 "schema/producer required-key drift in hive-daemon-reload.v1.json"
  end

  def test_hive_daemon_reload_reason_enum_pinned
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-daemon-reload")))
    schema_reasons = doc.dig("$defs", "SuccessPayload", "properties", "reason", "enum").sort
    # Reasons emitted by the four refusal branches in compute_reload_outcome.
    producer_reasons = %w[not_running pid_dead pid_reused unverified].sort
    assert_equal producer_reasons, schema_reasons
  end

  # ── hive-daemon-enroll ─────────────────────────────────────────────────

  def test_hive_daemon_enroll_schema_file_exists_and_is_valid_json
    path = Hive::Schemas.schema_path("hive-daemon-enroll")
    assert File.exist?(path), "schema file missing: #{path}"

    doc = JSON.parse(File.read(path))
    assert_equal "https://json-schema.org/draft/2020-12/schema", doc["$schema"]
    assert_equal "hive-daemon-enroll",
                 doc.dig("$defs", "SuccessPayload", "properties", "schema", "const")
    assert_equal 1,
                 doc.dig("$defs", "SuccessPayload", "properties", "schema_version", "const")
  end

  def test_hive_daemon_enroll_success_required_keys_match_producer_emission
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-daemon-enroll")))
    schema_required = doc.dig("$defs", "SuccessPayload", "required").sort
    # The producer always emits these. `next_action` is OPTIONAL in v1
    # because PR #45's earlier v1 producer shipped without it; making
    # next_action required now would silently break consumers pinned
    # to PR #45's envelope shape. A future v2 may promote it.
    producer_required = %w[schema schema_version ok subcommand results].sort
    assert_equal producer_required, schema_required,
                 "schema/producer required-key drift in hive-daemon-enroll.v1.json (envelope)"

    item_required = doc.dig("$defs", "Result", "required").sort
    item_producer = %w[name path previous current config_yml].sort
    assert_equal item_producer, item_required,
                 "schema/producer required-key drift in hive-daemon-enroll.v1.json (Result)"
  end

  # Although next_action is OPTIONAL on v1, the current producer always
  # emits it; that emission must validate against the schema. This pins
  # the additive shape so a future change can't drop next_action from
  # the producer without first updating the schema (or a future v2).
  def test_hive_daemon_enroll_success_with_next_action_validates
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-daemon-enroll"))))
    payload = {
      "schema" => "hive-daemon-enroll",
      "schema_version" => 1,
      "ok" => true,
      "subcommand" => "enable",
      "results" => [
        { "name" => "p", "path" => "/tmp/p", "previous" => false,
          "current" => true, "config_yml" => "/tmp/p/.hive-state/config.yml" }
      ],
      "next_action" => {
        "kind" => "reload",
        "command" => "hive daemon reload",
        "required" => false,
        "reason" => "daemon picks up daemon.enabled changes within poll_interval_sec"
      }
    }
    errors = schemer.validate(payload).map { |e| e["error"] }
    assert_empty errors, "current producer payload (with next_action) must validate"
  end

  # The original PR #45 v1 envelope shape (no next_action) is also
  # valid v1 — we did not introduce a silent breaking change by
  # adding the field.
  def test_hive_daemon_enroll_pr45_legacy_shape_still_validates
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-daemon-enroll"))))
    legacy_payload = {
      "schema" => "hive-daemon-enroll",
      "schema_version" => 1,
      "ok" => true,
      "subcommand" => "enable",
      "results" => [
        { "name" => "p", "path" => "/tmp/p", "previous" => nil,
          "current" => true, "config_yml" => "/tmp/p/.hive-state/config.yml" }
      ]
    }
    errors = schemer.validate(legacy_payload).map { |e| e["error"] }
    assert_empty errors, "PR #45's no-next_action envelope shape must still validate as v1 " \
                         "(otherwise this PR is a silent breaking change)"
  end

  def test_hive_daemon_enroll_subcommand_enum_pinned
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-daemon-enroll")))
    schema_verbs = doc.dig("$defs", "SuccessPayload", "properties", "subcommand", "enum").sort
    assert_equal %w[disable enable], schema_verbs
  end

  def test_hive_daemon_enroll_next_action_kind_enum_pinned
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-daemon-enroll")))
    schema_kinds = doc.dig("$defs", "NextAction", "properties", "kind", "enum").sort
    # Producer emits one of these two from enroll_next_action.
    producer_kinds = %w[no_op reload].sort
    assert_equal producer_kinds, schema_kinds,
                 "schema/producer drift in hive-daemon-enroll NextAction.kind enum"
  end

  def test_hive_daemon_enroll_error_kinds_match_closed_enum
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-daemon-enroll")))
    schema_kinds = doc.dig("$defs", "ErrorPayload", "properties", "error_kind", "enum").sort
    assert_equal Hive::Schemas::EnrollErrorKind::ALL.sort, schema_kinds,
                 "schema ErrorPayload.error_kind enum must mirror Hive::Schemas::EnrollErrorKind::ALL"
  end

  def test_hive_daemon_enroll_error_payload_validates_for_every_kind
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-daemon-enroll"))))
    cases = {
      Hive::Schemas::EnrollErrorKind::MISSING_PROJECT =>
        Hive::Commands::Daemon::UsageError.new(
          "missing", error_kind: Hive::Schemas::EnrollErrorKind::MISSING_PROJECT
        ),
      Hive::Schemas::EnrollErrorKind::UNKNOWN_PROJECT =>
        Hive::Commands::Daemon::UsageError.new(
          "unknown", error_kind: Hive::Schemas::EnrollErrorKind::UNKNOWN_PROJECT
        ),
      Hive::Schemas::EnrollErrorKind::PROJECT_AND_ALL =>
        Hive::Commands::Daemon::UsageError.new(
          "both", error_kind: Hive::Schemas::EnrollErrorKind::PROJECT_AND_ALL
        ),
      Hive::Schemas::EnrollErrorKind::NOT_INITIALISED =>
        Hive::Commands::Daemon::UsageError.new(
          "not init", error_kind: Hive::Schemas::EnrollErrorKind::NOT_INITIALISED
        ),
      Hive::Schemas::EnrollErrorKind::NO_PROJECTS =>
        Hive::Commands::Daemon::UsageError.new(
          "empty", error_kind: Hive::Schemas::EnrollErrorKind::NO_PROJECTS
        ),
      Hive::Schemas::EnrollErrorKind::CONFIG => Hive::ConfigError.new("bad config"),
      Hive::Schemas::EnrollErrorKind::INTERNAL => Hive::InternalError.new("boom")
    }
    cases.each do |kind, error|
      payload = Hive::Schemas::ErrorEnvelope.build(
        schema: "hive-daemon-enroll",
        error: error,
        error_kind: kind
      )
      assert schemer.valid?(payload),
             "hive-daemon-enroll ErrorPayload arm must accept error_kind=#{kind.inspect} (errors: #{schemer.validate(payload).map { |e| e['error'] }.inspect})"
    end
  end

  def test_hive_daemon_enroll_error_payload_rejects_unknown_kind
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-daemon-enroll"))))
    payload = {
      "schema" => "hive-daemon-enroll",
      "schema_version" => 1,
      "ok" => false,
      "error_class" => "MysteryError",
      "error_kind" => "made_up_kind",
      "exit_code" => 1,
      "message" => "nope"
    }
    refute schemer.valid?(payload),
           "schema must reject error_kind values outside EnrollErrorKind::ALL"
  end
end
