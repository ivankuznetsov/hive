require "test_helper"
require "hive/commands/init"
require "hive/commands/new"
require "hive/git_ops"
require "hive/worktree"

# Regression test for the orphan-branch model: hive-state mutations must NEVER
# materialise inside a feature worktree spawned from master, even after the
# feature worktree pulls/merges master. This is the "skip worktree" guarantee
# delivered by the orphan branch (no skip-worktree gymnastics required).
class SkipWorktreeIsolationTest < Minitest::Test
  include HiveTestHelper

  def test_hive_state_never_appears_in_feature_worktree
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        project = File.basename(dir)
        capture_io { Hive::Commands::New.new(project, "isolation test").call }

        worktree_root = Dir.mktmpdir("worktree-root")
        wt = Hive::Worktree.new(dir, "feat-iso", worktree_root: worktree_root)
        wt.create!("feat-iso", default_branch: "master")
        refute File.exist?(File.join(wt.path, ".hive-state")),
               ".hive-state must not be visible inside feature worktree"

        # Add another hive-state commit (new task), then check feature worktree
        # is still clean (no untracked files originating from .hive-state).
        capture_io { Hive::Commands::New.new(project, "second task").call }
        status_out = `git -C #{wt.path} status --porcelain`.strip
        assert_empty status_out, "feature worktree must remain clean: #{status_out.inspect}"

        # `git pull` from master shouldn't pull anything hive-state related;
        # master's only hive-related change is the chore .gitignore commit.
        master_log = `git -C #{dir} log --format=%s master`.strip.split("\n")
        hive_msgs = master_log.select { |m| m.start_with?("hive:") }
        assert_empty hive_msgs
      ensure
        FileUtils.rm_rf(worktree_root) if worktree_root
      end
    end
  end
end
