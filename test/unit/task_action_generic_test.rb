require "test_helper"
require "fileutils"
require "hive/daemon/policy"
require "hive/markers"
require "hive/task"
require "hive/task_action"

class TaskActionGenericTest < Minitest::Test
  include HiveTestHelper

  Marker = Hive::Markers::State
  SLUG = "generic-task-260620-abcd"

  def marker(name, attrs = {})
    Marker.new(name: name, attrs: attrs, raw: nil)
  end

  def with_research_task(stage_name, descriptor: research_workflow)
    with_registered_workflow(descriptor) do
      with_tmp_dir do |root|
        stage = descriptor.stage_named(stage_name)
        folder = File.join(root, ".hive-state", "stages", stage.dir, SLUG)
        FileUtils.mkdir_p(folder)
        File.write(
          File.join(folder, "meta.yml"),
          { "slug" => SLUG, "workflow" => descriptor.id.to_s }.to_yaml
        )

        yield Hive::Task.new(folder)
      end
    end
  end

  def action_for(stage_name, marker_name, attrs = {}, descriptor: research_workflow, **options)
    with_research_task(stage_name, descriptor: descriptor) do |task|
      return Hive::TaskAction.for(task, marker(marker_name, attrs), **options)
    end
  end

  def policy_decision(action)
    Hive::Daemon::Policy.decide(
      action: action.key,
      stage: "#{action.task.stage_index}-#{action.task.stage_name}",
      workflow: action.task.workflow.id.to_s,
      command: action.command,
      state_file_mtime: Time.utc(2026, 6, 20, 12, 0, 0),
      last_dispatched_state_file_mtime: nil,
      now: Time.utc(2026, 6, 20, 12, 1, 0)
    )
  end

  def test_generic_marker_to_action_matrix
    fresh_entry = action_for("intake", :none)
    assert_equal "ready_to_advance", fresh_entry.key
    assert_equal "Ready to advance", fresh_entry.label
    # A markerless inert stage carries --force: it has no agent to stamp a
    # terminal marker, so approve's VALID_TERMINAL_MARKERS gate would reject the
    # forward move and the daemon would dead-loop without the override.
    assert_equal "hive approve #{SLUG} --from 1-intake --force", fresh_entry.command

    waiting = action_for("gather", :waiting)
    assert_equal "needs_input", waiting.key
    assert_equal "Needs your input", waiting.label
    assert_equal "hive run #{SLUG}", waiting.command

    complete_middle = action_for("gather", :complete)
    assert_equal "ready_to_advance", complete_middle.key
    assert_equal "hive approve #{SLUG} --from 2-gather", complete_middle.command

    complete_terminal = action_for("report", :complete)
    assert_equal "archived", complete_terminal.key
    assert_nil complete_terminal.command

    # :agent_working / stale-agent / :error short-circuit at the universal
    # override (TaskAction#universal_action) *before* descriptor-kind dispatch,
    # so these rows pin the override path, not generic classification.
    running = action_for("gather", :agent_working, { "pid" => "12345" }, pid_alive: true)
    assert_equal "agent_running", running.key
    assert_nil running.command

    stale = action_for("gather", :agent_working, { "pid" => "12345" }, pid_alive: false)
    assert_equal "error", stale.key

    errored = action_for("gather", :error)
    assert_equal "error", errored.key
    assert_nil errored.command
  end

  def test_semantic_terminal_block_stays_active_and_exposes_stage_local_retry_guidance
    action = action_for(
      "report", :error,
      {
        "reason" => "terminal_outcome_blocked",
        "outcome" => "needs-human",
        "marker_id" => "semantic-block-1"
      }
    )

    assert_equal "error", action.key
    assert_equal "Blocked", action.label
    assert_nil action.command

    diagnostic = action.diagnostic
    assert_equal "marker", diagnostic.fetch("source")
    assert_includes diagnostic.fetch("detail"), "needs-human"
    assert_includes diagnostic.fetch("detail"), "current terminal stage"
    assert_includes diagnostic.fetch("detail"), "fresh task"
    assert_equal "retry", diagnostic.dig("suggested_next_action", "kind")
    assert_includes diagnostic.dig("suggested_next_action", "command"), "hive act workflow.retry"
  end

  def test_invalid_terminal_outcome_stays_active_with_marker_backed_retry_guidance
    action = action_for(
      "report", :error,
      {
        "reason" => "terminal_outcome_invalid",
        "outcome" => "malformed",
        "marker_id" => "semantic-invalid-1"
      }
    )

    assert_equal "error", action.key
    assert_equal "Error", action.label
    assert_nil action.command
    diagnostic = action.diagnostic
    assert_equal "marker", diagnostic.fetch("source")
    assert_includes diagnostic.fetch("detail"), "invalid outcome contract"
    assert_includes diagnostic.fetch("detail"), "malformed"
    assert_equal "retry", diagnostic.dig("suggested_next_action", "kind")
    assert_includes diagnostic.dig("suggested_next_action", "command"), "hive act workflow.retry"
  end

  def test_council_marker_to_action_matrix
    fresh = action_for("review", :none, descriptor: council_workflow)
    assert_equal "ready_to_run", fresh.key
    assert_equal "hive run #{SLUG}", fresh.command

    waiting = action_for("review", :waiting, descriptor: council_workflow)
    assert_equal "needs_input", waiting.key
    assert_equal "hive run #{SLUG}", waiting.command

    complete_middle = action_for("review", :complete, descriptor: council_workflow)
    assert_equal "ready_to_advance", complete_middle.key
    assert_equal "hive approve #{SLUG} --from 2-review", complete_middle.command
  end

  def test_human_stage_waits_for_a_named_decision_and_never_dispatches
    action = action_for("approval", :waiting, { "decision_id" => "a" * 16 }, descriptor: human_workflow)

    assert_equal "needs_input", action.key
    assert_equal "Awaiting human decision", action.label
    assert_nil action.command
    assert_equal [
      { "name" => "approve", "complete" => true, "artifact" => "draft.md", "to" => nil },
      { "name" => "reject", "complete" => false, "artifact" => nil, "to" => "draft" }
    ], action.allowed_outcomes
    assert_equal :skip, policy_decision(action)

    completed = action_for("approval", :complete, descriptor: human_workflow)
    assert_equal "archived", completed.key
    assert_equal "Archived", completed.label
    assert_nil completed.command
  end

  def test_terminal_agent_complete_requires_non_empty_deliverable
    missing = action_for_terminal_active(:agent, write_deliverable: false)
    assert_equal "error", missing.fetch(:key)
    assert_nil missing.fetch(:command)

    empty = action_for_terminal_active(:agent, write_deliverable: "")
    assert_equal "error", empty.fetch(:key)

    present = action_for_terminal_active(:agent, write_deliverable: "Architecture\n")
    assert_equal "archived", present.fetch(:key)
    assert_nil present.fetch(:command)
  end

  def test_terminal_council_complete_requires_non_empty_deliverable
    missing = action_for_terminal_active(:council, write_deliverable: false)
    assert_equal "error", missing.fetch(:key)

    present = action_for_terminal_active(:council, write_deliverable: "Reviewed\n")
    assert_equal "archived", present.fetch(:key)
  end

  # Generic stale-agent "orphaned placeholder" branch: a no-pid AGENT_WORKING
  # marker (`pid_alive: nil`, no `pid` attr) whose state-file mtime is older
  # than the grace window classifies as :agent_orphaned -> error, mirroring the
  # daemon's StaleAgentHealer before it ticks. The matrix test only covers the
  # pid_alive:false (agent_died) half of plan IU-4's "stale ⇒ error"
  # requirement; this pins the past-grace placeholder half for the generic route.
  def test_generic_stale_agent_orphaned_placeholder_classifies_as_error
    orphaned = action_for(
      "gather", :agent_working, {},
      pid_alive: nil,
      state_file_mtime: Time.now - 600,
      agent_marker_grace_sec: 300
    )

    assert_equal "error", orphaned.key
    assert_nil orphaned.command
  end

  def test_generic_complete_dispatches_at_policy_decision_level
    action = action_for("gather", :complete)

    assert_equal "ready_to_advance", action.key
    assert_equal :dispatch, policy_decision(action)
  end

  # The ONLY generic path that auto-advances a stage with ZERO prior execution:
  # a markerless inert entry classifies as ready_to_advance and the daemon
  # dispatches `hive approve --from 1-intake`. The matrix test pins the
  # classification key but never runs a policy_decision on this row, so a
  # regression dropping ready_to_advance from ADVANCE_ACTIONS or widening the
  # `:none` advance guard to non-entry stages would change auto-advance behavior
  # with the suite still green. This pins the daemon-decision outcome.
  def test_generic_inert_entry_none_dispatches_at_policy_decision_level
    action = action_for("intake", :none)

    assert_equal "ready_to_advance", action.key
    assert_equal "hive approve #{SLUG} --from 1-intake --force", action.command
    assert_equal :dispatch, policy_decision(action)
  end

  def test_generic_terminal_complete_and_waiting_do_not_dispatch
    terminal = action_for("report", :complete)
    assert_equal "archived", terminal.key
    assert_equal :skip, policy_decision(terminal)

    waiting = action_for("gather", :waiting)
    assert_equal "needs_input", waiting.key
    assert_equal :record_baseline, policy_decision(waiting)
  end

  def test_generic_multistage_complete_rows_emit_advance_commands
    %w[intake gather].each do |stage_name|
      action = action_for(stage_name, :complete)

      assert_equal "ready_to_advance", action.key
      assert_equal :dispatch, policy_decision(action)
      assert_match(/\Ahive approve #{SLUG} --from \d+-#{stage_name}\z/, action.command)
    end
  end

  def test_generic_command_includes_project_only_when_needed
    with_research_task("gather") do |task|
      action = Hive::TaskAction.for(
        task,
        marker(:complete),
        project_name: "research-proj",
        project_count: 2
      )

      assert_equal "hive approve #{SLUG} --project research-proj --from 2-gather", action.command
    end
  end

  def test_generic_command_omits_project_for_single_project_box
    with_research_task("gather") do |task|
      action = Hive::TaskAction.for(
        task,
        marker(:complete),
        project_name: "research-proj",
        project_count: 1
      )

      assert_equal "hive approve #{SLUG} --from 2-gather", action.command,
                   "--project must be absent when only one project exists, even with a project_name set"
    end
  end

  def test_generic_run_command_carries_stage_only_on_collision
    no_collision = action_for("gather", :none)
    assert_equal "hive run #{SLUG}", no_collision.command,
                 "generic run command must NOT carry --stage absent a slug collision"

    with_collision = action_for("gather", :none, stage_collision: true)
    assert_equal "hive run #{SLUG} --stage 2-gather", with_collision.command,
                 "generic run command must carry --stage when status.rb flags a slug collision"
  end

  def test_draft_pr_handoff_recovery_is_manual_run_and_never_daemon_dispatched
    action = action_for(
      "gather", :error,
      { "reason" => "draft_pr_handoff_failed" }
    )

    assert_equal "recover_draft_pr", action.key
    assert_equal "hive run #{SLUG}", action.command
    assert_equal :skip, policy_decision(action)
  end

  def test_generic_markerless_non_entry_row_surfaces_dispatchable_run_command
    action = action_for("gather", :none)

    assert_equal "ready_to_run", action.key
    assert_equal "Ready to run", action.label
    assert_equal "hive run #{SLUG}", action.command
    assert_equal :dispatch, policy_decision(action)
  end

  def test_generic_unknown_resting_marker_surfaces_dispatchable_run_command
    # Two semantically distinct unknown markers pin the contract that every
    # non-{complete,waiting,none} marker hits the `else` arm -> generic_ready_to_run.
    # A second sample guards against an accidental future `when` clause that
    # special-cases one marker name while leaving the catch-all intact.
    %i[synthetic_resting custom_checkpoint].each do |marker_name|
      action = action_for("gather", marker_name)

      assert_equal "ready_to_run", action.key, "#{marker_name} should classify as ready_to_run"
      assert_equal "Ready to run", action.label, "#{marker_name} should label as Ready to run"
      assert_equal "hive run #{SLUG}", action.command, "#{marker_name} should surface hive run"
      assert_equal :dispatch, policy_decision(action), "#{marker_name} should auto-dispatch"
    end
  end

  # One workflow, both sides of the entry-vs-middle `:none` split asserted
  # together so an off-by-one on `stages.first` can't pass: only the inert entry
  # stage advances; the middle (agent) stage surfaces a run command.
  def test_generic_markerless_entry_advances_but_middle_runs
    entry = action_for("intake", :none)
    assert_equal "ready_to_advance", entry.key
    assert_equal "hive approve #{SLUG} --from 1-intake --force", entry.command

    middle = action_for("gather", :none)
    assert_equal "ready_to_run", middle.key
    assert_equal "Ready to run", middle.label
    assert_equal "hive run #{SLUG}", middle.command
  end

  # Discriminating coverage for the `:none` advance guard
  # `!terminal && stage.kind == :inert`. U6.6 dropped the earlier `entry &&`
  # conjunct: an inert NON-entry middle stage must advance, because
  # `Resolver.resolve` raises `StageError` for `kind: :inert`, so routing it
  # to `hive run` would strand the task (neither runnable nor advanceable).
  # agent_entry_workflow separates kind from position: a non-inert (`:agent`)
  # ENTRY runs; an inert NON-entry middle advances.
  def test_generic_markerless_non_inert_runs_and_inert_middle_advances
    # `stage.kind == :inert` conjunct: a markerless `:agent` ENTRY must run its
    # agent, not be approved past it. Dropping the kind check would advance here.
    agent_entry = action_for("draft", :none, descriptor: agent_entry_workflow)
    assert_equal "ready_to_run", agent_entry.key
    assert_equal "Ready to run", agent_entry.label
    assert_equal "hive run #{SLUG}", agent_entry.command,
                 "a markerless :agent entry must run, not advance"

    # An inert, non-entry, non-terminal stage advances rather than stranding:
    # the resolver has no runner for `kind: :inert`, so `hive run` would leave
    # the task unable to either run or advance. Routing it to ready_to_advance
    # (the dropped entry-only restriction) keeps it moving.
    inert_middle = action_for("hold", :none, descriptor: agent_entry_workflow)
    assert_equal "ready_to_advance", inert_middle.key
    assert_equal "Ready to advance", inert_middle.label
    assert_equal "hive approve #{SLUG} --from 2-hold --force", inert_middle.command,
                 "an inert non-entry middle stage must advance with --force, not strand on hive run " \
                 "or dead-loop on approve's terminal-marker gate"
    assert_equal :dispatch, policy_decision(inert_middle)
  end

  def test_generic_entry_stage_waiting_surfaces_run_command
    action = action_for("intake", :waiting)

    assert_equal "needs_input", action.key
    assert_equal "Needs your input", action.label
    assert_equal "hive run #{SLUG}", action.command
  end

  def council_workflow
    Hive::Workflow.new(
      id: :council_status,
      stages: [
        Hive::Workflow::Stage.new(name: "draft", index: 1, state_file: "draft.md", kind: :agent, skill: "/draft"),
        Hive::Workflow::Stage.new(
          name: "review",
          index: 2,
          state_file: "review.md",
          kind: :council,
          reviewers: [ Hive::Workflow::Reviewer.new(name: "one", prompt: "Review.") ],
          council: Hive::Workflow::Council.new(quorum: 1)
        ),
        Hive::Workflow::Stage.new(name: "done", index: 3, state_file: "done.md", kind: :inert)
      ]
    )
  end

  def human_workflow
    Hive::Workflow.new(
      id: :human_status,
      stages: [
        Hive::Workflow::Stage.new(name: "draft", index: 1, state_file: "draft.md", kind: :agent, skill: "/draft"),
        Hive::Workflow::Stage.new(
          name: "approval", index: 2, state_file: "approval.md", kind: :human,
          outcomes: {
            "approve" => Hive::Workflow::Outcome.new(name: "approve", complete: true, artifact: "draft.md"),
            "reject" => Hive::Workflow::Outcome.new(name: "reject", to: "draft")
          }.freeze
        )
      ]
    )
  end

  def terminal_active_workflow(kind)
    terminal = if kind == :council
      Hive::Workflow::Stage.new(
        name: "produce",
        index: 2,
        state_file: "status.md",
        kind: :council,
        deliverable: "architecture.md",
        reviewers: [ Hive::Workflow::Reviewer.new(name: "one", prompt: "Review.") ],
        council: Hive::Workflow::Council.new(quorum: 1)
      )
    else
      Hive::Workflow::Stage.new(
        name: "produce",
        index: 2,
        state_file: "status.md",
        kind: :agent,
        skill: "/ship",
        deliverable: "architecture.md"
      )
    end

    Hive::Workflow.new(
      id: :"terminal_#{kind}",
      stages: [
        Hive::Workflow::Stage.new(name: "inbox", index: 1, state_file: "idea.md", kind: :inert),
        terminal
      ]
    )
  end

  def action_for_terminal_active(kind, write_deliverable:)
    descriptor = terminal_active_workflow(kind)
    with_research_task("produce", descriptor: descriptor) do |task|
      if write_deliverable != false
        File.write(File.join(task.folder, "architecture.md"), write_deliverable)
      end
      action = Hive::TaskAction.for(task, marker(:complete))
      return { key: action.key, command: action.command }
    end
  end

  # A degenerate single-stage workflow has its only stage as both entry and
  # terminal: a markerless inert terminal stage must NOT offer `hive approve`
  # (nowhere to advance) NOR `hive run` (a terminal inert stage has no runner —
  # Resolver raises StageError). A task parked there is finished, so it
  # classifies as archived with no command.
  def test_generic_degenerate_single_stage_markerless_terminal_classifies_archived
    action = action_for("only", :none, descriptor: single_stage_workflow)

    assert_equal "archived", action.key
    assert_equal "Archived", action.label
    assert_nil action.command
    refute_equal :dispatch, policy_decision(action)
  end
end
