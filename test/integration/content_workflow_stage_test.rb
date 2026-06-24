require "test_helper"
require "hive/markers"
require "hive/stages/agent"
require "hive/stages/resolver"
require "hive/task"
require "hive/task_meta"

class ContentWorkflowStageTest < Minitest::Test
  include HiveTestHelper

  SLUG = "content-stage-260620-abcd"

  EXPECTED_SKILLS = {
    "research" => "/deep-research",
    "outline" => "/seo:research",
    "draft" => "/write:writer",
    "critique" => "/write:editor",
    "done" => "/write:writer"
  }.freeze

  def test_each_content_agent_stage_renders_its_skill_and_completes
    EXPECTED_SKILLS.each do |stage_name, skill|
      with_tmp_dir do |project_root|
        task = task_for_stage(project_root, stage_name)

        with_stubbed_content_spawn(marker: "<!-- COMPLETE -->\n") do |captured|
          result = Hive::Stages::Agent.run!(task, {})

          assert_equal({ commit: "complete", status: :complete }, result)
          assert_includes captured.first.fetch(:prompt), "Use the #{skill} skill for this stage."
          assert_equal task.folder, captured.first.fetch(:kwargs).fetch(:cwd)
          assert File.file?(task.state_file), "#{stage_name} must write #{task.state_file}"
          assert_equal :complete, Hive::Markers.current(task.state_file).name
        end
      end
    end
  end

  def test_waiting_marker_maps_to_wait_action
    with_tmp_dir do |project_root|
      task = task_for_stage(project_root, "critique")

      with_stubbed_content_spawn(marker: "<!-- WAITING -->\n") do
        result = Hive::Stages::Agent.run!(task, {})

        assert_equal({ commit: "round_waiting", status: :waiting }, result)
        assert_equal :waiting, Hive::Markers.current(task.state_file).name
      end
    end
  end

  def test_terminal_done_stage_resolves_to_generic_agent_and_writes_article
    with_tmp_dir do |project_root|
      task = task_for_stage(project_root, "done")
      runner = Hive::Stages::Resolver.resolve(task, descriptor: task.workflow)

      assert_equal Hive::Stages::Agent.method(:run!), runner

      with_stubbed_content_spawn(marker: "<!-- COMPLETE -->\n") do
        result = runner.call(task, {})

        assert_equal({ commit: "complete", status: :complete }, result)
        assert_equal File.join(task.folder, "article.md"), task.state_file
        assert File.file?(task.state_file), "terminal done stage must write article.md"
      end
    end
  end

  private

  def task_for_stage(project_root, stage_name)
    descriptor = Hive::Workflows::Registry.fetch(:content)
    stage = descriptor.stage_named(stage_name)
    folder = File.join(project_root, ".hive-state", "stages", stage.dir, SLUG)
    Hive::TaskMeta.write(folder, id: 8, slug: SLUG, display_name: "Content Stage", workflow: "content")
    Hive::Task.new(folder)
  end

  def with_stubbed_content_spawn(marker:)
    captured = []
    original = Hive::Stages::Base.method(:spawn_agent)
    Hive::Stages::Base.define_singleton_method(:spawn_agent) do |task, prompt:, **kwargs|
      captured << { task: task, prompt: prompt, kwargs: kwargs }
      File.write(task.state_file, "# #{task.stage_name}\ncontent\n#{marker}")
      { status: :ok }
    end
    yield captured
  ensure
    Hive::Stages::Base.define_singleton_method(:spawn_agent, original) if original
  end
end
