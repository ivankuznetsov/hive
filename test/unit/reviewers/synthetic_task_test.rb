require "test_helper"
require "hive/reviewers"

# Direct coverage for Hive::Reviewers::SyntheticTask and the
# Hive::Reviewers.synthetic_task_for(ctx) factory. This struct is the
# task-shaped facade every 5-review sub-spawn (reviewers, triage,
# ci-fix, browser-test) hands to Hive::Stages::Base.spawn_agent — drift
# in its shape would silently break four spawn sites at once.
class ReviewersSyntheticTaskTest < Minitest::Test
  include HiveTestHelper

  def make_ctx(dir)
    Hive::Reviewers::Context.new(
      worktree_path: dir,
      task_folder: File.join(dir, ".hive-state", "stages", "5-review", "synth-task"),
      default_branch: "main",
      pass: 1
    )
  end

  def test_synthetic_task_for_returns_struct_with_folder_from_ctx
    with_tmp_dir do |dir|
      ctx = make_ctx(dir)
      task = Hive::Reviewers.synthetic_task_for(ctx)
      assert_equal ctx.task_folder, task.folder
    end
  end

  def test_synthetic_task_for_state_file_is_task_md_under_task_folder
    with_tmp_dir do |dir|
      ctx = make_ctx(dir)
      task = Hive::Reviewers.synthetic_task_for(ctx)
      assert_equal File.join(ctx.task_folder, "task.md"), task.state_file
    end
  end

  def test_synthetic_task_for_log_dir_is_logs_under_task_folder
    with_tmp_dir do |dir|
      ctx = make_ctx(dir)
      task = Hive::Reviewers.synthetic_task_for(ctx)
      assert_equal File.join(ctx.task_folder, "logs"), task.log_dir
    end
  end

  def test_synthetic_task_for_stage_name_is_5_review
    with_tmp_dir do |dir|
      ctx = make_ctx(dir)
      task = Hive::Reviewers.synthetic_task_for(ctx)
      assert_equal "5-review", task.stage_name,
                   "every sub-spawn under the 5-review runner identifies as 5-review"
    end
  end

  def test_synthetic_task_for_project_root_defaults_to_nil
    with_tmp_dir do |dir|
      ctx = make_ctx(dir)
      task = Hive::Reviewers.synthetic_task_for(ctx)
      assert_nil task.project_root,
                 "project_root is nil when the keyword is not passed"
    end
  end

  def test_synthetic_task_for_accepts_explicit_project_root
    with_tmp_dir do |dir|
      ctx = make_ctx(dir)
      task = Hive::Reviewers.synthetic_task_for(ctx, project_root: "/x")
      assert_equal "/x", task.project_root
    end
  end

  def test_synthetic_task_struct_is_keyword_init
    # keyword_init: true means positional args raise ArgumentError —
    # documents the constructor contract so a future drop of the kwarg
    # flag (which would silently accept positional args) fails this
    # test.
    assert_raises(ArgumentError) do
      Hive::Reviewers::SyntheticTask.new("folder", "state", "log", "5-review", nil)
    end
  end
end
