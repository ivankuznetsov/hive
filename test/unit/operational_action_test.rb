require "test_helper"
require "hive/commands/init"
require "hive/commands/status"
require "digest"
require "hive/operational_action"
require "hive/stages/base"
require "hive/task_meta"

class OperationalActionTest < Minitest::Test
  include HiveTestHelper

  FAKE_BIN = File.expand_path("../fixtures/fake-claude", __dir__)

  def test_task_recheck_reproduces_status_token_and_rejects_marker_rotation
    with_tmp_global_config do
      with_tmp_dir do |project_root|
        hive_state = File.join(project_root, ".hive-state")
        folder = File.join(hive_state, "stages", "2-brainstorm", "advance-260720-abcd")
        FileUtils.mkdir_p(folder)
        File.write(File.join(hive_state, "config.yml"), Hive::Config::DEFAULTS.to_yaml)
        state_file = File.join(folder, "brainstorm.md")
        File.write(state_file, "# Brainstorm\n<!-- COMPLETE -->\n")
        Hive::Config.register_project(name: "demo", path: project_root, repository_identity: nil)
        project = Hive::Config.registered_projects.fetch(0)
        status_action = Hive::Commands::Status.new(
          json: true, operational: true
        ).operational_payload([ project ]).fetch("tasks").first.fetch("action")
        task = Hive::Task.new(folder)

        direct_action = Hive::OperationalAction.descriptor_for_task(task, project: "demo")
        assert_equal status_action, direct_action
        assert_equal status_action, Hive::OperationalAction.assert_current!(
          task,
          project: "demo",
          action_id: status_action.fetch("action_id"),
          target: status_action.fetch("target"),
          observation_token: status_action.fetch("observation_token")
        )

        Hive::Markers.set(state_file, :waiting)
        assert_raises(Hive::StaleOperationalObservation) do
          Hive::OperationalAction.assert_current!(
            task,
            project: "demo",
            action_id: status_action.fetch("action_id"),
            target: status_action.fetch("target"),
            observation_token: status_action.fetch("observation_token")
          )
        end
      end
    end
  end

  def test_unknown_action_is_rejected_before_task_resolution
    executor = Hive::OperationalAction::Executor.new

    error = assert_raises(Hive::OperationalActionUsageError) do
      executor.execute(action_id: "shell.exec", target: "demo:task", observation_token: "a" * 64)
    end

    assert_match(/unknown operational action/, error.message)
  end

  def test_invalid_target_is_rejected_before_project_lookup
    executor = Hive::OperationalAction::Executor.new

    [ "", "demo", "demo:", "demo:path/to-task" ].each do |target|
      error = assert_raises(Hive::OperationalActionUsageError, target) do
        executor.execute(
          action_id: Hive::OperationalAction::ACTION_ID,
          target: target,
          observation_token: "a" * 64
        )
      end
      assert_match(/exact project:slug/, error.message)
    end
  end

  def test_task_resolution_preserves_ambiguity_and_converts_missing_task_to_stale
    require "hive/task_resolver"
    executor = Hive::OperationalAction::Executor.new
    ambiguous = Object.new
    ambiguous.define_singleton_method(:resolve) do
      raise Hive::AmbiguousSlug.new("ambiguous", slug: "task", candidates: [])
    end
    with_replaced_singleton_method(Hive::TaskResolver, :new, ->(*_args, **_kwargs) { ambiguous }) do
      assert_raises(Hive::AmbiguousSlug) { executor.send(:resolve_task, "task", "demo") }
    end

    missing = Object.new
    missing.define_singleton_method(:resolve) { raise Hive::InvalidTaskPath, "task disappeared" }
    error = with_replaced_singleton_method(
      Hive::TaskResolver, :new, ->(*_args, **_kwargs) { missing }
    ) do
      assert_raises(Hive::StaleOperationalObservation) do
        executor.send(:resolve_task, "task", "demo")
      end
    end
    assert_match(/task disappeared/, error.message)
  end

  def test_dispatch_rejects_a_state_without_a_routine_action
    error = assert_raises(Hive::StaleOperationalObservation) do
      Hive::OperationalAction::Executor.new.send(
        :dispatch, nil, { "action" => "wait" }, "demo", nil
      )
    end

    assert_match(/no confirmation-free operational action/, error.message)
  end

  def test_result_reports_archived_when_the_task_disappears_after_action
    executor = Hive::OperationalAction::Executor.new
    executor.define_singleton_method(:resolve_task) do |*|
      raise Hive::StaleOperationalObservation, "archived"
    end

    assert_equal({
      "task_state" => "archived", "stage" => nil, "marker" => nil
    }, executor.send(:result_for, "demo", "task"))
  end

  def test_executor_advances_a_fresh_stage_action_through_the_real_command_path
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        capture_io { Hive::Commands::Init.new(project_root).call }
        set_project_claude_mode(project_root, "headless")
        project = Hive::Config.registered_projects.find do |entry|
          File.expand_path(entry.fetch("path")) == File.expand_path(project_root)
        end
        refute_nil project
        slug = "advance-260720-real"
        brainstorm = File.join(project_root, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(brainstorm)
        File.write(File.join(brainstorm, "brainstorm.md"), "# Brainstorm\n<!-- COMPLETE -->\n")
        action = Hive::OperationalAction.descriptor_for_task(
          Hive::Task.new(brainstorm), project: project.fetch("name")
        )
        plan = File.join(project_root, ".hive-state", "stages", "3-plan", slug)

        result = nil
        with_env(
          "HIVE_CLAUDE_BIN" => FAKE_BIN,
          "HIVE_CODEX_BIN" => FAKE_BIN,
          "HIVE_FAKE_CLAUDE_WRITE_FILE" => File.join(plan, "plan.md"),
          "HIVE_FAKE_CLAUDE_WRITE_CONTENT" => "# Plan\n<!-- WAITING -->\n"
        ) do
          capture_io do
            result = Hive::OperationalAction::Executor.new.execute(
              action_id: action.fetch("action_id"),
              target: action.fetch("target"),
              observation_token: action.fetch("observation_token")
            )
          end
        end

        assert File.directory?(plan)
        assert_equal "3-plan", result.fetch("stage")
        assert_equal "needs_input", result.fetch("task_state")
        assert_equal "waiting", result.fetch("marker")
      end
    end
  end

  def test_executor_runs_and_approves_generic_actions_through_real_command_paths
    descriptor = dispatch_workflow
    with_registered_workflow(descriptor) do
      with_tmp_global_config do
        with_tmp_git_repo do |project_root|
          capture_io { Hive::Commands::Init.new(project_root).call }
          config_path = File.join(project_root, ".hive-state", "config.yml")
          config = YAML.safe_load(File.read(config_path))
          config.fetch("daemon")["enabled"] = false
          File.write(config_path, config.to_yaml)
          project = Hive::Config.registered_projects.find do |entry|
            File.expand_path(entry.fetch("path")) == File.expand_path(project_root)
          end
          refute_nil project
          slug = "generic-action-260720-real"
          intake = File.join(project_root, ".hive-state", "stages", "1-intake", slug)
          FileUtils.mkdir_p(intake)
          Hive::TaskMeta.write(
            intake, id: 101, slug: slug,
            display_name: "Generic operational action", workflow: descriptor.id.to_s
          )
          executor = Hive::OperationalAction::Executor.new
          ran = []
          original = Hive::Stages::Base.method(:spawn_agent)
          Hive::Stages::Base.define_singleton_method(:spawn_agent) do |task, **_kwargs|
            ran << task.stage_name
            File.write(task.state_file, "# #{task.stage_name}\n<!-- COMPLETE -->\n")
            { status: :complete }
          end

          begin
            first = operational_action_for(project, slug)
            run_result = nil
            with_attempt_context(
              attempt_id: "operational-run-attempt",
              task_generation: "operational-run-generation"
            ) do
              capture_io do
                run_result = executor.execute(
                  action_id: first.fetch("action_id"),
                  target: first.fetch("target"),
                  observation_token: first.fetch("observation_token")
                )
              end
            end
            assert_equal [ "intake" ], ran
            assert_equal "ready_to_advance", run_result.fetch("task_state")

            second = operational_action_for(project, slug)
            approve_result = nil
            capture_io do
              approve_result = executor.execute(
                action_id: second.fetch("action_id"),
                target: second.fetch("target"),
                observation_token: second.fetch("observation_token")
              )
            end

            gather = File.join(project_root, ".hive-state", "stages", "2-gather", slug)
            assert File.directory?(gather)
            assert_equal "2-gather", approve_result.fetch("stage")
            assert_equal "ready_to_run", approve_result.fetch("task_state")
            assert_equal "none", approve_result.fetch("marker")
          ensure
            Hive::Stages::Base.define_singleton_method(:spawn_agent, original)
          end
        end
      end
    end
  end

  def test_status_keeps_dispatch_mtime_distinct_from_markerless_action_observation
    descriptor = dispatch_workflow
    with_registered_workflow(descriptor) do
      with_tmp_global_config do
        with_tmp_git_repo do |project_root|
          capture_io { Hive::Commands::Init.new(project_root).call }
          project = Hive::Config.registered_projects.find do |entry|
            File.expand_path(entry.fetch("path")) == File.expand_path(project_root)
          end
          slug = "generic-mtime-260721-real"
          folder = File.join(project_root, ".hive-state", "stages", "1-intake", slug)
          FileUtils.mkdir_p(folder)
          Hive::TaskMeta.write(
            folder, id: 202, slug: slug,
            display_name: "Generic mtime split", workflow: descriptor.id.to_s
          )
          meta_path = File.join(folder, "meta.yml")
          File.utime(Time.now - 10, Time.now - 10, meta_path)
          File.utime(Time.now + 10, Time.now + 10, folder)

          row = Hive::Commands::Status.new.json_payload([ project ])
            .fetch("projects").first.fetch("tasks")
            .find { |entry| entry.fetch("slug") == slug }

          assert_equal File.mtime(folder).utc.iso8601(6), row.fetch("mtime"),
                       "daemon dispatch must still observe markerless stage-directory moves"
          assert_equal File.mtime(meta_path).utc.iso8601(6), row.fetch("observation_mtime"),
                       "action tokens must use the stable markerless task metadata"
          assert_equal Hive::OperationalAction.descriptor_for_task(
            Hive::Task.new(folder), project: project.fetch("name")
          ), Hive::OperationalAction.descriptor(project: project.fetch("name"), row: row)
        end
      end
    end
  end

  private

  def operational_action_for(project, slug)
    row = Hive::Commands::Status.new(json: true, operational: true)
      .operational_payload([ project ], scheduler_snapshot: nil)
      .fetch("tasks")
      .find { |entry| entry.dig("identity", "slug") == slug }
    refute_nil row
    refute_nil row.fetch("action")
    row.fetch("action")
  end
end
