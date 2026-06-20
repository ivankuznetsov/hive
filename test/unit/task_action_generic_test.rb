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

    running = action_for("gather", :agent_working, { "pid" => "12345" }, pid_alive: true)
    assert_equal "agent_running", running.key
    assert_nil running.command

    stale = action_for("gather", :agent_working, { "pid" => "12345" }, pid_alive: false)
    assert_equal "error", stale.key

    errored = action_for("gather", :error)
    assert_equal "error", errored.key
    assert_nil errored.command
  end

  def test_generic_complete_dispatches_at_policy_decision_level
    action = action_for("gather", :complete)

    assert_equal "ready_to_advance", action.key
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

  def test_generic_markerless_non_entry_row_surfaces_run_command_without_advance_decision
    action = action_for("gather", :none)

    assert_equal "needs_input", action.key
    assert_equal "Ready to run", action.label
    assert_equal "hive run #{SLUG}", action.command
    assert_equal :record_baseline, policy_decision(action)
  end

  def test_generic_unknown_resting_marker_surfaces_run_command_without_advance_decision
    action = action_for("gather", :synthetic_resting)

    assert_equal "needs_input", action.key
    assert_equal "Ready to run", action.label
    assert_equal "hive run #{SLUG}", action.command
    assert_equal :record_baseline, policy_decision(action)
  end

  # One workflow, both sides of the entry-vs-middle `:none` split asserted
  # together so an off-by-one on `stages.first` can't pass: only the inert entry
  # stage advances; the middle (agent) stage surfaces a run command.
  def test_generic_markerless_entry_advances_but_middle_runs
    entry = action_for("intake", :none)
    assert_equal "ready_to_advance", entry.key
    assert_equal "hive approve #{SLUG} --from 1-intake", entry.command

    middle = action_for("gather", :none)
    assert_equal "needs_input", middle.key
    assert_equal "Ready to run", middle.label
    assert_equal "hive run #{SLUG}", middle.command
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

    assert_equal "needs_input", action.key
    assert_equal "Ready to run", action.label
    assert_equal "hive run #{SLUG}", action.command
    assert_equal :record_baseline, policy_decision(action)
  end
end
