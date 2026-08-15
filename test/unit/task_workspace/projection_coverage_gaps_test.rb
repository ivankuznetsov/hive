require "test_helper"
require "hive/task_workspace/provenance"
require "hive/task_workspace/timeline"

class TaskWorkspaceProjectionCoverageGapsTest < Minitest::Test
  include HiveTestHelper

  SECRET = "workspace-projection-coverage-secret-32-bytes".freeze
  NOW = "2026-08-12T12:00:00Z"
  Task = Data.define(:folder, :slug, :id)

  class RaisingValue
    def to_h
      raise "invalid value"
    end
  end

  class Reader
    attr_writer :result

    def initialize(result = nil, error: nil)
      @result = result
      @error = error
    end

    def read(*)
      raise @error if @error

      @result
    end
  end

  def test_timeline_fail_soft_normalization_and_legacy_projection
    refute Hive::TaskWorkspace::Timeline.material_record?(RaisingValue.new)

    codec = Hive::TaskWorkspace::Timeline::CursorCodec.new(secret: SECRET)
    encoded = Base64.urlsafe_encode64("not-json", padding: false)
    signature = OpenSSL::HMAC.hexdigest("SHA256", SECRET, encoded)
    assert_raises(Hive::TaskWorkspace::Timeline::InvalidCursor) do
      codec.decode("#{encoded}.#{signature}")
    end

    projector = Hive::TaskWorkspace::Timeline.new(
      task_identity: { project: "demo", slug: "task" },
      journal_records: [
        { "event_type" => "activity_recorded", "occurred_at" => NOW,
          "payload" => { "activity_kind" => "unknown" } },
        RaisingValue.new
      ],
      event_records: [ RaisingValue.new ],
      legacy_records: [
        { "kind" => "legacy_note", "observed_at" => NOW },
        { "kind" => "legacy_note", "observed_at" => "bad" }
      ], cursor_codec: codec
    )
    assert_kind_of Time, projector.instance_variable_get(:@clock).call
    panel = projector.call

    assert_equal "partial", panel.fetch("state")
    assert_equal "legacy", panel.dig("records", 0, "source")
    assert_operator panel.fetch("diagnostics").length, :>=, 4
  end

  def test_timeline_noise_byte_cap_and_safe_value_helpers
    projector = timeline(
      events: [ { "event_id" => "noise", "event_type" => "heartbeat", "ts" => NOW,
                  "details" => "x" * 200 } ],
      limits: Hive::TaskWorkspace::Limits.new(timeline_bytes: 1)
    )
    panel = projector.call
    assert panel.fetch("truncated")
    assert_empty panel.fetch("noise_groups")

    details = projector.send(
      :safe_details,
      "session_id" => "/private/path", "timeout_sec" => Float::INFINITY,
      "timed_out" => false, "ignored" => "value"
    )
    assert_equal "[REDACTED:path]", details.fetch("session_id")
    assert_equal false, details.fetch("timed_out")
    refute details.key?("timeout_sec")
    refute projector.send(:finite_numeric?, Object.new)
    assert_match(/event-.*[0-9a-f]{16}/,
                 projector.send(:safe_identifier, "bad id", prefix: "event"))
  end

  def test_provenance_projects_current_receipts_and_invalid_bindings
    with_tmp_dir do |root|
      task = Task.new(root, "task", 42)
      reader = Reader.new
      subject = provenance(task, reader: reader)
      assert_kind_of Time, subject.instance_variable_get(:@clock).call
      attempt = attempt_row
      budget = Hive::TaskWorkspace::BoundedReader::Budget.new(1_000_000)
      diagnostics = []

      reader.result = read_result(JSON.generate(receipt("controller_launch", "observed_at_launch")))
      launch = subject.send(
        :read_receipt, "launch", expected_kind: "controller_launch",
        expected_quality: "observed_at_launch", attempt: attempt,
        source: "controller_receipt", budget: budget, diagnostics: diagnostics
      )
      reader.result = read_result(JSON.generate(receipt("agent_selection", "agent_asserted_used")))
      agent = subject.send(
        :read_receipt, "agent", expected_kind: "agent_selection",
        expected_quality: "agent_asserted_used", attempt: attempt,
        source: "agent_receipt", budget: budget, diagnostics: diagnostics
      )
      current = subject.send(:normalize_current, current_observation, diagnostics)
      launch_result = read_result(JSON.generate(receipt("controller_launch", "observed_at_launch")))
      agent_result = read_result(JSON.generate(receipt("agent_selection", "agent_asserted_used")))
      reader.define_singleton_method(:read) do |reference, **|
        reference.end_with?(".launch.json") ? launch_result : agent_result
      end
      projected = subject.send(:project_attempt, attempt, current, budget, diagnostics)
      assert_equal "current", projected.fetch("state")
      assert_equal "current", subject.call.fetch("state")

      invalid = subject.send(
        :project_attempt, attempt.merge("attempt_id" => "bad/id"), current, budget, diagnostics
      )
      assert_equal "unavailable", invalid.fetch("state")
    end
  end

  def test_provenance_receipt_failures_and_state_helpers
    with_tmp_dir do |root|
      task = Task.new(root, "task", 42)
      reader = Reader.new
      subject = provenance(task, reader: reader)
      budget = Hive::TaskWorkspace::BoundedReader::Budget.new(1_000_000)
      diagnostics = []

      reader.result = read_result("{}", truncated: true)
      assert_equal "partial", read_receipt(subject, budget, diagnostics).fetch("state")
      reader.result = read_result("{}", binary: true)
      assert_equal "unavailable", read_receipt(subject, budget, diagnostics).fetch("state")
      reader.result = read_result("{}", invalid_encoding: true)
      assert_equal "unavailable", read_receipt(subject, budget, diagnostics).fetch("state")

      reader = Reader.new(error: Hive::TaskWorkspace::SourceError.new(
        source: "bounded_reader", reason: "read_failed"
      ))
      subject = provenance(task, reader: reader)
      assert_equal "unavailable", read_receipt(subject, budget, diagnostics).fetch("state")

      assert_raises(ArgumentError) do
        subject.send(
          :validate_receipt!, receipt("wrong", "wrong"), expected_kind: "controller_launch",
          expected_quality: "observed_at_launch", attempt: attempt_row
        )
      end
      foreign = receipt("controller_launch", "observed_at_launch")
      foreign["binding"]["project"] = "foreign"
      assert_raises(ArgumentError) do
        subject.send(
          :validate_receipt!, foreign, expected_kind: "controller_launch",
          expected_quality: "observed_at_launch", attempt: attempt_row
        )
      end
      assert_raises(ArgumentError) do
        subject.send(:validate_selection!, "references" => [ { "path" => "../secret" } ])
      end

      assert_equal "partial", subject.send(
        :attempt_state, launch: { "state" => "missing" }, agent: { "state" => "current" },
        repository: { "state" => "current" }, repository_consistency: "current",
        wiki_consistency: "current"
      )
      assert_equal "partial", subject.send(
        :attempt_state, launch: { "state" => "current" }, agent: { "state" => "current" },
        repository: { "state" => "current" }, repository_consistency: "partial",
        wiki_consistency: "current"
      )
      assert_equal "partial", subject.send(:context_state, { "state" => "current" }, { "state" => "partial" })
      assert_equal "current", subject.send(:value_state, {})
      assert_raises(ArgumentError) { subject.send(:safe_attempt_id, "bad/id") }
      assert_nil subject.send(:valid_time, "bad")
    end
  end

  def test_provenance_outer_and_current_observation_fail_soft_paths
    with_tmp_dir do |root|
      task = Task.new(root, "task", 42)
      subject = Hive::TaskWorkspace::Provenance.new(
        task: task, attempts_panel: RaisingValue.new, current_observation: current_observation
      )
      assert_equal "unavailable", subject.call.fetch("state")

      diagnostics = []
      normalized = subject.send(:normalize_current, RaisingValue.new, diagnostics)
      assert_equal "unavailable", normalized.fetch("state")
      assert_equal "current_observation_invalid", diagnostics.first.fetch("reason")

      observation = Hive::ContextProvenance.method(:observe_current)
      with_replaced_singleton_method(
        Hive::ContextProvenance, :observe_current, ->(**) { raise "capture failed" }
      ) do
        no_current = Hive::TaskWorkspace::Provenance.new(
          task: task, attempts_panel: { "records" => [] }
        )
        assert_nil no_current.send(:observe_current)
      end
      assert observation
    end
  end

  private

  def timeline(events:, limits: Hive::TaskWorkspace::Limits.new)
    Hive::TaskWorkspace::Timeline.new(
      task_identity: { project: "demo", slug: "task" }, journal_records: [],
      event_records: events, limits: limits,
      cursor_codec: Hive::TaskWorkspace::Timeline::CursorCodec.new(secret: SECRET)
    )
  end

  def provenance(task, reader:)
    Hive::TaskWorkspace::Provenance.new(
      task: task, attempts_panel: { "records" => [ attempt_row ] }, reader: reader,
      current_observation: current_observation
    )
  end

  def read_result(content, truncated: false, binary: false, invalid_encoding: false)
    Hive::TaskWorkspace::BoundedReader::Result.new(
      content: content, bytes: content.bytesize, truncated: truncated,
      binary: binary, invalid_encoding: invalid_encoding, evidence_ref: "receipt"
    )
  end

  def read_receipt(subject, budget, diagnostics)
    subject.send(
      :read_receipt, "receipt", expected_kind: "controller_launch",
      expected_quality: "observed_at_launch", attempt: attempt_row,
      source: "controller_receipt", budget: budget, diagnostics: diagnostics
    )
  end

  def attempt_row
    {
      "attempt_id" => "attempt-1", "project_slug" => "demo", "stage" => "4-execute",
      "task_generation" => 3, "current" => true
    }
  end

  def receipt(kind, quality)
    {
      "schema" => "hive-context-receipt", "schema_version" => 1, "kind" => kind,
      "binding" => {
        "project" => "demo", "task_slug" => "task", "task_id" => "42",
        "stage" => "4-execute", "attempt_id" => "attempt-1", "task_generation" => 3
      },
      "captured_at" => NOW, "quality" => quality,
      "repository" => current_observation.fetch("repository"),
      "wiki" => current_observation.fetch("wiki"),
      "selection" => kind == "agent_selection" ? { "references" => [ { "path" => "wiki/index.md" } ] } : nil,
      "diagnostics" => []
    }
  end

  def current_observation
    {
      "observed_at" => NOW,
      "repository" => {
        "state" => "current", "repository" => "github.com/acme/demo",
        "head_oid" => "a" * 40
      },
      "wiki" => {
        "state" => "current", "identity_kind" => "tree", "identifier" => "b" * 40
      }
    }
  end
end
