require "test_helper"
require "json_schemer"
require "hive/task_workspace/builder"

class TaskWorkspaceBuilderTest < Minitest::Test
  include HiveTestHelper

  SECRET = "workspace-builder-cursor-secret-at-least-thirty-two-bytes".freeze
  NativeTask = Data.define(:folder, :project_root, :slug, :id)

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
        JSON.parse(File.read(Hive::Schemas.schema_path("hive-task-workspace")))
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

  def test_partial_projection_evidence_disables_actions_even_with_a_fresh_status_feed
    with_fixture do |native, task|
      snapshot = builder(
        native, task, questions: 1, projection_state: "partial",
        projection_diagnostics: [
          { "source" => "task_projection", "reason" => "checkpoint_invalid",
            "message" => "bounded projection is invalid", "details" => {} }
        ]
      ).call

      assert_equal "partial", snapshot.dig("status", "state")
      assert_equal "investigate", snapshot.dig("decision", "posture")
      refute snapshot.dig("decision", "action", "enabled")
    end
  end

  def test_truncated_projection_evidence_disables_actions_even_when_marked_current
    with_fixture do |native, task|
      snapshot = builder(native, task, questions: 1, projection_truncated: true).call

      assert_equal "partial", snapshot.dig("status", "state")
      assert_equal "investigate", snapshot.dig("decision", "posture")
      refute snapshot.dig("decision", "action", "enabled")
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

  private

  def with_fixture(artifact: "# Artifact\n", material_events: 1)
    with_tmp_dir do |root|
      task_root = File.join(root, "task")
      FileUtils.mkdir_p(task_root)
      native = NativeTask.new(task_root, root, "task-260812-abcd", 42)
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
      yield native, task
    ensure
      @material_events = nil
    end
  end

  def builder(native, task, questions:, limits: Hive::TaskWorkspace::Limits.new,
              status_availability: "fresh", status_error: nil,
              projection_state: "current", projection_diagnostics: [],
              projection_truncated: false)
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
      "accepted_at" => "2026-08-12T12:00:00Z"
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
      usage_reader: ->(**) { { available: false } },
      current_context_observation: {
        "observed_at" => "2026-08-12T12:00:00Z",
        "repository" => nil, "wiki" => nil
      },
      questions_count: questions, daemon_enabled: true,
      clock: -> { Time.utc(2026, 8, 12, 12) }
    )
  end
end
