require "test_helper"
require "hive/attempts/generation"

class AttemptsGenerationTest < Minitest::Test
  include HiveTestHelper

  FakeTask = Struct.new(:id, :slug, :state_file, :stage_index, :stage_name, keyword_init: true)

  def test_stable_task_id_stage_and_artifact_identity_form_generation
    with_tmp_dir do |dir|
      state_file = File.join(dir, "task.md")
      File.write(state_file, "body\n<!-- WAITING -->\n")
      task = FakeTask.new(id: 42, slug: "task-one", state_file: state_file,
                          stage_index: 3, stage_name: "plan")

      first = Hive::Attempts::Generation.resolve(task: task, project: "demo", intended_stage: "3-plan")
      second = Hive::Attempts::Generation.resolve(task: task, project: "demo", intended_stage: "3-plan")
      next_stage = Hive::Attempts::Generation.resolve(task: task, project: "demo", intended_stage: "4-execute")

      assert_equal first.task_generation, second.task_generation
      refute_equal first.task_generation, next_stage.task_generation
      assert_equal "id:42", first.task_locator
      assert_match(/\A[0-9a-f]{64}\z/, first.progress_token)
    end
  end

  def test_legacy_locator_and_progress_change_are_deterministic
    with_tmp_dir do |dir|
      state_file = File.join(dir, "task.md")
      File.write(state_file, "one")
      task = FakeTask.new(id: nil, slug: "legacy-task", state_file: state_file,
                          stage_index: 1, stage_name: "inbox")
      one = Hive::Attempts::Generation.resolve(task: task, project: "demo", intended_stage: "1-inbox")
      File.write(state_file, "two")
      two = Hive::Attempts::Generation.resolve(task: task, project: "demo", intended_stage: "1-inbox")

      assert_equal "project:demo/slug:legacy-task", one.task_locator
      refute_equal one.progress_token, two.progress_token
      refute_equal one.task_generation, two.task_generation
    end
  end

  def test_missing_and_unreadable_artifacts_have_stable_tokens
    with_tmp_dir do |dir|
      task = FakeTask.new(id: 1, slug: "missing", state_file: File.join(dir, "missing"))
      missing = Hive::Attempts::Generation.artifact_token(task)
      assert_match(/\A[0-9a-f]{64}\z/, missing)

      File.write(task.state_file, "body")
      with_replaced_singleton_method(File, :open, ->(*_args) { raise Errno::EACCES }) do
        unreadable = Hive::Attempts::Generation.artifact_token(task)
        assert_match(/\A[0-9a-f]{64}\z/, unreadable)
        refute_equal missing, unreadable
      end
    end
  end
end
