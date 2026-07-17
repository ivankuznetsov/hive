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

  def test_blocked_condition_action_uses_diagnostic_even_when_marker_is_stale
    with_tmp_dir do |dir|
      task = build_task(dir)
      stale = marker(:execute_complete)
      lost = observation(
        "agent-lost", "AgentHealthy", "unsatisfied", "attempt_lost",
        [ { "type" => "attempt_lease", "attempt_id" => "attempt-b",
            "lease_version" => 2, "state" => "lost", "outcome" => nil } ]
      )
      records = satisfied_records.reject { |record| record["event_id"] == "agent" } + [ lost ]
      action = Hive::TaskAction.for(
        task,
        projection: Hive::TaskProjection.project(records: records, marker: stale),
        config: condition_config("conditions")
      )

      assert_equal "needs_input", action.key
      next_action = action.next_action
      assert_equal Hive::Schemas::NextActionKind::RUN, next_action.fetch("kind")
      assert_equal "AgentHealthy", next_action.fetch("condition")
      assert_equal "attempt_lost", next_action.fetch("reason")
      assert_equal dir, next_action.fetch("target")
      assert_includes next_action.fetch("rerun_with"), "hive develop"
    end
  end

  def test_pending_condition_action_explicitly_requests_reconciliation
    with_tmp_dir do |dir|
      task = build_task(dir)
      stale = marker(:execute_complete, "attempt_id" => "attempt-b")
      action = Hive::TaskAction.for(
        task,
        projection: Hive::TaskProjection.project(records: [], marker: stale),
        config: condition_config("conditions")
      )

      next_action = action.next_action
      assert_equal Hive::Schemas::NextActionKind::NO_OP, next_action.fetch("kind")
      assert_equal "condition_reconciliation_required", next_action.fetch("reason")
      assert_equal "AgentHealthy", next_action.fetch("condition")
    end
  end

  def test_hash_gate_and_unverifiable_evidence_build_typed_recovery_actions
    with_tmp_dir do |dir|
      task = build_task(dir)
      pending = Hive::Conditions::RecoveryAction.build(
        task: task,
        gate: { "diagnostics" => [
          { "condition" => "AgentHealthy", "state" => "missing", "code" => "missing" }
        ] }
      )
      assert_equal Hive::Schemas::NextActionKind::NO_OP, pending.fetch("kind")

      marker = marker(:execute_waiting, "reason" => "evidence_unverifiable")
      action = Hive::ExecuteWaitingAction.build(task, marker)
      assert_equal Hive::Schemas::NextActionKind::EDIT, action.fetch("kind")
      assert_equal dir, action.fetch("target")
    end
  end

  def test_research_evidence_comes_only_from_the_current_journal_projection
    with_tmp_dir do |dir|
      task = build_task(dir)
      File.write(File.join(dir, "plan.md"), "---\nexecution_mode: research\n---\nplan\n")

      evidence = [
        { "type" => "commit", "sha" => "b" * 40, "branch" => "task" },
        { "type" => "file", "path" => "task.md", "digest" => "c" * 64,
          "purpose" => "research_output" }
      ]
      research = observation(
        "research", "ChangesPresent", "unsatisfied", "research_no_commit", evidence,
        "research_output_evidence" => true
      )
      completed = marker(:execute_complete, "mode" => "research")
      action = Hive::TaskAction.new(
        task, completed,
        projection: Hive::TaskProjection.project(records: satisfied_records + [ research ], marker: completed)
      )
      assert action.send(:research_evidence?)

      waiting = marker(:execute_waiting)
      File.write(task.state_file, "## Execute Output\n\nresult\n")
      action = Hive::TaskAction.new(
        task, waiting, projection: Hive::TaskProjection.project(records: [], marker: waiting)
      )
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

  def test_research_frontmatter_uses_shared_parser_for_crlf_and_eof_closing_delimiter
    with_tmp_dir do |dir|
      task = build_task(dir)
      File.binwrite(File.join(dir, "plan.md"), "---\r\nexecution_mode: research\r\n---")
      action = Hive::TaskAction.new(
        task, marker(:execute_waiting),
        projection: Hive::TaskProjection.project(records: [], marker: marker(:execute_waiting))
      )

      assert action.send(:research_execution?)
    end
  end

  def test_projection_loading_supports_folderless_tasks_and_propagates_store_failures
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
        assert_raises(Errno::EACCES) do
          Hive::TaskAction.new(task, marker(:execute_waiting))
        end
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
