require "test_helper"
require "json"
require "json_schemer"
require "hive/commands/answer_digest"
require "hive/commands/approve"
require "hive/commands/bot"
require "hive/commands/daemon"
require "hive/commands/drop"
require "hive/commands/forget"
require "hive/commands/init"
require "hive/commands/patrol"
require "hive/commands/prune"
require "hive/commands/run"
require "hive/commands/stage_action"
require "hive/commands/status"
require "hive/patrol/candidate_selector"
require "hive/patrol/reviewer"
require "hive/tui/snapshot"
require "hive/daemon/dispatch_request_queue"
require "hive/daemon/dispatch_result_queue"
require "tmpdir"

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

  # U6: the stage-dir / stage-name / stage-index fields were relaxed from the
  # closed coding enums to patterns so generic (runtime-registered) workflow
  # stages validate, mirroring the hive-status.v4 precedent. The contract is
  # now "well-formed N-name dir / bare name", not a fixed coding whitelist.
  def test_hive_approve_v2_relaxes_stage_fields_to_patterns_for_generic_workflows
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-approve")))
    props = doc.dig("$defs", "SuccessPayload", "properties")

    %w[from_stage_dir to_stage_dir].each do |field|
      assert_nil props.dig(field, "enum"),
                 "#{field} must not be a closed coding enum — generic dirs are runtime-registered"
      dir_re = Regexp.new(props.fetch(field).fetch("pattern"))
      # Coding dirs still validate (no regression for pinned consumers)…
      assert_match dir_re, "7-artifacts", "#{field} pattern must still accept coding dirs"
      assert_match dir_re, "9-done"
      # …and the generic descriptor dirs the producer now emits validate too.
      assert_match dir_re, "3-report", "#{field} pattern must accept generic descriptor dirs"
      assert_match dir_re, "2-gather"
      refute_match dir_re, "plan", "#{field} pattern still requires the N- index prefix"
    end

    %w[from_stage to_stage].each do |field|
      assert_nil props.dig(field, "enum"),
                 "#{field} must not be a closed coding enum"
      name_re = Regexp.new(props.fetch(field).fetch("pattern"))
      assert_match name_re, "open-pr", "#{field} pattern must accept hyphenated coding names"
      assert_match name_re, "report", "#{field} pattern must accept generic stage names"
    end

    %w[from_stage_index to_stage_index].each do |field|
      assert_nil props.dig(field, "maximum"),
                 "#{field} must drop the maximum:9 cap so generic descriptors past 9 stages validate"
      assert_equal 1, props.dig(field, "minimum")
    end
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
      wrong_stage rollback_failed invalid_task_path dependency_wait
      admission_error error
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
    assert_equal 5,
                 doc.dig("$defs", "SuccessPayload", "properties", "schema_version", "const")
  end

  def test_hive_status_v4_schema_remains_for_back_compat
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-status", version: 4)))
    assert_equal 4, doc.dig("$defs", "SuccessPayload", "properties", "schema_version", "const")
    refute_includes doc.dig("$defs", "Task", "properties").keys, "admission_error"
  end

  def test_hive_status_v1_schema_remains_for_back_compat
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-status", version: 1)))
    assert_equal 1, doc.dig("$defs", "SuccessPayload", "properties", "schema_version", "const")
    assert_includes doc.dig("$defs", "Task", "properties", "stage", "enum"), "6-pr"
    assert_includes doc.dig("$defs", "Task", "properties", "action", "enum"), "ready_for_pr"
  end

  # v3 (the pre-dependency schema) is preserved for external validators
  # pinned to the release before the task-dependency fields landed in v4.
  # The daemon fails closed on a v3 payload via schema-skew, so correctness
  # holds — but unlike hive-approve there was no test guarding v3 against
  # accidental mutation. v3's Task must NOT carry the v4 dependency fields.
  def test_hive_status_v3_schema_remains_for_back_compat
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-status", version: 3)))
    assert_equal 3, doc.dig("$defs", "SuccessPayload", "properties", "schema_version", "const")

    v3_required = doc.dig("$defs", "Task", "required")
    v3_props = doc.dig("$defs", "Task", "properties").keys
    %w[depends_on blocked_by dependency_stage blocked].each do |field|
      refute_includes v3_required, field,
                      "v3 Task must not require the v4 dependency field #{field.inspect}"
      refute_includes v3_props, field,
                      "v3 Task must not declare the v4 dependency property #{field.inspect}"
    end
  end

  def test_hive_status_required_keys_match_producer_emission
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-status")))
    schema_required = doc.dig("$defs", "SuccessPayload", "required").sort
    assert_equal %w[generated_at ok projects schema schema_version].sort, schema_required

    row = {
      stage: "1-inbox",
      slug: "probe",
      id: 42,
      display_name: "Probe",
      depends_on: nil,
      blocked_by: nil,
      dependency_stage: nil,
      blocked: false,
      admission_error: nil,
      folder: "/tmp/probe",
      state_file: "/tmp/probe/idea.md",
      pr_url: nil,
      marker_name: :waiting,
      marker_attrs: {},
      mtime: Time.now,
      folder_mtime: Time.now,
      claude_pid: nil,
      claude_pid_alive: nil,
      action_key: Hive::Schemas::TaskActionKind::READY_TO_BRAINSTORM,
      action_label: "Ready to brainstorm",
      suggested_command: "hive brainstorm probe --from 1-inbox",
      diagnostic: nil,
      worktree_path: nil,
      live_task_lock: false,
      unanswered_questions: 0,
      next_action: nil
    }
    producer_keys = Hive::Commands::Status.new.task_payload(row).keys.sort
    schema_task_required = doc.dig("$defs", "Task", "required").sort
    assert_equal producer_keys, schema_task_required,
                 "schema/producer required-key drift in hive-status Task"
  end

  def test_hive_status_task_enums_match_closed_sets
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-status")))

    stage_pattern = "^[0-9]+-[a-z0-9][a-z0-9-]*$"
    assert_equal stage_pattern,
                 doc.dig("$defs", "Task", "properties", "stage", "pattern")
    assert_equal stage_pattern,
                 doc.dig("$defs", "Task", "properties", "dependency_stage", "pattern")
    assert_nil doc.dig("$defs", "Task", "properties", "stage", "enum"),
               "generic workflow stage dirs are runtime-registered, so stage must not be a coding enum"
    assert_equal Hive::Commands::Status::ICON.keys.map(&:to_s).sort,
                 doc.dig("$defs", "Task", "properties", "marker", "enum").sort
    assert_equal Hive::Schemas::TaskActionKind::ALL.sort,
                 doc.dig("$defs", "Task", "properties", "action", "enum").sort
  end

  def test_hive_status_admission_error_is_closed_and_matches_reason_codes
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-status")))
    definition = doc.dig("$defs", "AdmissionError")
    assert_equal Hive::DependencyAdmission::REASON_CODES.sort,
                 definition.dig("properties", "reason_code", "enum").sort

    schemer = JSONSchemer.schema(definition)
    valid = {
      "reason_code" => "dependency_cycle",
      "offending_ref" => "app:a -> app:b -> app:a",
      "safe_correction" => "Break the cycle."
    }
    assert schemer.valid?(valid)
    refute schemer.valid?(valid.merge("reason_code" => "unknown_reason"))
    refute schemer.valid?(valid.merge("extra" => true))
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
      "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-status"),
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

  # Round-trip: a SuccessPayload carrying POPULATED tasks must validate.
  # The other success-path round-trips here use empty `tasks` arrays, so a
  # real producer-shaped Task (every required field present, including the
  # additive pr_url and v4 dependency fields) is validated against the
  # published schema. Build the tasks through the producer (#task_payload) so
  # a missing/renamed key, a pr_url type drift, or a too-narrow dependency
  # field type fails here. Exercise BOTH the pr_url string and pr_url null
  # variants, since pr_url is "type": ["string","null"].
  def test_hive_status_success_payload_with_populated_tasks_validates_against_published_schema
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-status"))))
    base_row = {
      stage: "6-review",
      slug: "review-task",
      id: 7,
      display_name: "Fix Login",
      depends_on: "base-task",
      blocked_by: "base-task",
      dependency_stage: "7-artifacts",
      blocked: true,
      admission_error: nil,
      folder: "/tmp/review-task",
      state_file: "/tmp/review-task/task.md",
      marker_name: :review_waiting,
      marker_attrs: {},
      mtime: Time.now,
      folder_mtime: Time.now,
      claude_pid: nil,
      claude_pid_alive: nil,
      action_key: Hive::Schemas::TaskActionKind::READY_FOR_REVIEW,
      action_label: "Ready for review",
      suggested_command: "hive review review-task",
      diagnostic: nil,
      worktree_path: "/tmp/wt",
      live_task_lock: false,
      unanswered_questions: 0,
      next_action: nil
    }
    status = Hive::Commands::Status.new
    task_with_pr = status.task_payload(base_row.merge(pr_url: "https://github.com/example/repo/pull/561"))
    task_without_pr = status.task_payload(base_row.merge(slug: "early-task", pr_url: nil))
    retry_after = "2026-06-24T23:20:00Z"
    held_task = status.task_payload(base_row.merge(
                                      slug: "quota-task",
                                      pr_url: nil,
                                      marker_name: :error,
                                      marker_attrs: {
                                        "reason" => "limits_reached",
                                        "provider" => "codex",
                                        "retry_after" => retry_after
                                      },
                                      action_key: Hive::Schemas::TaskActionKind::ERROR,
                                      action_label: "Error",
                                      suggested_command: nil
                                    ))
    # The null variant: an attr-less legacy limit marker emits
    # `held: {reason: quota, provider: null, retry_after: null}` — the exact
    # shape the schema declares provider/retry_after nullable for. Validating
    # it here catches a schema-tightening or a nil→"" producer regression
    # that the fully-populated case above would pass through green.
    held_task_null = status.task_payload(base_row.merge(
                                           slug: "quota-task-bare",
                                           pr_url: nil,
                                           marker_name: :error,
                                           marker_attrs: { "reason" => "limits_reached" },
                                           action_key: Hive::Schemas::TaskActionKind::ERROR,
                                           action_label: "Error",
                                           suggested_command: nil
                                         ))

    payload = {
      "schema" => "hive-status",
      "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-status"),
      "ok" => true,
      "generated_at" => "2026-06-15T00:00:00Z",
      "projects" => [
        {
          "name" => "demo",
          "path" => "/tmp/demo",
          "hive_state_path" => "/tmp/demo/.hive-state",
          "tasks" => [ task_with_pr, task_without_pr, held_task, held_task_null ],
          "legacy_stage_dirs" => [],
          "legacy_migrate_command" => nil
        }
      ]
    }
    errors = schemer.validate(payload).map { |e| e["error"] }
    assert_empty errors,
                 "populated tasks (dependency fields plus pr_url string + null, held populated + null) " \
                 "must validate against the schema (errors: #{errors.inspect})"
    assert_equal "https://github.com/example/repo/pull/561", task_with_pr["pr_url"]
    assert_nil task_without_pr["pr_url"]
    assert_equal({
      "reason" => "quota",
      "provider" => "codex",
      "retry_after" => retry_after
    }, held_task["held"])
    assert_equal({
      "reason" => "quota",
      "provider" => nil,
      "retry_after" => nil
    }, held_task_null["held"])
  end

  # `legacy_migrate_command` accepts either "hive migrate" (when
  # legacy_stage_dirs is non-empty) or `null` (when clean); any other
  # JSON type (e.g. a boolean or a number) must be rejected. Issue #94.
  def test_hive_status_legacy_migrate_command_rejects_non_string_non_null
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-status"))))
    payload = {
      "schema" => "hive-status",
      "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-status"),
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
      "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-status"),
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
    assert_equal 2,
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
      "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-status-diagnose"),
      "ok" => true,
      "slug" => "probe",
      "id" => 42,
      "display_name" => "Probe",
      "task_folder" => "/tmp/probe",
      "marker_summary" => "REVIEW_ERROR phase=fix pass=1",
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
      "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-status-diagnose"),
      "ok" => true,
      "slug" => "probe",
      "id" => nil,
      "display_name" => nil,
      "task_folder" => "/tmp/probe",
      "marker_summary" => nil,
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
      Hive::Schemas::RunErrorKind::DEPENDENCY_WAIT => Hive::DependencyWaitError.new(
        "waiting", offending_ref: "base", safe_correction: "Wait for base."
      ),
      Hive::Schemas::RunErrorKind::ADMISSION_ERROR => Hive::DependencyAdmissionError.new(
        "invalid", reason_code: "dependency_cycle", offending_ref: "p:a -> p:a",
        safe_correction: "Break the cycle."
      ),
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
    assert_equal 2,
                 doc.dig("$defs", "SuccessPayload", "properties", "schema_version", "const")
  end

  def test_hive_init_v1_schema_remains_pinned
    path = Hive::Schemas.schema_path("hive-init", version: 1)
    doc = JSON.parse(File.read(path))

    assert_equal 1, doc.dig("$defs", "SuccessPayload", "properties", "schema_version", "const")
    refute_includes doc.dig("$defs", "Answers", "required"), "refactor_patrol_enabled"
  end

  def test_hive_init_required_keys_match_producer_emission
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-init")))
    schema_required = doc.dig("$defs", "SuccessPayload", "required").sort
    answers_required = doc.dig("$defs", "Answers", "required").sort
    expected = %w[
      adhoc_auto_fix answers babysitter_enabled budgets claude_mode daemon_autostart_requested daemon_enabled
      default_branch development_agent enabled_reviewers hints hive_state_path ok path patrol_mode patrol_reviewers planning_agent
      project refactor_patrol_enabled schema schema_version timeouts triage_bias workflow worktree_root
    ].sort
    assert_equal expected, schema_required,
                 "schema/producer required-key drift in hive-init.v2.json"

    # Sandbox the project root: success_payload now drives load_dir against
    # <hive_state_path>/workflows, so a hardcoded /tmp/demo would read a real,
    # world-shared path. Mirror the twin test_hive_init_success_payload_validates.
    Dir.mktmpdir("hive-init-keys") do |dir|
      state_path = File.join(dir, ".hive-state")
      ops = Struct.new(:default_branch, :hive_state_path).new("main", state_path)
      entry = { "name" => "demo", "path" => dir, "hive_state_path" => state_path }
      answers = Hive::Commands::Init::Prompts.new(input: StringIO.new, summary_io: StringIO.new).collect
      assert_equal answers.keys.sort, answers_required,
                   "schema/prompt answer-key drift in hive-init.v2.json"
      producer = Hive::Commands::Init.new(dir, json: true).send(
        :success_payload, entry: entry, ops: ops, answers: answers, workflow: :coding
      )
      assert_equal schema_required, producer.keys.sort,
                   "Init#success_payload must emit exactly the schema's required keys"
    end
  end

  def test_hive_init_success_payload_validates
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-init"))))
    Dir.mktmpdir("hive-init-schema") do |dir|
      state_path = File.join(dir, ".hive-state")
      ops = Struct.new(:default_branch, :hive_state_path).new("main", state_path)
      entry = { "name" => "demo", "path" => dir, "hive_state_path" => state_path }
      answers = Hive::Commands::Init::Prompts.new(input: StringIO.new, summary_io: StringIO.new).collect
      payload = Hive::Commands::Init.new(dir, json: true).send(
        :success_payload, entry: entry, ops: ops, answers: answers, workflow: :coding
      )

      assert_equal [
        {
          "kind" => "custom_workflow",
          "command" => "hive workflow new <id>",
          "message" => "custom workflows live in this project — author one with `hive workflow new <id>`"
        }
      ], payload.fetch("hints")

      errors = schemer.validate(payload).map { |e| e["error"] }
      assert_empty errors, "hive-init SuccessPayload must validate (errors: #{errors.inspect})"
    end
  end

  def test_hive_init_new_workflow_success_payload_validates_with_scaffold_paths
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-init"))))
    ops = Struct.new(:default_branch, :hive_state_path).new("main", "/tmp/demo/.hive-state")
    entry = { "name" => "demo", "path" => "/tmp/demo", "hive_state_path" => "/tmp/demo/.hive-state" }
    answers = Hive::Commands::Init::Prompts.new(input: StringIO.new, summary_io: StringIO.new).collect
    payload = Hive::Commands::Init.new("/tmp/demo", json: true).send(
      :success_payload, entry: entry, ops: ops, answers: answers, workflow: :writing
    ).merge(
      "descriptor_path" => "/tmp/demo/.hive-state/workflows/writing.yml",
      "instruction_path" => "/tmp/demo/.hive-state/workflows/writing/work.md"
    )

    errors = schemer.validate(payload).map { |e| e["error"] }
    assert_empty errors, "hive-init --new-workflow SuccessPayload must validate (errors: #{errors.inspect})"
    assert_equal "writing", payload.fetch("workflow")
    assert_equal "/tmp/demo/.hive-state/workflows/writing.yml", payload.fetch("descriptor_path")
    assert_equal "/tmp/demo/.hive-state/workflows/writing/work.md", payload.fetch("instruction_path")
  end

  def test_hive_init_new_workflow_already_initialized_payload_validates_with_scaffold_paths
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-init"))))
    ops = Struct.new(:hive_state_path).new("/tmp/demo/.hive-state")
    descriptor = Struct.new(:id).new(:writing)
    workflow_choice = Hive::Commands::Init::WorkflowChoice.new(descriptor: descriptor, source: :flag)
    payload = Hive::Commands::Init.new("/tmp/demo", json: true).send(
      :existing_payload, ops, workflow_choice: workflow_choice
    ).merge(
      "descriptor_path" => "/tmp/demo/.hive-state/workflows/writing.yml",
      "instruction_path" => "/tmp/demo/.hive-state/workflows/writing/work.md"
    )

    errors = schemer.validate(payload).map { |e| e["error"] }
    assert_empty errors,
                 "hive-init --new-workflow AlreadyInitializedPayload must validate (errors: #{errors.inspect})"
    assert_equal true, payload.fetch("already_initialized")
    assert_equal "writing", payload.fetch("workflow")
    assert_equal "/tmp/demo/.hive-state/workflows/writing.yml", payload.fetch("descriptor_path")
    assert_equal "/tmp/demo/.hive-state/workflows/writing/work.md", payload.fetch("instruction_path")
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
      Hive::Schemas::ForgetErrorKind::USAGE =>
        Hive::Commands::Forget::UsageError.new("usage", error_kind: Hive::Schemas::ForgetErrorKind::USAGE),
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
    assert_equal 2,
                 doc.dig("$defs", "SuccessPayload", "properties", "schema_version", "const"),
                 "v2 changed pr_closed semantics (true = PR cleanup clean incl. the "                  "no-PR case; false strictly = a recorded PR would not close)"
  end

  # v1 (pr_closed false for the no-PR case too) is preserved for external
  # validators pinned to pre-v2 releases.
  def test_hive_drop_v1_schema_file_remains_for_back_compat
    path = Hive::Schemas.schema_path("hive-drop", version: 1)
    assert File.exist?(path), "v1 schema file missing: #{path}"

    doc = JSON.parse(File.read(path))
    assert_equal 1,
                 doc.dig("$defs", "SuccessPayload", "properties", "schema_version", "const"),
                 "v1 schema must still declare schema_version: 1"
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
      "schema_version" => 2,
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

  def test_hive_patrol_v1_remains_pinned_for_back_compat
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-patrol", version: 1)))

    assert_equal 1, doc.dig("$defs", "SuccessPayload", "properties", "schema_version", "const")
    reasons = doc.dig("$defs", "SuccessPayload", "properties", "skipped_findings",
                      "items", "properties", "reason", "enum")
    assert_equal %w[dismissed existing_pr similar_to_existing low_confidence low_severity], reasons
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
    # Hive::Commands::Daemon#status_daemon's JSON.generate call). The three
    # service_* fields are always emitted (null on probe failure), so they
    # are required-but-nullable in the schema.
    producer_required = %w[
      schema schema_version ok running pid uptime_sec pid_file log_file
      service_installed service_enabled unit_path
      installed_binary expected_binary installed_binary_version cli_version binary_drift
      current_version update_nudge
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

  # ── hive-daemon-queue ──────────────────────────────────────────────────

  def test_hive_daemon_queue_schema_file_exists_and_is_valid_json
    path = Hive::Schemas.schema_path("hive-daemon-queue")
    assert File.exist?(path), "schema file missing: #{path}"

    doc = JSON.parse(File.read(path))
    assert_equal "https://json-schema.org/draft/2020-12/schema", doc["$schema"]
    assert_equal "hive-daemon-queue",
                 doc.dig("$defs", "SuccessPayload", "properties", "schema", "const")
    assert_equal 1,
                 doc.dig("$defs", "SuccessPayload", "properties", "schema_version", "const")
  end

  def test_hive_daemon_queue_required_keys_match_producer_emission
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-daemon-queue")))
    schema_required = doc.dig("$defs", "SuccessPayload", "required").sort
    # queue_envelope always emits these four; requests/request/malformed/
    # pruned_count/request_id are per-action optional keys.
    producer_required = %w[schema schema_version ok action].sort
    assert_equal producer_required, schema_required,
                 "schema/producer required-key drift in hive-daemon-queue.v1.json"
  end

  def test_hive_daemon_queue_action_enum_pinned
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-daemon-queue")))
    schema_actions = doc.dig("$defs", "SuccessPayload", "properties", "action", "enum").sort
    assert_equal Hive::Commands::Daemon::VALID_QUEUE_ACTIONS.sort, schema_actions,
                 "action enum must match Daemon::VALID_QUEUE_ACTIONS"
  end

  def test_hive_daemon_queue_request_required_keys_match_producer
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-daemon-queue")))
    schema_required = doc.dig("$defs", "Request", "required").sort
    # Mirrors Hive::Commands::Daemon#queue_request_hash.
    producer_required = %w[
      request_id created_at age_sec project slug verb argv trigger
      requestor chat_id update_id expired allowlisted
    ].sort
    assert_equal producer_required, schema_required,
                 "Request required-key drift in hive-daemon-queue.v1.json"
  end

  def test_hive_daemon_queue_error_payload_validates
    schema = JSON.parse(File.read(Hive::Schemas.schema_path("hive-daemon-queue")))
    schemer = JSONSchemer.schema(schema)
    error_envelope = {
      "schema" => "hive-daemon-queue", "schema_version" => 1, "ok" => false,
      "action" => "bogus", "error_kind" => "unknown_action",
      "message" => "hive daemon queue: unknown action"
    }
    assert_empty schemer.validate(error_envelope).to_a,
                 "error envelope must validate against the ErrorPayload arm"
    # The error_kind enum is pinned to the producer's set.
    assert_equal %w[internal invalid_arguments missing_request_id unknown_action],
                 schema.dig("$defs", "ErrorPayload", "properties", "error_kind", "enum").sort
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

  # ── hive-bot-status ────────────────────────────────────────────────────

  # The usage-error kinds the `hive bot` surface emits through
  # Hive::Commands::Bot.json_usage_error_payload. missing_subcommand /
  # unknown_subcommand are raised in Hive::Commands::Bot#call; the cli.rb
  # `bot` dispatcher raises wrong_subcommand_flag before the command runs
  # (e.g. `bot status --force`); and extra_arguments rides the bin/hive
  # JSON_USAGE_ERROR_CONTRACTS `bot` entry when Thor rejects an extra
  # positional (e.g. `bot status extra`) before dispatch. All ride the
  # hive-bot-status schema because there is no separate bot-usage-error
  # schema — JSON_USAGE_ERROR_SCHEMA points here.
  BOT_USAGE_ERROR_KINDS = %w[
    missing_subcommand unknown_subcommand wrong_subcommand_flag extra_arguments
  ].freeze

  def test_hive_bot_status_schema_file_exists_and_is_valid_json
    path = Hive::Schemas.schema_path("hive-bot-status")
    assert File.exist?(path), "schema file missing: #{path}"

    doc = JSON.parse(File.read(path))
    assert_equal "https://json-schema.org/draft/2020-12/schema", doc["$schema"]
    assert_equal "hive-bot-status",
                 doc.dig("$defs", "SuccessPayload", "properties", "schema", "const")
    assert_equal 1,
                 doc.dig("$defs", "SuccessPayload", "properties", "schema_version", "const")
  end

  # The usage-error arm (ErrorPayload) must exist in the oneOf alongside the
  # SuccessPayload — without it, every `hive bot ... --json` usage error
  # (which carries ok:false) is rejected by schema-validating agent clients.
  def test_hive_bot_status_oneof_carries_success_and_error_arms
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-bot-status")))
    refs = doc.fetch("oneOf").map { |arm| arm["$ref"] }
    assert_includes refs, "#/$defs/SuccessPayload"
    assert_includes refs, "#/$defs/ErrorPayload",
                    "hive-bot-status must carry an ErrorPayload arm for usage errors"
    assert_equal "hive-bot-status",
                 doc.dig("$defs", "ErrorPayload", "properties", "schema", "const")
    assert_equal false,
                 doc.dig("$defs", "ErrorPayload", "properties", "ok", "const"),
                 "ErrorPayload.ok must pin false so it never collides with SuccessPayload (ok:true)"
  end

  def test_hive_bot_status_error_kinds_match_producer_emission
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-bot-status")))
    schema_kinds = doc.dig("$defs", "ErrorPayload", "properties", "error_kind", "enum").sort
    assert_equal BOT_USAGE_ERROR_KINDS.sort, schema_kinds,
                 "schema ErrorPayload.error_kind enum must mirror the bot usage-error kinds"
  end

  # Round-trip: every bot usage-error kind, built through the real producer
  # (Hive::Commands::Bot.json_usage_error_payload), must validate against the
  # published schema. This is the direct guard for the bug — before the
  # ErrorPayload arm existed, `bot status --force --json` / `bot --json`
  # emitted an ok:false envelope claiming schema "hive-bot-status" that the
  # schema rejected.
  def test_hive_bot_status_usage_error_payload_validates_for_every_kind
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-bot-status"))))
    error = Hive::InvalidTaskPath.new("hive bot: usage error")
    BOT_USAGE_ERROR_KINDS.each do |kind|
      payload = Hive::Commands::Bot.json_usage_error_payload(error: error, error_kind: kind)
      assert_equal Hive::ExitCodes::USAGE, payload["exit_code"]
      assert schemer.valid?(payload),
             "hive-bot-status ErrorPayload arm must accept error_kind=#{kind.inspect} " \
             "(validation errors: #{schemer.validate(payload).map { |e| e['error'] }.inspect})"
    end
  end

  def test_hive_bot_status_error_payload_rejects_unknown_kind
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-bot-status"))))
    payload = {
      "schema" => "hive-bot-status",
      "schema_version" => 1,
      "ok" => false,
      "error_class" => "InvalidTaskPath",
      "error_kind" => "made_up_kind",
      "exit_code" => 64,
      "message" => "nope"
    }
    refute schemer.valid?(payload),
           "schema must reject error_kind values outside the bot usage-error set"
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
      Hive::Schemas::EnrollErrorKind::INTERNAL => Hive::InternalError.new("boom"),
      Hive::Schemas::EnrollErrorKind::WRONG_SUBCOMMAND_FLAG =>
        Hive::Commands::Daemon::UsageError.new(
          "--force only applies to install",
          error_kind: Hive::Schemas::EnrollErrorKind::WRONG_SUBCOMMAND_FLAG
        )
    }
    # Guard against a future enum kind slipping past this per-kind round-trip:
    # every EnrollErrorKind must have a case here (#257 was exactly this gap —
    # WRONG_SUBCOMMAND_FLAG was in the enum and schema but never validated).
    assert_equal Hive::Schemas::EnrollErrorKind::ALL.sort, cases.keys.sort,
                 "every EnrollErrorKind must be exercised by the error-payload round-trip"
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

  # -- hive-patrol ------------------------------------------------------

  def test_hive_patrol_schema_file_exists_and_is_valid_json
    path = Hive::Schemas.schema_path("hive-patrol")
    assert File.exist?(path), "schema file missing: #{path}"

    doc = JSON.parse(File.read(path))
    assert_equal "https://json-schema.org/draft/2020-12/schema", doc["$schema"]
    assert_equal "hive-patrol",
                 doc.dig("$defs", "SuccessPayload", "properties", "schema", "const")
    assert_equal 2,
                 doc.dig("$defs", "SuccessPayload", "properties", "schema_version", "const")
  end

  def test_hive_patrol_success_required_keys_match_producer_emission
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-patrol")))
    schema_required = doc.dig("$defs", "SuccessPayload", "required").sort
    producer_required = %w[
      schema schema_version ok project project_root dry_run features_mapped
      features_review_attempted features_reviewed review_complete review_errors
      findings fix_candidates fixes_attempted fixes_validated prs_opened
      pr_urls review_handoff_errors fix_results skipped_findings last_scanned_sha
    ].sort

    assert_equal producer_required, schema_required,
                 "schema/producer required-key drift in hive-patrol.v1.json"
  end

  def test_hive_patrol_success_payload_validates
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-patrol"))))
    payload = {
      "schema" => "hive-patrol",
      "schema_version" => 2,
      "ok" => true,
      "project" => "demo",
      "project_root" => "/tmp/demo",
      "dry_run" => false,
      "features_mapped" => 1,
      "features_review_attempted" => 1,
      "features_reviewed" => 1,
      "review_complete" => true,
      "review_errors" => [],
      "findings" => 1,
      "fix_candidates" => 1,
      "fixes_attempted" => 1,
      "fixes_validated" => 1,
      "prs_opened" => 1,
      "pr_urls" => [ "https://example.com/pr/1" ],
      "review_handoff_errors" => [
        { "pr_url" => "https://example.com/pr/2", "reason" => "review_handoff_failed" }
      ],
      "fix_results" => [
        {
          "finding_id" => "f1", "patch_id" => "p1", "passed" => true,
          "reason" => "validated", "patch_artifact" => ".hive-state/patrol/patches/p1.json",
          "detail" => nil, "publication_status" => "opened", "publication_reason" => nil,
          "publication_detail" => nil, "pr_url" => "https://example.com/pr/1"
        }
      ],
      "skipped_findings" => [
        { "finding_id" => "f2", "fingerprint" => "fp2", "reason" => "low_confidence" },
        { "finding_id" => "f3", "fingerprint" => "fp3", "reason" => "similar_to_existing" }
      ],
      "last_scanned_sha" => "abc123"
    }

    errors = schemer.validate(payload).map { |e| e["error"] }
    assert_empty errors, "hive-patrol success payload must validate"
  end

  def test_hive_patrol_v2_accepts_every_candidate_selector_skip_reason
    document = JSON.parse(File.read(Hive::Schemas.schema_path("hive-patrol")))
    allowed = document.dig("$defs", "SuccessPayload", "properties", "skipped_findings",
                           "items", "properties", "reason", "enum")
    produced = Hive::Patrol::CandidateSelector::SKIP_REASONS

    assert_equal produced.sort, allowed.sort
  end

  def test_hive_patrol_v2_review_error_kinds_match_reviewer
    document = JSON.parse(File.read(Hive::Schemas.schema_path("hive-patrol")))
    allowed = document.dig("$defs", "SuccessPayload", "properties", "review_errors",
                           "items", "properties", "error", "enum")

    assert_equal Hive::Patrol::Reviewer::REVIEW_ERROR_KINDS.sort, allowed.sort
  end

  def test_hive_patrol_v2_fix_and_publication_reasons_match_producers
    document = JSON.parse(File.read(Hive::Schemas.schema_path("hive-patrol")))
    properties = document.dig("$defs", "SuccessPayload", "properties", "fix_results",
                              "items", "properties")

    assert_equal Hive::Commands::Patrol::FIX_RESULT_REASONS.sort,
                 properties.dig("reason", "enum").sort
    assert_equal Hive::Patrol::PrOpener::RESULT_STATUSES.map(&:to_s).sort,
                 properties.dig("publication_status", "enum").compact.sort
    assert_equal Hive::Patrol::PrOpener::RESULT_REASONS.compact.sort,
                 properties.dig("publication_reason", "enum").compact.sort
  end

  def test_hive_patrol_finding_schema_file_exists_and_accepts_record
    path = Hive::Schemas.schema_path("hive-patrol-finding")
    assert File.exist?(path), "schema file missing: #{path}"

    doc = JSON.parse(File.read(path))
    assert_equal "https://json-schema.org/draft/2020-12/schema", doc["$schema"]

    payload = {
      "id" => "finding-1",
      "feature_id" => "route-home",
      "category" => "bug",
      "severity" => "high",
      "confidence" => "medium",
      "title" => "Nil dereference",
      "description" => "The route calls a nil receiver.",
      "recommendation" => "Guard the receiver before use.",
      "scope" => "cross_feature",
      "contract" => "A missing record must produce a not-found response.",
      "impact" => "A normal request crashes the process instead.",
      "root_cause" => "The shared lookup path assumes records always exist.",
      "reproduction" => "Request a valid route with an unknown record id.",
      "validation" => "Run the focused request regression and full request suite.",
      "alpha_score" => 84,
      "fingerprint" => "fp1",
      "evidence" => [
        { "file" => "app.rb", "line" => 12, "snippet" => "user.name" }
      ]
    }
    errors = JSONSchemer.schema(doc).validate(payload).map { |e| e["error"] }
    assert_empty errors, "durable patrol finding record must validate"

    legacy = payload.reject do |key, _value|
      %w[scope contract impact root_cause reproduction validation alpha_score].include?(key)
    end
    legacy_errors = JSONSchemer.schema(doc).validate(legacy).map { |e| e["error"] }
    assert_empty legacy_errors, "v2 must continue accepting durable records written before alpha scoring"
  end

  def test_hive_patrol_finding_v1_remains_pinned_for_back_compat
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-patrol-finding", version: 1)))
    properties = doc.fetch("properties")

    assert_equal "hive patrol finding record (v1)", doc.fetch("title")
    refute properties.key?("root_cause"), "v1 must not be rewritten with v2 fields"
    refute properties.key?("alpha_score"), "v1 must remain the original closed contract"
  end

  # ── hive-answer-digest ───────────────────────────────────────────────────

  def answer_digest_command(output: StringIO.new)
    Hive::Commands::AnswerDigest.new(json: true, output: output, cfg: {})
  end

  def answer_digest_task
    Hive::Commands::AnswerDigest::Task.new(
      project: "hive", slug: "answer-me-260625-abcd", id: 17, title: "#17 Answer Me",
      stage: "2-brainstorm", pr: "#42"
    )
  end

  def test_hive_answer_digest_schema_file_exists_and_is_valid_json
    path = Hive::Schemas.schema_path("hive-answer-digest")
    assert File.exist?(path), "schema file missing: #{path}"

    doc = JSON.parse(File.read(path))
    assert_equal "https://json-schema.org/draft/2020-12/schema", doc["$schema"]
    assert_equal "hive-answer-digest",
                 doc.dig("$defs", "SuccessPayload", "properties", "schema", "const")
    assert_equal 1,
                 doc.dig("$defs", "SuccessPayload", "properties", "schema_version", "const")
  end

  def test_hive_answer_digest_required_keys_match_producer_emission
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-answer-digest")))
    schema_required = doc.dig("$defs", "SuccessPayload", "required").sort

    # Drive the producer (#json_payload) so an added/dropped/renamed key in the
    # emitted hash fails here against the schema's required set.
    result = Hive::Commands::AnswerDigest::Result.new(
      date: Date.new(2026, 6, 27), message: "", button_count: 0, chat_id: nil,
      reason: "empty", dry_run: false, count: 0, tasks: []
    )
    producer_keys = answer_digest_command.send(:json_payload, result).keys.sort
    assert_equal producer_keys, schema_required,
                 "schema/producer required-key drift in hive-answer-digest SuccessPayload"

    # The Task value object's members must equal the schema Task's required keys.
    task_required = doc.dig("$defs", "Task", "required").sort
    assert_equal Hive::Commands::AnswerDigest::Task.members.map(&:to_s).sort, task_required,
                 "schema/producer required-key drift in hive-answer-digest Task"
  end

  def test_hive_answer_digest_error_kinds_match_producer_emission
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-answer-digest")))
    schema_kinds = doc.dig("$defs", "ErrorPayload", "properties", "error_kind", "enum").sort

    # Producer-routed: every representative error classifies to a schema kind,
    # and the enum mirrors exactly the kinds the producer can emit.
    cmd = answer_digest_command
    representatives = {
      "config" => Hive::ConfigError.new("bad --date"),
      "status_unavailable" => Hive::Commands::AnswerDigest::StatusUnavailableError.new("status down"),
      "usage" => Hive::Commands::AnswerDigest::UsageError.new("bad flag"),
      "internal" => Hive::InternalError.new("boom")
    }
    representatives.each do |expected_kind, error|
      assert_equal expected_kind, cmd.send(:error_kind_for, error),
                   "error_kind_for(#{error.class}) must route to #{expected_kind.inspect}"
    end
    assert_equal representatives.keys.sort, schema_kinds,
                 "schema ErrorPayload.error_kind enum must mirror the producer's routed kinds"
  end

  def test_hive_answer_digest_success_payloads_validate_against_published_schema
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-answer-digest"))))
    cmd = answer_digest_command
    task = answer_digest_task

    empty = Hive::Commands::AnswerDigest::Result.new(
      date: Date.new(2026, 6, 27), message: "", button_count: 0, chat_id: nil,
      reason: "empty", dry_run: false, count: 0, tasks: []
    )
    dry_run = Hive::Commands::AnswerDigest::Result.new(
      date: Date.new(2026, 6, 27), message: "⏳ Waiting on you (1)\n…", button_count: 1,
      chat_id: nil, reason: "dry_run", dry_run: true, count: 1, tasks: [ task ]
    )
    real_send = Hive::Commands::AnswerDigest::Result.new(
      date: Date.new(2026, 6, 27), message: "⏳ Waiting on you (1)\n…", button_count: 1,
      chat_id: 4242, reason: nil, dry_run: false, count: 1, tasks: [ task ]
    )

    { "empty" => empty, "dry_run" => dry_run, "real_send" => real_send }.each do |label, result|
      # Validate the JSON WIRE form a consumer sees (string keys throughout),
      # not the Ruby hash whose task entries carry symbol keys.
      payload = JSON.parse(JSON.generate(cmd.send(:json_payload, result)))
      errors = schemer.validate(payload).map { |e| e["error"] }
      assert_empty errors,
                   "hive-answer-digest #{label} SuccessPayload (populated tasks where applicable) " \
                   "must validate (errors: #{errors.inspect})"
    end

    # Pin the real-send shape: a populated task plus a null message (the text
    # went to Telegram), so a schema tightening or a nil→"" drift fails here.
    real_payload = JSON.parse(JSON.generate(cmd.send(:json_payload, real_send)))
    assert_nil real_payload["message"], "message is null on a real send"
    assert_equal 1, real_payload["tasks"].length
    assert_equal "#42", real_payload.dig("tasks", 0, "pr")
  end

  def test_hive_answer_digest_error_payload_validates_for_every_kind
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-answer-digest"))))
    {
      "config" => Hive::ConfigError.new("bad --date"),
      "status_unavailable" => Hive::Commands::AnswerDigest::StatusUnavailableError.new("status down"),
      "usage" => Hive::Commands::AnswerDigest::UsageError.new("bad flag"),
      "internal" => Hive::InternalError.new("boom")
    }.each do |kind, error|
      out = StringIO.new
      answer_digest_command(output: out).send(:emit_error_envelope, error)
      payload = JSON.parse(out.string)
      assert_equal kind, payload.fetch("error_kind")
      validation = schemer.validate(payload).map { |e| e["error"] }
      assert_empty validation,
                   "hive-answer-digest ErrorPayload (#{kind}, exit #{payload['exit_code']}) " \
                   "must validate (errors: #{validation.inspect})"
    end
  end

  def test_hive_answer_digest_error_payload_rejects_unknown_kind
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-answer-digest"))))
    payload = {
      "schema" => "hive-answer-digest", "schema_version" => 1, "ok" => false,
      "error_class" => "MysteryError", "error_kind" => "made_up_kind",
      "exit_code" => 70, "message" => "nope"
    }
    refute schemer.valid?(payload),
           "schema must reject error_kind values outside the closed enum"
  end

  # ── schema metadata identity ─────────────────────────────────────────────

  # Copy-pasting vN.json to vN+1.json and only changing the version const is
  # exactly how hive-drop.v2.json shipped with a v1 $id and title. For every
  # current schema, the filename, $id basename, and any "(vN)" suffix in the
  # title must agree with SCHEMA_VERSIONS.
  def test_schema_file_identity_matches_schema_versions
    Hive::Schemas::SCHEMA_VERSIONS.each do |name, version|
      path = Hive::Schemas.schema_path(name)
      doc = JSON.parse(File.read(path))
      expected_basename = "#{name}.v#{version}.json"
      id = doc["$id"].to_s
      if id.start_with?("urn:")
        # The status/run/diagnose family ids are URNs: urn:hive:schema:<short>:vN.
        assert id.end_with?(":v#{version}"),
               "#{expected_basename}: URN $id (#{id}) must end with :v#{version}"
      else
        assert_equal expected_basename, File.basename(id),
                     "#{expected_basename}: $id basename must match the filename"
      end
      if (m = doc["title"].to_s.match(/\(v(\d+)\)/))
        assert_equal version, Integer(m[1]),
                     "#{expected_basename}: title version suffix must match SCHEMA_VERSIONS"
      end
    end
  end

  def test_internal_attempt_schema_pins_state_and_receipt_contract
    path = Hive::Schemas.schema_path("hive-attempt")
    doc = JSON.parse(File.read(path))

    assert_equal 1, doc.fetch("properties").dig("schema_version", "const")
    assert_equal %w[launching running terminal lost], doc.fetch("properties").dig("state", "enum")
    receipt_required = doc.dig("$defs", "Receipt", "required")
    %w[attempt_id task_generation outcome exit_status started_at ended_at final_checkpoint output_references log_reference].each do |key|
      assert_includes receipt_required, key
    end
  end

  def test_refactor_patrol_retains_v1_while_v2_is_current
    assert_equal 2, Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-refactor-patrol")

    v1 = JSON.parse(File.read(Hive::Schemas.schema_path("hive-refactor-patrol", version: 1)))
    v2 = JSON.parse(File.read(Hive::Schemas.schema_path("hive-refactor-patrol", version: 2)))
    assert_equal 1, v1.dig("$defs", "SuccessPayload", "properties", "schema_version", "const")
    assert_equal 2, v2.dig("$defs", "SuccessPayload", "properties", "schema_version", "const")
  end

  def test_refactor_patrol_v2_requires_a_complete_immutable_thesis_snapshot
    document = JSON.parse(File.read(Hive::Schemas.schema_path("hive-refactor-patrol", version: 2)))
    snapshot_schema = JSONSchemer.schema(
      { "$ref" => "#/$defs/ThesisSnapshot", "$defs" => document.fetch("$defs") }
    )

    incomplete = {
      "id" => "thesis-1", "feature_id" => "checkout", "fingerprint" => "fp-1"
    }
    refute snapshot_schema.valid?(incomplete)

    required = document.dig("$defs", "ThesisSnapshot", "required")
    assert_includes required, "problem"
    assert_includes required, "expected_leverage"
    assert_includes required, "required_validation"
    assert_includes required, "admissible"
  end

  # The standalone thesis schema is the normalizer gate; the report envelope
  # embeds the same shape as ThesisSnapshot. Their non-empty narrative-field
  # contracts must stay in lockstep or an agent thesis with an empty `problem`
  # would pass the normalizer and then poison the whole discovery envelope.
  def test_refactor_patrol_thesis_narrative_min_lengths_match_the_envelope_snapshot
    thesis = JSON.parse(File.read(Hive::Schemas.schema_path("hive-refactor-patrol-thesis", version: 2)))
    envelope = JSON.parse(File.read(Hive::Schemas.schema_path("hive-refactor-patrol", version: 2)))

    %w[problem cost proposed_refactor].each do |field|
      assert_equal 1, thesis.dig("properties", field, "minLength"),
                   "#{field}: the thesis schema must reject empty strings at the normalizer gate"
      assert_equal thesis.dig("properties", field, "minLength"),
                   envelope.dig("$defs", "ThesisSnapshot", "properties", field, "minLength"),
                   "#{field}: thesis schema and envelope ThesisSnapshot must agree"
    end
  end

  def test_refactor_patrol_v2_pins_complete_source_and_action_identity
    document = JSON.parse(File.read(Hive::Schemas.schema_path("hive-refactor-patrol", version: 2)))

    source_required = document.dig("$defs", "SourcePr", "required")
    assert_includes source_required, "registration"
    assert_includes source_required, "changed_paths"
    assert_includes source_required, "manifest_checksum"

    action_required = document.dig("$defs", "Action", "required")
    assert_includes action_required, "canonical_action_id"
    assert_includes action_required, "thesis_fingerprint"
    assert_includes action_required, "owner_job_id"
  end

  # ── hive-dispatch-request: claimed-file contract (#247) ─────────────────

  # A `<id>.json.claimed` file still self-declares schema=hive-dispatch-request
  # /schema_version=1. The sidecar design (claim metadata in a separate
  # `.claim` file) keeps the claimed JSON byte-identical to the original
  # request, so it must still validate against the strict
  # additionalProperties:false schema — no stray `claim` key.
  def test_hive_dispatch_request_claimed_file_stays_schema_valid
    q = Hive::Daemon::DispatchRequestQueue
    Dir.mktmpdir("hive-dispatch-queue") do |dir|
      q.write_request!(project: "hive", slug: "my-task",
                       argv: [ "hive", "review", "my-task", "--json" ],
                       request_id: "abc12345", state_home: dir,
                       now: Time.utc(2026, 6, 3, 12, 0, 0))
      claimed = q.claim("abc12345", pid: 4321, state_home: dir,
                        now: Time.utc(2026, 6, 3, 12, 0, 1))
      payload = JSON.parse(File.read(claimed))
      schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-dispatch-request"))))
      assert_empty schemer.validate(payload).to_a,
                   "claimed request JSON must remain a valid hive-dispatch-request (no extra `claim` key)"
    end
  end

  # ── hive-dispatch-result (#256, #258) ───────────────────────────────────

  def test_hive_dispatch_result_schema_file_exists_and_is_valid_json
    path = Hive::Schemas.schema_path("hive-dispatch-result")
    assert File.exist?(path), "schema file missing: #{path}"

    doc = JSON.parse(File.read(path))
    assert_equal "https://json-schema.org/draft/2020-12/schema", doc["$schema"]
    assert_equal "hive-dispatch-result", doc.dig("properties", "schema", "const")
    assert_equal 2, doc.dig("properties", "schema_version", "const")
  end

  def test_hive_dispatch_result_required_keys_match_producer
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-dispatch-result")))
    schema_required = doc["required"].sort
    # Mirrors Hive::Daemon::DispatchResultQueue.write! — every emitted key
    # except the optional/nullable update_id is required.
    producer_required = %w[
      schema schema_version result_id created_at chat_id project slug
      request_id exit_code command attempt_id attempt_state receipt
    ].sort
    assert_equal producer_required, schema_required,
                 "schema/producer required-key drift in hive-dispatch-result.v1.json"
  end

  def test_hive_dispatch_result_producer_round_trip_validates
    Dir.mktmpdir("hive-dispatch-result") do |dir|
      # Actual producer output, with a nil update_id and a negative
      # (group/supergroup) chat_id — both must validate.
      Hive::Daemon::DispatchResultQueue.write!(
        chat_id: -1001234567890, project: "hive", slug: "my-task",
        request_id: "abc12345", exit_code: 1, command: "hive review my-task --json",
        update_id: nil, state_home: dir, now: Time.utc(2026, 6, 3, 12, 0, 0)
      )
      written = Dir.glob(File.join(dir, "dispatch_results", "*.json")).first
      payload = JSON.parse(File.read(written))
      schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-dispatch-result"))))
      assert_empty schemer.validate(payload).to_a,
                   "DispatchResultQueue.write! output (nil update_id, negative chat_id) must validate"
    end
  end

  # #258: chat_id is machine-checked as non-zero — 0 is the only id no
  # Telegram chat ever has; private chats are positive, groups negative.
  def test_hive_dispatch_result_chat_id_must_be_non_zero
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-dispatch-result"))))
    base = {
      "schema" => "hive-dispatch-result", "schema_version" => 2,
      "result_id" => "abc12345", "created_at" => "2026-06-03T12:00:00Z",
      "project" => "hive", "slug" => "my-task", "request_id" => "req00001",
      "exit_code" => 1, "command" => "hive review my-task",
      "attempt_id" => nil, "attempt_state" => nil, "receipt" => nil
    }
    assert schemer.valid?(base.merge("chat_id" => 12_345)), "positive private chat id validates"
    assert schemer.valid?(base.merge("chat_id" => -1_001_234_567_890)), "negative group chat id validates"
    refute schemer.valid?(base.merge("chat_id" => 0)), "chat_id 0 must be rejected (#258)"
  end

  # ── hive-daemon-queue: producer round-trip (#256) ───────────────────────

  def test_hive_daemon_queue_producer_round_trip_validates_list_show_prune
    # queue_request_hash / queue_envelope were extracted from Commands::Daemon
    # into QueueCommand (#254); exercise them on the extracted class.
    require "hive/commands/daemon/queue_command"
    queue_cmd = Hive::Commands::Daemon::QueueCommand.new(
      queue_args: [ "list" ], json: false, hive_home: Dir.mktmpdir
    )
    req = Hive::Daemon::DispatchRequestQueue::Request.new(
      request_id: "req00001", created_at: Time.utc(2026, 6, 3, 12, 0, 0),
      project: "hive", slug: "my-task", argv: [ "hive", "review", "my-task", "--json" ],
      requestor: "bot", chat_id: 12_345, update_id: nil, trigger: "autofix", path: nil
    )
    request_hash = queue_cmd.send(:queue_request_hash, req)
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-daemon-queue"))))

    list = queue_cmd.send(:queue_envelope, action: "list", requests: [ request_hash ], malformed: [])
    assert_empty schemer.validate(list).to_a,
                 "list envelope (Request with nil update_id) must validate against SuccessPayload"

    show = queue_cmd.send(:queue_envelope, action: "show", request: request_hash)
    assert_empty schemer.validate(show).to_a, "show envelope must validate"

    prune = queue_cmd.send(:queue_envelope, action: "prune", pruned_count: 1,
                                            requests: [ request_hash ], malformed: [])
    assert_empty schemer.validate(prune).to_a, "prune envelope must validate"
  end
end
