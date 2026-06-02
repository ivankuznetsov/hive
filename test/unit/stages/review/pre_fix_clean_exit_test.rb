require "test_helper"
require "hive/stages/review"

class HiveStagesReviewPreFixCleanExitTest < Minitest::Test
  include HiveTestHelper

  FakeTask = Struct.new(:folder, :slug, keyword_init: true)

  def fake_task
    FakeTask.new(folder: Dir.mktmpdir("hive-review-task"), slug: "demo-260530-aaaa")
  end

  def teardown
    FileUtils.rm_rf(@task.folder) if @task
  end

  def test_prepare_worktree_for_fix_returns_clean_when_cleanup_reports_clean
    @task = fake_task
    status_calls = 0

    with_replaced_singleton_method(Hive::Stages::Review, :worktree_status, lambda { |_path|
      status_calls += 1
      :dirty
    }) do
      with_replaced_singleton_method(Hive::Stages::CleanExit, :run!, ->(**_kwargs) { { status: :clean } }) do
        result = Hive::Stages::Review.send(:prepare_worktree_for_fix, @task, {}, "/worktree")

        assert_equal :clean, result
      end
    end

    assert_equal 1, status_calls
  end

  def test_prepare_worktree_for_fix_maps_cleanup_git_failure_to_status_failure
    @task = fake_task

    with_replaced_singleton_method(Hive::Stages::Review, :worktree_status, ->(_path) { :dirty }) do
      with_replaced_singleton_method(Hive::Stages::CleanExit, :run!, lambda { |**_kwargs|
        { status: :git_failed, message: "git status exploded" }
      }) do
        result = Hive::Stages::Review.send(:prepare_worktree_for_fix, @task, {}, "/worktree")

        assert_equal [ :status_failed, "git status exploded" ], result
      end
    end
  end

  def test_prepare_worktree_for_fix_maps_cleanup_config_error_to_status_failure
    @task = fake_task

    with_replaced_singleton_method(Hive::Stages::Review, :worktree_status, ->(_path) { :dirty }) do
      with_replaced_singleton_method(Hive::Stages::CleanExit, :run!, lambda { |**_kwargs|
        raise Hive::ConfigError, "bad sign_policy"
      }) do
        result = Hive::Stages::Review.send(:prepare_worktree_for_fix, @task, {}, "/worktree")

        assert_equal [ :status_failed, "invalid auto-commit config: bad sign_policy" ], result
      end
    end
  end

  def test_emit_pre_fix_clean_exit_event_is_best_effort
    @task = fake_task

    with_replaced_singleton_method(Hive::Events, :emit, ->(**_kwargs) { raise IOError, "blocked" }) do
      result = Hive::Stages::Review.send(
        :emit_pre_fix_clean_exit_event,
        @task,
        { head: "abc123", paths: [ "wiki/page.md" ] }
      )

      assert_nil result
    end
  end
end
