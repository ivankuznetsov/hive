require "test_helper"
require "hive/markers"
require "hive/stages/artifacts"
require "hive/task"

class StagesArtifactsTest < Minitest::Test
  def test_markerless_artifacts_stage_spawns_agent_and_returns_complete_marker
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      folder = File.join(dir, ".hive-state", "stages", "7-artifacts", "demo-260522-aaaa")
      FileUtils.mkdir_p(folder)
      task = Hive::Task.new(folder)

      calls = with_stubbed_artifacts_spawn do
        Hive::Stages::Artifacts.run!(task, {})
      end
      result = calls.fetch(:result)

      assert_equal({ commit: "artifacts_collected", status: :complete }, result)
      assert_equal 1, calls.fetch(:spawns).length
      assert File.exist?(task.state_file)
      assert_equal :complete, Hive::Markers.current(task.state_file).name
    end
  end

  def test_complete_artifacts_stage_is_idempotent
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      folder = File.join(dir, ".hive-state", "stages", "7-artifacts", "demo-260522-aaaa")
      FileUtils.mkdir_p(folder)
      task = Hive::Task.new(folder)
      Hive::Markers.set(task.state_file, :complete)

      assert_equal({ commit: nil, status: :complete }, Hive::Stages::Artifacts.run!(task, {}))
      assert_equal :complete, Hive::Markers.current(task.state_file).name
    end
  end

  private

  def with_stubbed_artifacts_spawn
    original = Hive::Stages::Artifacts.method(:spawn_artifacts_agent)
    spawns = []
    Hive::Stages::Artifacts.define_singleton_method(:spawn_artifacts_agent) do |task, cfg, prompt, profile|
      spawns << { task: task, cfg: cfg, prompt: prompt, profile: profile }
      Hive::Markers.set(task.state_file, :complete)
      { status: :complete }
    end

    { result: yield, spawns: spawns }
  ensure
    Hive::Stages::Artifacts.define_singleton_method(:spawn_artifacts_agent, original)
  end
end
