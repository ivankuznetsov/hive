require "test_helper"
require "hive/commands/status"
require "hive/operational_action"

class OperationalActionTest < Minitest::Test
  include HiveTestHelper

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
end
