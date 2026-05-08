require "test_helper"
require "hive/config"
require "hive/markers"
require "hive/stages/brainstorm"
require "hive/stages/plan"

class HiveStagesSkillInvocationFormatTest < Minitest::Test
  include HiveTestHelper

  TaskStub = Struct.new(:project_root, :folder, :state_file, keyword_init: true)

  def with_stubbed_spawn
    captured = []
    original = Hive::Stages::Base.method(:spawn_agent)
    Hive::Stages::Base.define_singleton_method(:spawn_agent) do |task, prompt:, **kwargs|
      captured << { task: task, prompt: prompt, kwargs: kwargs }
      File.write(task.state_file, "<!-- COMPLETE -->\n")
      { status: :ok }
    end
    yield captured
  ensure
    Hive::Stages::Base.define_singleton_method(:spawn_agent) do |*args, **kwargs, &block|
      original.call(*args, **kwargs, &block)
    end
  end

  def test_brainstorm_formats_default_skill_for_pi_profile
    with_tmp_dir do |project|
      task_dir = File.join(project, ".hive-state", "stages", "2-brainstorm", "demo")
      FileUtils.mkdir_p(task_dir)
      File.write(File.join(task_dir, "idea.md"), "idea\n")
      task = TaskStub.new(
        project_root: project,
        folder: task_dir,
        state_file: File.join(task_dir, "brainstorm.md")
      )

      with_stubbed_spawn do |captured|
        Hive::Stages::Brainstorm.run!(task, { "brainstorm" => { "agent" => "pi" } })

        assert_includes captured.first[:prompt], "/skill:ce-brainstorm"
        assert_equal :pi, captured.first[:kwargs][:profile].name
      end
    end
  end

  def test_plan_formats_default_skill_for_pi_profile
    with_tmp_dir do |project|
      task_dir = File.join(project, ".hive-state", "stages", "3-plan", "demo")
      FileUtils.mkdir_p(task_dir)
      File.write(File.join(task_dir, "brainstorm.md"), "brainstorm\n")
      task = TaskStub.new(
        project_root: project,
        folder: task_dir,
        state_file: File.join(task_dir, "plan.md")
      )

      with_stubbed_spawn do |captured|
        Hive::Stages::Plan.run!(task, { "plan" => { "agent" => "pi" } })

        assert_includes captured.first[:prompt], "/skill:plan"
        assert_equal :pi, captured.first[:kwargs][:profile].name
      end
    end
  end
end
