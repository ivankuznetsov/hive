require "test_helper"
require "hive/task_workspace/artifacts"
require "hive/task_workspace/attempts"
require "hive/task_workspace/jsonl_reader"
require "hive/task_workspace/resources"

class TaskWorkspaceCoreCoverageGapsTest < Minitest::Test
  include HiveTestHelper

  NOW = "2026-08-12T10:00:00.000000Z"

  class Store
    def initialize(records = {}, error: nil)
      @records = records
      @error = error
    end

    def fetch(id)
      raise @error if @error

      @records[id]
    end
  end

  class ExactUsage
    def exact_attempt(**)
      {
        available: true,
        sessions: [
          { session_id: "session", input: "bad", output: -2, cached: 1.5,
            model: "gpt", source: "receipt" }
        ],
        unattributed_count: 0
      }
    end
  end

  def test_workspace_rejects_absolute_paths_and_unknown_values
    assert_raises(ArgumentError) do
      Hive::TaskWorkspace.safe_value!("evidence_ref" => "C:\\private\\evidence")
    end
    assert_raises(ArgumentError) { Hive::TaskWorkspace.safe_value!(Object.new) }
    assert_equal "unavailable", Hive::TaskWorkspace.panel("timeline") { raise "boom" }.fetch("state")
    assert_equal "unavailable", Hive::TaskWorkspace.panel("unknown") { [] }.fetch("state")
  end

  def test_artifacts_reports_empty_current_invalid_and_stat_failures
    with_tmp_dir do |root|
      missing = Hive::TaskWorkspace::Artifacts.new(task_root: root, references: []).call
      assert_equal "missing", missing.fetch("state")

      File.write(File.join(root, "artifact.md"), "evidence")
      current = Hive::TaskWorkspace::Artifacts.new(
        task_root: root, references: [ "artifact.md", "artifact.md" ]
      ).call
      assert_equal "current", current.fetch("state")
      assert_equal 1, current.fetch("observed_files")

      invalid = Hive::TaskWorkspace::Artifacts.new(
        task_root: root, references: [ "../outside", "missing.md" ]
      ).call
      assert_equal "partial", invalid.fetch("state")
      assert_equal "invalid_reference", invalid.dig("diagnostics", 0, "reason")

      original = File.method(:lstat)
      with_replaced_singleton_method(
        File, :lstat,
        ->(path) { path.end_with?("denied.md") ? raise(Errno::EACCES) : original.call(path) }
      ) do
        denied = Hive::TaskWorkspace::Artifacts.new(task_root: root, references: [ "denied.md" ]).call
        assert_equal "stat_failed", denied.dig("diagnostics", 0, "reason")
      end
    end

    with_tmp_dir do |root|
      reader = Object.new
      reader.define_singleton_method(:read) { |*| raise ArgumentError, "bad root" }
      File.write(File.join(root, "artifact.md"), "evidence")
      unavailable = Hive::TaskWorkspace::Artifacts.new(
        task_root: root, references: [ "artifact.md" ], reader: reader
      ).call
      assert_equal "unavailable", unavailable.fetch("state")
    end
  end

  def test_attempt_caps_missing_records_fetch_failures_and_record_objects
    empty = Hive::TaskWorkspace::Attempts.new(
      projection: {}, attempt_store: Store.new, activities: []
    ).call
    assert_equal "missing", empty.fetch("state")

    attempts = 3.times.to_h { |index| [ "a#{index}", attempt("a#{index}") ] }
    projection = {
      "identity" => { "attempt_id" => nil },
      "journal" => { "attempts" => attempts.keys.map { |id| { "attempt_id" => id } } }
    }
    capped = Hive::TaskWorkspace::Attempts.new(
      projection: projection, attempt_store: Store.new(attempts), activities: [],
      limits: Hive::TaskWorkspace::Limits.new(attempt_ids: 1)
    ).call
    assert capped.fetch("truncated")
    assert_includes capped.fetch("diagnostics").map { |row| row["reason"] }, "attempt_ids_exhausted"

    missing_predecessor = Hive::TaskWorkspace::Attempts.new(
      projection: { "identity" => { "attempt_id" => "a" }, "journal" => { "attempts" => [] } },
      attempt_store: Store.new({ "a" => attempt("a", predecessor: "gone") }), activities: []
    ).call
    assert_includes missing_predecessor.fetch("diagnostics").map { |row| row["reason"] },
                    "predecessor_missing"

    bytes = Hive::TaskWorkspace::Attempts.new(
      projection: { "identity" => { "attempt_id" => "a" }, "journal" => { "attempts" => [] } },
      attempt_store: Store.new({
        "a" => attempt("a", predecessor: "b"),
        "b" => attempt("b").merge("padding" => "x" * 500)
      }), activities: [], limits: Hive::TaskWorkspace::Limits.new(attempt_bytes: 450)
    ).call
    assert_includes bytes.fetch("diagnostics").map { |row| row["reason"] }, "attempt_bytes_exhausted"

    failed = Hive::TaskWorkspace::Attempts.new(
      projection: { "identity" => { "attempt_id" => "a" }, "journal" => { "attempts" => [] } },
      attempt_store: Store.new(error: RuntimeError.new("nope")), activities: []
    ).call
    assert_equal "unavailable", failed.fetch("state")
    assert_includes failed.fetch("diagnostics").map { |row| row["reason"] }, "attempt_fetch_failed"

    absent = Hive::TaskWorkspace::Attempts.new(
      projection: { "identity" => { "attempt_id" => "gone" }, "journal" => { "attempts" => [] } },
      attempt_store: Store.new, activities: []
    ).call
    assert_includes absent.fetch("diagnostics").map { |row| row["reason"] }, "current_attempt_missing"

    object = attempt("object")
    object.define_singleton_method(:task_input_epoch) { 7 }
    object_panel = Hive::TaskWorkspace::Attempts.new(
      projection: { "identity" => { "attempt_id" => "object" }, "journal" => { "attempts" => [] } },
      attempt_store: Store.new({ "object" => object }), activities: []
    ).call
    assert_equal 7, object_panel.dig("records", 0, "task_generation")
  end

  def test_bounded_reader_defensive_file_paths
    assert_raises(ArgumentError) do
      Hive::TaskWorkspace::BoundedReader.new(root: "/definitely/missing/root")
    end

    with_tmp_dir do |root|
      reader = Hive::TaskWorkspace::BoundedReader.new(root: root)
      Dir.mkdir(File.join(root, "directory"))
      assert_equal "not_regular", assert_raises(Hive::TaskWorkspace::SourceError) {
        reader.read("directory", max_bytes: 10)
      }.reason

      File.write(File.join(root, "file"), "content")
      assert_equal "missing", assert_raises(Hive::TaskWorkspace::SourceError) {
        reader.read("missing", max_bytes: 10)
      }.reason

      with_replaced_singleton_method(reader, :stable?, ->(*) { false }) do
        assert_equal "source_changed", assert_raises(Hive::TaskWorkspace::SourceError) {
          reader.read("file", max_bytes: 10)
        }.reason
      end

      before = File.lstat(File.join(root, "file"))
      fake = Object.new
      fake.define_singleton_method(:stat) { Struct.new(:file?, :dev, :ino).new(true, before.dev, before.ino + 1) }
      with_replaced_singleton_method(File, :open, ->(*, &block) { block.call(fake) }) do
        assert_equal "descriptor_changed", assert_raises(Hive::TaskWorkspace::SourceError) {
          reader.read("file", max_bytes: 10)
        }.reason
      end

      with_replaced_singleton_method(File, :lstat, ->(*) { raise Errno::ELOOP }) do
        assert_equal "symlink_refused", assert_raises(Hive::TaskWorkspace::SourceError) {
          reader.read("file", max_bytes: 10)
        }.reason
      end
      with_replaced_singleton_method(File, :lstat, ->(*) { raise Errno::EACCES }) do
        assert_equal "read_failed", assert_raises(Hive::TaskWorkspace::SourceError) {
          reader.read("file", max_bytes: 10)
        }.reason
      end

      outside = Dir.mktmpdir("workspace-outside")
      Dir.mkdir(File.join(outside, "nested"))
      File.symlink(File.join(outside, "nested"), File.join(root, "escape"))
      assert_equal "containment_escape", assert_raises(Hive::TaskWorkspace::SourceError) {
        reader.read("escape/file", max_bytes: 10)
      }.reason
    ensure
      FileUtils.remove_entry(outside) if outside && File.exist?(outside)
    end
  end

  def test_jsonl_reader_defensive_file_paths_and_values
    assert_raises(ArgumentError) do
      Hive::TaskWorkspace::JsonlReader.new(
        root: "/definitely/missing/root", reference: "events", max_bytes: 1,
        max_records: 1, source: "events"
      )
    end

    with_tmp_dir do |root|
      assert_raises(ArgumentError) { jsonl_reader(root, "../events") }
      assert_equal [], jsonl_reader(root, "missing/records").call.records

      Dir.mkdir(File.join(root, "directory"))
      assert_equal "not_regular", jsonl_reader(root, "directory").call.diagnostics.first["reason"]

      File.write(File.join(root, "values"), "[]\n{\"ok\":[\"ghp_#{'a' * 36}\"]}\n")
      values = jsonl_reader(root, "values").call
      assert_equal [ { "ok" => [ "[REDACTED:github_token]" ] } ], values.records
      assert_equal "malformed_record", values.diagnostics.first["reason"]

      File.write(File.join(root, "large"), "x" * 30)
      large = jsonl_reader(root, "large", max_bytes: 10).call
      assert_equal 30, large.window_start
      assert_equal [], large.records

      File.write(File.join(root, "cursor"), "{}\n")
      invalid = jsonl_reader(root, "cursor").call(before: 100)
      assert_equal "cursor_boundary_invalid", invalid.diagnostics.first["reason"]

      reader = jsonl_reader(root, "cursor")
      with_replaced_singleton_method(reader, :stable?, ->(*) { false }) do
        assert_equal "source_changed", reader.call.diagnostics.first["reason"]
      end


      path_stat = File.lstat(File.join(root, "cursor"))
      fake = Object.new
      fake.define_singleton_method(:stat) do
        Struct.new(:file?, :dev, :ino).new(true, path_stat.dev, path_stat.ino + 1)
      end
      with_replaced_singleton_method(File, :open, ->(*, &block) { block.call(fake) }) do
        assert_equal "descriptor_changed", jsonl_reader(root, "cursor").call.diagnostics.first["reason"]
      end
      with_replaced_singleton_method(File, :lstat, ->(*) { raise Errno::ELOOP }) do
        assert_equal "symlink_refused", jsonl_reader(root, "cursor").call.diagnostics.first["reason"]
      end
      with_replaced_singleton_method(File, :lstat, ->(*) { raise Errno::EACCES }) do
        assert_equal "read_failed", jsonl_reader(root, "cursor").call.diagnostics.first["reason"]
      end
      assert_equal "read_failed", reader.send(:failed, "read_failed").diagnostics.first["reason"]

      outside = Dir.mktmpdir("jsonl-outside")
      File.symlink(outside, File.join(root, "escape"))
      escaped = jsonl_reader(root, "escape/records").call
      assert_equal "containment_escape", escaped.diagnostics.first["reason"]
    ensure
      FileUtils.remove_entry(outside) if outside && File.exist?(outside)
    end
  end

  def test_limits_snapshot_and_resource_edge_cases
    limits = Hive::TaskWorkspace::Limits.new
    assert_equal limits.fetch(:workspace_bytes), limits[:workspace_bytes]
    refute_same limits.to_h, limits.to_h

    assert_raises(ArgumentError) { snapshot(generated_at: "bad") }
    assert_raises(ArgumentError) { snapshot(operator: { questions: [ { n: [], text: "?", binding: "b", ordinal: 1 } ] }) }
    assert_equal "hive", snapshot["task"]["project"]

    empty = Hive::TaskWorkspace::Resources.new(
      attempts_panel: { "records" => [], "diagnostics" => [], "truncated" => false },
      usage_reader: ->(**) { raise "unused" }
    ).call
    assert_equal "missing", empty.fetch("state")

    observation = {
      "kind" => "provider_rate_limit", "unit" => "requests", "observed" => 3,
      "retry_at" => nil
    }
    panel = resource_panel(
      usage_reader: ExactUsage.new, guards: [], observation: observation
    )
    assert_equal "current", panel.fetch("state")
    guard = panel.fetch("records").find { |record| record["record_kind"] == "guard" }
    usage = panel.fetch("records").find { |record| record["record_kind"] == "usage" }
    assert_equal "Provider rate limit", guard.fetch("label")
    assert_equal({ "input" => 0, "output" => 0, "cached" => 1, "tokens" => 0 },
                 usage.fetch("totals"))

    failing = resource_panel(usage_reader: ->(**) { raise "failed" }, guards: [])
    assert_equal "partial", failing.fetch("state")
    assert_equal "usage_unavailable", failing.dig("diagnostics", 0, "reason")

    labels = %w[monetary_api_cap timeout launch_quota account_quota mystery]
    labels.each do |kind|
      record = resource_panel(
        usage_reader: ->(**) { { available: false } },
        guards: [ { "kind" => kind, "unit" => "turns", "scope" => "session",
                   "source" => "descriptor", "enforcement" => "controller",
                   "billing_semantics" => "not_applicable" } ]
      ).fetch("records").find { |row| row["record_kind"] == "guard" }
      refute_empty record.fetch("label")
      assert_equal "missing", record.fetch("state")
    end

    invalid_number = resource_panel(
      usage_reader: ->(**) { { available: false } },
      guards: [ { "kind" => "token_limit", "unit" => "tokens", "scope" => "session",
                  "source" => "descriptor", "enforcement" => "controller",
                  "billing_semantics" => "not_applicable", "configured" => "bad" } ]
    ).fetch("records").find { |row| row["record_kind"] == "guard" }
    assert_nil invalid_number.fetch("configured")
  end

  private

  def attempt(id, predecessor: nil)
    {
      "attempt_id" => id, "predecessor_attempt_id" => predecessor,
      "intended_stage" => "4-execute", "task_input_epoch" => 3,
      "routing" => {}, "state" => "running", "accepted_at" => NOW
    }
  end

  def jsonl_reader(root, reference, max_bytes: 1024)
    Hive::TaskWorkspace::JsonlReader.new(
      root: root, reference: reference, max_bytes: max_bytes, max_records: 10,
      source: "event_stream"
    )
  end

  def snapshot(generated_at: NOW, operator: {})
    Hive::TaskWorkspace::Snapshot.new(
      generated_at: generated_at,
      task: { project: "hive", slug: "task", id: 1, stage: "4-execute", generation: 1 },
      status: { state: "current", freshness: "fresh", diagnostics: [] },
      decision: { posture: "wait", action: {} }, panels: {}, operator: operator
    )
  end

  def resource_panel(usage_reader:, guards:, observation: nil)
    Hive::TaskWorkspace::Resources.new(
      attempts_panel: {
        "records" => [ { "attempt_id" => "attempt", "task_generation" => 1,
                        "sessions" => [ { "session_id" => "session", "guards" => guards,
                                         "resource_observation" => observation } ] } ],
        "diagnostics" => [], "truncated" => false
      }, usage_reader: usage_reader
    ).call
  end
end
