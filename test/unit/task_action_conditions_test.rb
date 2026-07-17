require "test_helper"
require "hive/task_action"
require "hive/task_projection"
require "hive/task_journal/envelope"
require "hive/workflows/coding"

class TaskActionConditionsTest < Minitest::Test
  include HiveTestHelper

  TaskStub = Struct.new(
    :folder, :state_file, :slug, :stage_index, :stage_name, :workflow,
    keyword_init: true
  )

  def test_conditions_mode_uses_projection_when_compatibility_marker_is_stale
    with_tmp_dir do |dir|
      task = build_task(dir)
      stale = marker(:execute_waiting, "reason" => "no_worktree_changes")
      projection = Hive::TaskProjection.project(records: satisfied_records, marker: stale)

      action = Hive::TaskAction.for(
        task, projection: projection,
        config: condition_config("conditions")
      )

      assert_equal "ready_to_open_pr", action.key
      assert action.condition_gate.eligible?
      assert_equal "conditions", action.migration_selection.effective
    end
  end

  def test_shadow_mode_keeps_marker_action_and_surfaces_divergence
    with_tmp_dir do |dir|
      task = build_task(dir)
      stale = marker(:execute_waiting, "reason" => "no_worktree_changes")
      projection = Hive::TaskProjection.project(
        records: satisfied_records + [ shadow_mismatch ], marker: stale
      )

      action = Hive::TaskAction.for(
        task, projection: projection,
        config: condition_config("shadow")
      )

      assert_equal "needs_input", action.key
      assert_equal "condition shadow mismatch", action.condition_warning
      assert_equal "shadow", action.migration_selection.effective
    end
  end

  def test_research_evidence_accepts_marker_or_execute_output_and_fails_closed_on_io
    with_tmp_dir do |dir|
      task = build_task(dir)
      File.write(File.join(dir, "plan.md"), "---\nexecution_mode: research\n---\nplan\n")

      completed = marker(:execute_complete, "mode" => "research")
      action = Hive::TaskAction.new(
        task, completed, projection: Hive::TaskProjection.project(records: [], marker: completed)
      )
      assert action.send(:research_evidence?)

      waiting = marker(:execute_waiting)
      File.write(task.state_file, "## Execute Output\n\nresult\n")
      action = Hive::TaskAction.new(
        task, waiting, projection: Hive::TaskProjection.project(records: [], marker: waiting)
      )
      assert action.send(:research_evidence?)

      File.delete(task.state_file)
      refute action.send(:research_evidence?)
    end
  end

  def test_research_frontmatter_parse_errors_fail_closed
    with_tmp_dir do |dir|
      task = build_task(dir)
      File.write(File.join(dir, "plan.md"), "---\n[unterminated\n---\n")
      action = Hive::TaskAction.new(
        task, marker(:execute_waiting),
        projection: Hive::TaskProjection.project(records: [], marker: marker(:execute_waiting))
      )

      refute action.send(:research_execution?)
    end
  end

  def test_projection_loading_supports_folderless_tasks_and_store_failures
    folderless = TaskStub.new(
      folder: nil, state_file: "/tmp/folderless-task.md", slug: "folderless",
      stage_index: 4, stage_name: "execute", workflow: Hive::Workflows::Coding::DESCRIPTOR
    )
    action = Hive::TaskAction.new(folderless, marker(:execute_waiting))
    assert_equal 0, action.projection["identity"].fetch("task_generation")

    with_tmp_dir do |dir|
      task = build_task(dir)
      broken_store = Object.new
      broken_store.define_singleton_method(:read) { |**| raise Errno::EACCES, "blocked" }
      with_replaced_singleton_method(
        Hive::TaskProjection::Store, :new, ->(**) { broken_store }
      ) do
        recovered = Hive::TaskAction.new(task, marker(:execute_waiting))
        assert_equal 0, recovered.projection["identity"].fetch("task_generation")
      end
    end
  end

  private

  def build_task(dir)
    File.write(File.join(dir, "task.md"), "task\n")
    TaskStub.new(
      folder: dir, state_file: File.join(dir, "task.md"), slug: "task",
      stage_index: 4, stage_name: "execute",
      workflow: Hive::Workflows::Coding::DESCRIPTOR
    )
  end

  def marker(name, attrs = {})
    Hive::Markers::State.new(name: name, attrs: attrs, raw: nil)
  end

  def condition_config(mode)
    { "conditions" => { "authority" => "markers", "stages" => { "4-execute" => mode } } }
  end

  def satisfied_records
    [
      observation(
        "agent", "AgentHealthy", "satisfied", "attempt_live",
        [ { "type" => "attempt_lease", "attempt_id" => "attempt-b", "lease_version" => 1,
            "state" => "running" } ]
      ),
      observation(
        "changes", "ChangesPresent", "satisfied", "commit_present",
        [ { "type" => "commit", "sha" => "b" * 40, "branch" => "task" } ]
      ),
      observation(
        "wait", "AwaitingHuman", "unsatisfied", "not_waiting",
        [ { "type" => "attempt_lease", "attempt_id" => "attempt-b", "lease_version" => 1,
            "state" => "running" } ],
        "blocked_transition" => "execute_to_open_pr"
      )
    ]
  end

  def observation(event_id, condition, state, reason, evidence, payload = {})
    base_record(event_id, "condition_observed", reason).merge(
      "evidence" => evidence,
      "payload" => payload.merge("condition" => condition, "state" => state)
    )
  end

  def shadow_mismatch
    base_record("shadow", "shadow_audit", "shadow_mismatch").merge(
      "payload" => {
        "category" => "commit_success", "marker_action" => "execute_waiting",
        "condition_action" => "execute_complete", "match" => false, "explained" => false
      }
    )
  end

  def base_record(event_id, event_type, reason)
    {
      "schema" => Hive::TaskJournal::Envelope::SCHEMA,
      "schema_version" => 1,
      "event_id" => event_id,
      "event_type" => event_type,
      "occurred_at" => "2026-07-17T12:00:00.000000Z",
      "observed_at" => "2026-07-17T12:00:00.000000Z",
      "task" => { "id" => "42", "slug" => "task" },
      "workflow" => "coding", "stage" => "4-execute",
      "attempt_id" => "attempt-b", "task_generation" => 1,
      "ownership_generation" => "owner-b", "commit_generation" => 1,
      "reason" => reason, "evidence" => [],
      "provenance" => { "source" => "test" }, "payload" => {}
    }
  end
end
