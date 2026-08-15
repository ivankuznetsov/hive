require "test_helper"
require "hive/task_workspace/provenance"

class TaskWorkspaceProvenanceTest < Minitest::Test
  include HiveTestHelper

  NOW = "2026-08-12T12:00:00.000000Z"
  TaskStub = Data.define(:folder, :project_root, :slug, :id)

  def test_keeps_historical_and_current_identity_separate_and_marks_stale
    with_fixture do |task|
      write_receipt(task, "attempt-1.launch.json", launch_receipt(task))
      write_receipt(task, "attempt-1.json", agent_receipt(task))
      current = current_observation(head: "b" * 40, wiki: "c" * 40)

      panel = projector(task, current: current).call

      assert_equal "stale", panel.fetch("state")
      record = panel.fetch("records").first
      assert_equal "a" * 40, record.dig("repository", "value", "head_oid")
      assert_equal "b" * 40,
                   panel.dig("current_observation", "repository", "value", "head_oid")
      assert_equal "stale", record.dig("consistency", "repository")
      assert_equal "agent_asserted_used", record.dig("selection", "quality")
      refute_includes panel.to_s, task.folder
    end
  end

  def test_legacy_and_conflicting_receipts_remain_explicit
    with_fixture do |task|
      legacy = Hive::TaskWorkspace::Provenance.new(
        task: task, attempts_panel: { "records" => [] },
        current_observation: current_observation
      ).call
      assert_equal "partial", legacy.fetch("state")
      assert_empty legacy.fetch("records")
      assert_includes legacy.fetch("diagnostics").map { |row| row.fetch("reason") },
                      "historical_receipts_missing"

      write_receipt(task, "attempt-1.launch.json", launch_receipt(task))
      agent = agent_receipt(task)
      agent["repository"] = launch_receipt(task).fetch("repository").merge("head_oid" => "d" * 40)
      write_receipt(task, "attempt-1.json", agent)
      conflicting = projector(task).call
      assert_equal "conflicting", conflicting.fetch("state")
      assert_equal 2, conflicting.dig("records", 0, "repository", "conflicts").length
    end
  end

  def test_malformed_or_wrong_binding_degrades_only_the_receipt
    with_fixture do |task|
      write_receipt(task, "attempt-1.launch.json", launch_receipt(task))
      wrong = agent_receipt(task)
      wrong["binding"]["attempt_id"] = "other"
      write_receipt(task, "attempt-1.json", wrong)

      panel = projector(task).call

      assert_equal "partial", panel.fetch("state")
      assert_equal "unavailable", panel.dig("records", 0, "receipts", "agent", "state")
      assert_includes panel.fetch("diagnostics").map { |row| row.fetch("reason") },
                      "receipt_invalid"
    end
  end

  private

  def with_fixture
    with_tmp_dir do |root|
      task_root = File.join(root, "task")
      FileUtils.mkdir_p(File.join(task_root, "context-receipts"))
      yield TaskStub.new(task_root, root, "task-260812-abcd", 42)
    end
  end

  def projector(task, current: current_observation)
    Hive::TaskWorkspace::Provenance.new(
      task: task,
      attempts_panel: {
        "records" => [
          {
            "attempt_id" => "attempt-1", "stage" => "4-execute",
            "task_generation" => 3, "current" => true, "project_slug" => "demo"
          }
        ]
      },
      current_observation: current
    )
  end

  def launch_receipt(task)
    receipt(task, kind: "controller_launch", quality: "observed_at_launch").merge(
      "repository" => {
        "state" => "current", "head_oid" => "a" * 40, "branch" => "feature",
        "repository" => "github.com/acme/demo", "observed_from" => "local_git",
        "diagnostics" => []
      },
      "wiki" => {
        "state" => "current", "identity_kind" => "git_tree",
        "identifier" => "b" * 40, "file_count" => nil, "byte_count" => nil,
        "truncated" => false, "diagnostics" => []
      },
      "selection" => nil
    )
  end

  def agent_receipt(task)
    receipt(task, kind: "agent_selection", quality: "agent_asserted_used").merge(
      "repository" => nil, "wiki" => nil,
      "selection" => {
        "references" => [
          { "path" => "wiki/index.md", "kind" => "wiki", "label" => "index" }
        ],
        "queries" => [], "rationale" => "Establish the Web ownership boundary."
      }
    )
  end

  def receipt(task, kind:, quality:)
    {
      "schema" => "hive-context-receipt", "schema_version" => 1,
      "kind" => kind,
      "binding" => {
        "project" => "demo", "task_slug" => task.slug, "task_id" => task.id.to_s,
        "stage" => "4-execute", "attempt_id" => "attempt-1",
        "task_generation" => 3, "ownership_generation" => "owner-3"
      },
      "captured_at" => NOW, "quality" => quality,
      "repository" => nil, "wiki" => nil, "selection" => nil,
      "diagnostics" => []
    }
  end

  def current_observation(head: "a" * 40, wiki: "b" * 40)
    {
      "observed_at" => NOW,
      "repository" => {
        "state" => "current", "head_oid" => head, "branch" => "feature",
        "repository" => "github.com/acme/demo", "observed_from" => "local_git",
        "diagnostics" => []
      },
      "wiki" => {
        "state" => "current", "identity_kind" => "git_tree", "identifier" => wiki,
        "file_count" => nil, "byte_count" => nil, "truncated" => false,
        "diagnostics" => []
      }
    }
  end

  def write_receipt(task, name, value)
    File.write(
      File.join(task.folder, "context-receipts", name),
      JSON.generate(value)
    )
  end
end
