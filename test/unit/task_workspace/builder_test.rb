require "test_helper"
require "json_schemer"
require "hive/task_workspace/builder"

class TaskWorkspaceBuilderTest < Minitest::Test
  include HiveTestHelper

  SECRET = "workspace-builder-cursor-secret-at-least-thirty-two-bytes".freeze
  NativeTask = Data.define(:folder, :project_root, :slug, :id, :workflow)

  class WebTask
    def initialize(attributes, artifact_panel:, publication_panel:)
      @attributes = attributes
      @artifact_panel = artifact_panel
      @publication_panel = publication_panel
    end

    def [](key) = @attributes[key]
    def artifact_panel = @artifact_panel
    def publication(cache: nil) = @publication_panel
    def passable? = @attributes["passable"] == true
    def recovery_action_visible? = @attributes["recovery_visible"] == true
    def recovery_action_enabled? = @attributes["recovery_enabled"] == true
    def recovery = @attributes["recovery"]
    def recovery_primary_label = @attributes["recovery_label"]
    def recovery_context = Array(@attributes["recovery_context"])
    def dispatch_action = @attributes["dispatch_action"]
  end

  Store = Struct.new(:records) do
    def fetch(id) = records[id]
    def scan = raise("workspace attempted a global attempt scan")
  end

  def test_builds_one_schema_valid_snapshot_and_projects_answer_posture
    with_fixture do |native, task|
      snapshot = builder(native, task, questions: 2).call
      schemer = JSONSchemer.schema(
        JSON.parse(File.read(Hive::Schemas.schema_path("hive-task-workspace", version: 1)))
      )

      assert_empty schemer.validate(snapshot).to_a
      assert_equal "answer", snapshot.dig("decision", "posture")
      assert snapshot.dig("decision", "action", "enabled")
      assert_equal "hive-task-workspace", snapshot.fetch("schema")
      assert_equal "current", snapshot.dig("status", "state")
      assert_equal "attempt-1", snapshot.dig("panels", "attempts", "current_attempt_id")
      assert_equal "stage_transition", snapshot.dig("panels", "timeline", "records", 0, "kind")
    end
  end

  def test_stale_status_disables_the_sanitized_action_and_never_exposes_command_or_token
    with_fixture do |native, task|
      snapshot = builder(
        native, task, questions: 1, status_availability: "degraded",
        status_error: "/private/config.yml failed"
      ).call

      assert_equal "investigate", snapshot.dig("decision", "posture")
      refute snapshot.dig("decision", "action", "enabled")
      refute_includes snapshot.to_s, "/private/config.yml"
      refute snapshot.to_s.include?("suggested_command")
      refute snapshot.to_s.include?("observation_token")
    end
  end

  def test_partial_projection_evidence_preserves_bound_answer_action_with_a_fresh_status_feed
    with_fixture do |native, task|
      snapshot = builder(
        native, task, questions: 1, projection_state: "partial",
        projection_diagnostics: [
          { "source" => "task_projection", "reason" => "checkpoint_invalid",
            "message" => "bounded projection is invalid", "details" => {} }
        ]
      ).call

      assert_equal "partial", snapshot.dig("status", "state")
      assert_equal "answer", snapshot.dig("decision", "posture")
      assert snapshot.dig("decision", "action", "enabled")
    end
  end

  def test_truncated_projection_evidence_preserves_bound_answer_action
    with_fixture do |native, task|
      snapshot = builder(native, task, questions: 1, projection_truncated: true).call

      assert_equal "partial", snapshot.dig("status", "state")
      assert_equal "answer", snapshot.dig("decision", "posture")
      assert snapshot.dig("decision", "action", "enabled")
    end
  end

  def test_attempt_or_resource_integrity_degradation_preserves_bound_answer_action
    with_fixture do |native, task|
      snapshot = builder(native, task, questions: 1, usage_available: false).call

      assert_equal "partial", snapshot.dig("panels", "resources", "state")
      assert_equal "answer", snapshot.dig("decision", "posture")
      assert snapshot.dig("decision", "action", "enabled")
    end
  end

  def test_partial_projection_evidence_still_disables_non_answer_actions
    with_fixture do |native, task|
      snapshot = builder(native, task, questions: 0, projection_state: "partial").call

      assert_equal "partial", snapshot.dig("status", "state")
      assert_equal "investigate", snapshot.dig("decision", "posture")
      refute snapshot.dig("decision", "action", "enabled")
    end
  end

  def test_partial_projection_does_not_enable_an_unbound_question
    with_fixture do |native, task|
      malformed_question = {
        "n" => 1, "text" => "Scope?", "binding" => "", "ordinal" => 0
      }
      snapshot = builder(
        native, task, questions: 1, questions_payload: [ malformed_question ],
        projection_state: "partial"
      ).call

      assert_empty snapshot.dig("operator", "questions")
      assert_equal "investigate", snapshot.dig("decision", "posture")
      refute snapshot.dig("decision", "action", "enabled")
    end
  end

  def test_operator_questions_recovery_and_diagnostic_are_normalized_in_the_snapshot
    with_fixture do |native, task|
      attributes = task.instance_variable_get(:@attributes)
      attributes["recovery_visible"] = true
      attributes["recovery_enabled"] = true
      attributes["diagnostic"] = { "summary" => "failed at /home/operator/task" }
      question = Struct.new(:n, :text, :binding, :ordinal).new(
        1, "Where?", "binding-1", 0
      )

      snapshot = builder(
        native, task, questions: 1, questions_payload: [ question ]
      ).call

      assert_equal "Where?", snapshot.dig("operator", "questions", 0, "text")
      assert snapshot.dig("operator", "recovery", "action_visible")
      assert_nil snapshot.dig("operator", "recovery", "status")
      assert_equal "failed at [REDACTED:path]", snapshot.dig("operator", "diagnostic_summary")
    end
  end

  def test_timeline_cursor_uses_the_same_bounded_sources
    with_fixture(material_events: 3) do |native, task|
      limits = Hive::TaskWorkspace::Limits.new(timeline_material_items: 1)
      subject = builder(native, task, questions: 0, limits: limits)

      first = subject.timeline
      second = subject.timeline(cursor: first.fetch("older_cursor"))

      refute_nil first.fetch("older_cursor")
      refute_equal first.dig("records", 0, "event_id"),
                   second.dig("records", 0, "event_id")
    end
  end

  def test_workspace_total_cap_degrades_only_the_oversized_panel
    with_fixture(artifact: "a" * 400_000) do |native, task|
      snapshot = builder(
        native, task, questions: 0,
        limits: Hive::TaskWorkspace::Limits.new(workspace_bytes: 300_000)
      ).call

      assert_equal "partial", snapshot.dig("panels", "artifacts", "state")
      assert_nil snapshot.dig("panels", "artifacts", "records", 0, "content")
      assert_equal "missing", snapshot.dig("panels", "attempts", "state") if
        snapshot.dig("panels", "attempts", "records").empty?
      assert_operator JSON.generate(snapshot).bytesize, :<=, 300_000
    end
  end

  def test_decision_postures_follow_canonical_answer_approve_retry_wait_and_investigate_precedence
    with_fixture do |native, task|
      attributes = task.instance_variable_get(:@attributes)

      assert_equal "answer", builder(native, task, questions: 1).call.dig("decision", "posture")

      attributes["passable"] = true
      assert_equal "approve", builder(native, task, questions: 0).call.dig("decision", "posture")

      attributes["passable"] = false
      attributes["recovery_visible"] = true
      attributes["recovery_enabled"] = true
      assert_equal "retry", builder(native, task, questions: 0).call.dig("decision", "posture")

      attributes["recovery_visible"] = false
      attributes["recovery_enabled"] = false
      attributes["action"] = "agent_running"
      assert_equal "wait", builder(native, task, questions: 0).call.dig("decision", "posture")

      attributes["action"] = nil
      assert_equal "investigate", builder(native, task, questions: 0).call.dig("decision", "posture")
    end
  end

  def test_semantic_v2_keeps_action_authority_independent_from_usage_and_omits_coding_audit_noise
    with_fixture do |native, task|
      task.instance_variable_get(:@attributes)["worktree_path"] = "/derived/not-observed"
      snapshot = builder(native, task, questions: 0, usage_available: false).semantic

      assert_equal 2, snapshot.fetch("schema_version")
      assert_equal "document", snapshot.dig("result", "kind")
      assert_equal "artifact.md", snapshot.dig("result", "primary", "reference")
      assert_equal "unavailable", snapshot.dig("usage", "coverage")
      assert snapshot.dig("action", "enabled"),
             "optional usage loss must not disable a fresh canonical task action"
      refute snapshot.dig("applicability", "worktree")
      refute snapshot.dig("applicability", "publication")
      refute_includes snapshot.to_s, "/derived/not-observed"
      refute snapshot.key?("panels")
      refute_includes snapshot.to_s, "attempt-1"
      refute_includes snapshot.to_s, "stage_transition"
    end
  end

  def test_semantic_v2_uses_the_exact_attempt_receipt_log_reference
    reference = {
      "path" => "logs/attempt-1.frames", "size" => 17, "sha256" => "a" * 64
    }
    with_fixture(log_reference: reference) do |native, task|
      attributes = task.instance_variable_get(:@attributes)
      attributes["action"] = "recover_execute"
      attributes["action_label"] = "Needs recovery"
      attributes["diagnostic"] = { "summary" => "Execution failed" }

      snapshot = builder(native, task, questions: 0).semantic

      assert_equal "receipt_correlated", snapshot.dig("diagnostic", "log", "quality")
      assert_equal reference, snapshot.dig("diagnostic", "log", "reference")
      refute_includes snapshot.to_s, "newer-unrelated.log"
      refute snapshot.to_s.include?("provider_reported_cost")
    end
  end

  def test_semantic_v2_does_not_complete_an_active_terminal_agent_stage
    with_fixture do |native, task|
      native.workflow.stages = [
        Hive::Workflow::Stage.new(
          name: "done", index: 6, state_file: "artifact.md", kind: :agent
        )
      ]
      attributes = task.instance_variable_get(:@attributes)
      attributes["stage"] = "6-done"
      attributes["action"] = Hive::Schemas::TaskActionKind::AGENT_RUNNING
      attributes["action_label"] = "Agent running"

      active = builder(native, task, questions: 0).semantic
      refute_equal "completed", active.dig("headline", "state")
      refute active.dig("task", "archived")

      attributes["action"] = Hive::Schemas::TaskActionKind::ARCHIVED
      attributes["action_label"] = "Archived"
      completed = builder(native, task, questions: 0).semantic
      assert_equal "completed", completed.dig("headline", "state")
      assert completed.dig("task", "archived")
      refute completed.dig("action", "enabled")
    end
  end

  def test_semantic_v2_compacts_supporting_content_before_exceeding_its_document_budget
    with_fixture(artifact: "# Primary\n#{"p" * 6_000}") do |native, task|
      task.instance_variable_get(:@artifact_panel).fetch("records") << {
        "name" => "notes.md", "reference" => "notes.md",
        "content" => "n" * 12_000, "bytes" => 12_000,
        "truncated" => false, "invalid_encoding" => false,
        "binary" => false, "diagnostics" => []
      }

      snapshot = builder(
        native, task, questions: 0,
        limits: Hive::TaskWorkspace::Limits.new(workspace_bytes: 16_000)
      ).semantic

      assert_nil snapshot.dig("result", "supporting", 0, "content")
      assert snapshot.dig("result", "supporting", 0, "truncated")
      assert_match(/Primary/, snapshot.dig("result", "primary", "content"))
    end
  end

  def test_semantic_v2_projects_coding_capabilities_without_workflow_id_branching
    result = Hive::Workflow::Result.new(
      kind: :change,
      capabilities: %i[worktree diff publication media dependencies supporting_artifacts]
    )
    with_fixture(result: result) do |native, task|
      snapshot = builder(native, task, questions: 0).semantic

      assert_equal "change", snapshot.dig("result", "kind")
      assert snapshot.dig("applicability", "worktree")
      assert snapshot.dig("applicability", "diff")
      assert snapshot.dig("applicability", "publication")
      assert snapshot.dig("applicability", "media")
      assert snapshot.dig("applicability", "dependencies")
    end
  end

  def test_semantic_v2_fails_actions_closed_on_stale_authority_but_not_missing_usage
    with_fixture do |native, task|
      fresh = builder(native, task, questions: 0, usage_available: false).semantic
      stale = builder(
        native, task, questions: 0, usage_available: false,
        status_availability: "degraded"
      ).semantic

      assert fresh.dig("action", "enabled")
      refute stale.dig("action", "enabled")
      assert_equal "unavailable", stale.dig("usage", "coverage")
    end
  end

  def test_semantic_v2_warns_when_a_completed_document_is_missing_its_declared_primary
    result = Hive::Workflow::Result.new(
      kind: :document, primary_artifact: "final.md",
      capabilities: [ :supporting_artifacts ]
    )
    with_fixture(result: result) do |native, task|
      attributes = task.instance_variable_get(:@attributes)
      attributes["action"] = Hive::Schemas::TaskActionKind::ARCHIVED
      attributes["action_label"] = "Archived"

      snapshot = builder(native, task, questions: 0).semantic

      assert_equal "artifact.md", snapshot.dig("result", "primary", "reference")
      assert_match(/final\.md.*unavailable/, snapshot.dig("result", "warning"))
      assert_equal "completed", snapshot.dig("headline", "state")
    end
  end

  private

  def with_fixture(artifact: "# Artifact\n", material_events: 1, log_reference: nil,
                   result: nil)
    with_tmp_dir do |root|
      task_root = File.join(root, "task")
      FileUtils.mkdir_p(task_root)
      workflow = Struct.new(:result, :stages).new(
        result || Hive::Workflow::Result.new(
          kind: :document, primary_artifact: "artifact.md",
          capabilities: [ :supporting_artifacts ]
        ),
        []
      )
      native = NativeTask.new(task_root, root, "task-260812-abcd", 42, workflow)
      task = WebTask.new(
        {
          "slug" => native.slug, "id" => 42, "stage" => "4-execute",
          "marker" => "agent_working", "attrs" => {},
          "action" => "needs_input", "action_label" => "Answer questions",
          "observation_mtime" => "2026-08-12T12:00:00Z"
        },
        artifact_panel: {
          "state" => "current",
          "records" => [
            {
              "name" => "artifact.md", "reference" => "artifact.md",
              "content" => artifact, "bytes" => artifact.bytesize,
              "truncated" => false, "invalid_encoding" => false,
              "binary" => false, "diagnostics" => []
            }
          ],
          "diagnostics" => [], "truncated" => false
        },
        publication_panel: Hive::TaskWorkspace.unavailable_panel("publication")
      )
      @material_events = material_events
      @log_reference = log_reference
      yield native, task
    ensure
      @material_events = nil
      @log_reference = nil
    end
  end

  def builder(native, task, questions:, limits: Hive::TaskWorkspace::Limits.new,
              status_availability: "fresh", status_error: nil,
              projection_state: "current", projection_diagnostics: [],
              projection_truncated: false, usage_available: true, questions_payload: nil)
    questions_payload ||= Array.new(questions) do |index|
      {
        "n" => index + 1, "text" => "Question #{index + 1}?",
        "binding" => "binding-#{index + 1}", "ordinal" => index
      }
    end
    events = Array.new(@material_events || 1) do |index|
      {
        "schema" => "hive-task-journal-event", "schema_version" => 1,
        "event_id" => "event-#{index}", "event_type" => "activity_recorded",
        "occurred_at" => (Time.utc(2026, 8, 12, 12) + index).iso8601,
        "observed_at" => (Time.utc(2026, 8, 12, 12) + index).iso8601,
        "stage" => "4-execute", "attempt_id" => "attempt-1",
        "task_generation" => 3, "reason" => "Stage transition",
        "provenance" => { "source" => "stage_service" },
        "payload" => {
          "activity_kind" => "stage_transition", "operation_id" => "op-#{index}",
          "correlation_id" => "correlation-#{index}"
        }
      }
    end
    projection = {
      "identity" => { "attempt_id" => "attempt-1", "task_generation" => 3 },
      "journal" => {
        "attempts" => [
          {
            "attempt_id" => "attempt-1", "predecessor_attempt_id" => nil,
            "stage" => "4-execute", "task_generation" => 3
          }
        ]
      }
    }
    read = Hive::TaskWorkspace::Builder::ProjectionRead.new(
      projection: projection, state: projection_state,
      diagnostics: projection_diagnostics,
      truncated: projection_truncated, journal_cursor: 0, journal_records: events
    )
    attempt = {
      "attempt_id" => "attempt-1", "project" => "demo",
      "task_slug" => native.slug, "task_id" => native.id,
      "intended_stage" => "4-execute", "task_input_epoch" => 3,
      "ownership_generation" => "owner-3", "provider" => "codex",
      "state" => "running", "outcome" => nil,
      "accepted_at" => "2026-08-12T12:00:00Z",
      "log_reference" => @log_reference,
      "receipt" => @log_reference && { "log_reference" => @log_reference }
    }
    Hive::TaskWorkspace::Builder.new(
      task: task, native_task: native, project: "demo",
      status_availability: status_availability, status_error: status_error,
      cursor_codec: Hive::TaskWorkspace::Timeline::CursorCodec.new(secret: SECRET),
      limits: limits, attempt_store: Store.new({ "attempt-1" => attempt }),
      projection_read: read,
      event_reader: Struct.new(:value) do
        def call
          Hive::TaskWorkspace::JsonlReader::Result.new(
            records: [], diagnostics: [], truncated: false,
            observed_bytes: 0, observed_records: 0, window_start: 0, window_end: 0
          )
        end
      end.new(nil),
      usage_reader: ->(**) { { available: usage_available, sessions: [], unattributed_count: 0 } },
      current_context_observation: {
        "observed_at" => "2026-08-12T12:00:00Z",
        "repository" => nil, "wiki" => nil
      },
      questions: questions_payload, daemon_enabled: true,
      clock: -> { Time.utc(2026, 8, 12, 12) }
    )
  end
end
