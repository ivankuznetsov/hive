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
    assert_equal "hive approve #{SLUG} --from 1-intake", fresh_entry.command

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
    # override (task_action.rb:274-279) *before* the coding_workflow? dispatch,
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
    assert_equal "hive approve #{SLUG} --from 1-intake", action.command
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
    assert_equal "hive approve #{SLUG} --from 1-intake", entry.command

    middle = action_for("gather", :none)
    assert_equal "ready_to_run", middle.key
    assert_equal "Ready to run", middle.label
    assert_equal "hive run #{SLUG}", middle.command
  end

  # Discriminating coverage for the two non-`entry`-position conjuncts of the
  # `:none` advance guard `entry && !terminal && stage.kind == :inert`. In
  # research_workflow the only inert stage is also the entry, so both conjuncts
  # move together and dropping either keeps the suite green. agent_entry_workflow
  # separates them: a non-inert (`:agent`) ENTRY and an inert NON-entry middle.
  def test_generic_markerless_non_inert_entry_and_inert_middle_run_not_advance
    # `stage.kind == :inert` conjunct: a markerless `:agent` ENTRY must run its
    # agent, not be approved past it. Dropping the kind check would advance here.
    agent_entry = action_for("draft", :none, descriptor: agent_entry_workflow)
    assert_equal "ready_to_run", agent_entry.key
    assert_equal "Ready to run", agent_entry.label
    assert_equal "hive run #{SLUG}", agent_entry.command,
                 "a markerless :agent entry must run, not advance"

    # `entry` conjunct: an inert but NON-entry, non-terminal stage must still
    # run. Dropping the entry check would wrongly advance this inert middle.
    inert_middle = action_for("hold", :none, descriptor: agent_entry_workflow)
    assert_equal "ready_to_run", inert_middle.key
    assert_equal "Ready to run", inert_middle.label
    assert_equal "hive run #{SLUG}", inert_middle.command,
                 "an inert non-entry stage must run, not advance"
  end

  def test_generic_entry_stage_waiting_surfaces_run_command
    action = action_for("intake", :waiting)

    assert_equal "needs_input", action.key
    assert_equal "Needs your input", action.label
    assert_equal "hive run #{SLUG}", action.command
  end

  # A degenerate single-stage workflow has its only stage as both entry and
  # terminal: a markerless inert entry must NOT offer `hive approve` (nowhere to
  # advance) — it falls through to the run command instead.
  def test_generic_degenerate_single_stage_markerless_entry_does_not_advance
    action = action_for("only", :none, descriptor: single_stage_workflow)

    assert_equal "ready_to_run", action.key
    assert_equal "Ready to run", action.label
    assert_equal "hive run #{SLUG}", action.command
    assert_equal :dispatch, policy_decision(action)
  end
end
