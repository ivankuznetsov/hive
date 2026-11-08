require "test_helper"
require "hive/stages/execute"
require "hive/task"

class ExecuteEntryTest < Minitest::Test
  include HiveTestHelper

  def test_wrong_branch_stops_before_launch_without_changing_pointer
    with_execute_worktree do |task, path|
      run!("git", "-C", path, "switch", "-c", "unrelated")
      assert_entry_rejected(task, path, "branch_mismatch")
    end
  end

  def test_rewritten_history_stops_before_launch_without_guessing_a_baseline
    with_execute_worktree do |task, path|
      run!("git", "-C", path, "commit", "--amend", "-m", "rewritten initial history")
      assert_entry_rejected(task, path, "head_not_descendant")
    end
  end

  def test_missing_baseline_object_stops_before_launch
    with_execute_worktree do |task, path|
      pointer = Hive::Worktree.read_pointer(task.folder)
      pointer["execute_base_head"] = "f" * 40
      File.write(task.worktree_yml_path, pointer.to_yaml)
      assert_entry_rejected(task, path, "worktree_git_failed")
    end
  end

  def test_valid_old_base_and_existing_progress_can_continue
    with_execute_worktree do |task, path|
      run!("git", "-C", task.project_root, "commit", "--allow-empty", "-m", "unrelated main change")
      run!("git", "-C", path, "commit", "--allow-empty", "-m", "existing task progress")
      launched = 0
      with_replaced_singleton_method(Hive::Stages::Execute, :spawn_implementation, lambda { |*_, **|
        launched += 1
        { status: :ok }
      }) do
        assert_equal :execute_complete, Hive::Stages::Execute.run_pass(task, {}, path)[:status]
      end
      assert_equal 1, launched
    end
  end

  def test_branch_changes_during_execution_are_still_rejected
    git_run = method(:run!)
    with_execute_worktree do |task, path|
      launched = 0
      with_replaced_singleton_method(Hive::Stages::Execute, :spawn_implementation, lambda { |*_, **|
        launched += 1
        git_run.call("git", "-C", path, "switch", "-c", "wrong-after-spawn")
        { status: :ok }
      }) do
        assert_equal :execute_waiting, Hive::Stages::Execute.run_pass(task, {}, path)[:status]
      end
      assert_equal 1, launched
      assert_equal "branch_mismatch", Hive::Markers.current(task.state_file).attrs["reason"]
    end
  end

  private

  def assert_entry_rejected(task, path, reason)
    original_pointer = File.binread(task.worktree_yml_path)
    launched = 0
    with_replaced_singleton_method(Hive::Stages::Execute, :spawn_implementation, lambda { |*_, **|
      launched += 1
      { status: :ok }
    }) do
      Hive::Stages::Execute.run_pass(task, {}, path)
    end
    assert_equal 0, launched, "invalid execution checkout must not consume an agent turn"
    assert_equal reason, Hive::Markers.current(task.state_file).attrs["reason"]
    assert_equal original_pointer, File.binread(task.worktree_yml_path)
  end

  def with_execute_worktree
    with_tmp_git_repo do |project|
      folder = File.join(project, ".hive-state", "stages", "4-execute", "entry-test")
      FileUtils.mkdir_p(folder)
      task = Hive::Task.new(folder)
      File.write(File.join(folder, "plan.md"), "# Implement the feature\n")
      with_tmp_dir do |root|
        path = File.join(root, "worktree")
        run!("git", "-C", project, "worktree", "add", "-b", task.slug, path)
        File.write(task.worktree_yml_path, {
          "path" => path, "branch" => task.slug,
          "execute_base_head" => Hive::GitOps.new(path).head_sha
        }.to_yaml)
        yield task, path
      end
    end
  end
end
