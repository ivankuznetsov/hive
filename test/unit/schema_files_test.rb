require "test_helper"
require "json"
require "json_schemer"
require "hive/commands/approve"
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
  # pinned to the pre-5-review release. Loading by explicit version: must
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
    refute_includes v1_dirs, "5-review",
                    "v1 enum must NOT include the v2-introduced 5-review stage"
  end

  def test_hive_approve_v2_includes_review_stage
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-approve")))
    v2_dirs = doc.dig("$defs", "SuccessPayload", "properties", "from_stage_dir", "enum")
    assert_includes v2_dirs, "5-review", "v2 introduces the 5-review stage"
    assert_includes v2_dirs, "6-pr"
    assert_includes v2_dirs, "7-done"
    refute_includes v2_dirs, "5-pr", "v2 retires the legacy 5-pr enum value"
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
    assert_equal 1,
                 doc.dig("$defs", "SuccessPayload", "properties", "schema_version", "const")
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
      suggested_command: "hive brainstorm probe --from 1-inbox"
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

  # ── hive-run ───────────────────────────────────────────────────────────

  def test_hive_run_schema_file_exists_and_is_valid_json
    path = Hive::Schemas.schema_path("hive-run")
    assert File.exist?(path), "schema file missing: #{path}"

    doc = JSON.parse(File.read(path))
    assert_equal "https://json-schema.org/draft/2020-12/schema", doc["$schema"]
    assert_equal "hive-run",
                 doc.dig("$defs", "SuccessPayload", "properties", "schema", "const")
    assert_equal 1,
                 doc.dig("$defs", "SuccessPayload", "properties", "schema_version", "const")
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
                 "schema/producer required-key drift in hive-run.v1.json"
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
end
