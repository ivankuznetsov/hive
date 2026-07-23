require "test_helper"
require "hive/gh"
require "hive/babysitter/worktree"

class BabysitterWorktreeTest < Minitest::Test
  include HiveTestHelper

  def test_materialize_fetches_head_and_adds_dedicated_worktree_branch
    with_tmp_dir do |dir|
      project = { "name" => "demo", "path" => dir, "hive_state_path" => File.join(dir, ".hive-state") }
      pr = { "number" => 42, "headRefName" => "feature" }
      calls = []
      status = Hive::Gh::CommandStatus.new(exitstatus: 0)

      with_replaced_singleton_method(Open3, :capture3, lambda { |*cmd|
        calls << cmd
        [ "", "", status ]
      }) do
        result = Hive::Babysitter::Worktree.materialize(project, pr)
        assert_equal File.join(project.fetch("hive_state_path"), "babysitter", "worktrees", "42"), result.path
        assert_equal "hive-babysitter/pr-42", result.branch
      end

      assert calls.any? { |cmd| cmd.include?("fetch") && cmd.include?("+pull/42/head:refs/hive-babysitter/pr-42") },
             "expected force-updating `git fetch origin +pull/42/head:...` so rebased PR heads do not wedge babysitter"
      assert calls.any? { |cmd| cmd.include?("worktree") && cmd.include?("-B") && cmd.include?("hive-babysitter/pr-42") }
    end
  end

  def test_path_resolves_relative_state_path_from_project_root
    with_tmp_dir do |dir|
      project = { "name" => "demo", "path" => dir, "hive_state_path" => "state" }
      pr = { "number" => 42 }

      assert_equal File.join(dir, "state", "babysitter", "worktrees", "42"),
                   Hive::Babysitter::Worktree.new(project, pr).path
    end
  end
end
