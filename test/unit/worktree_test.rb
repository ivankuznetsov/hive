require "test_helper"
require "hive/git_ops"
require "hive/worktree"

class WorktreeTest < Minitest::Test
  include HiveTestHelper

  def with_initialized_project
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      ops.add_hive_state_to_master_gitignore!
      worktree_root = File.join(File.dirname(dir), "#{File.basename(dir)}.worktrees")
      FileUtils.mkdir_p(worktree_root)
      yield(dir, worktree_root)
    ensure
      worktree_root = File.join(File.dirname(dir), "#{File.basename(dir)}.worktrees") if dir
      FileUtils.rm_rf(worktree_root) if worktree_root && File.exist?(worktree_root)
    end
  end

  def test_create_worktree_makes_branch_and_dir
    with_initialized_project do |dir, root|
      wt = Hive::Worktree.new(dir, "feat-x", worktree_root: root)
      wt.create!("feat-x", default_branch: "master")
      assert wt.exists?
      branch = `git -C #{wt.path} branch --show-current`.strip
      assert_equal "feat-x", branch
      refute File.directory?(File.join(wt.path, ".hive-state")),
             ".hive-state must not appear in feature worktree (master gitignores it)"
    end
  end

  def test_attaches_to_existing_branch
    with_initialized_project do |dir, root|
      wt1 = Hive::Worktree.new(dir, "feat-y", worktree_root: root)
      wt1.create!("feat-y", default_branch: "master")
      wt1.remove!
      wt2 = Hive::Worktree.new(dir, "feat-y", worktree_root: root)
      wt2.create!("feat-y", default_branch: "master")
      assert wt2.exists?
    end
  end

  def test_create_fails_on_double_create
    with_initialized_project do |dir, root|
      wt = Hive::Worktree.new(dir, "feat-z", worktree_root: root)
      wt.create!("feat-z", default_branch: "master")
      assert_raises(Hive::WorktreeError) do
        Hive::Worktree.new(dir, "feat-z", worktree_root: root).create!("feat-z", default_branch: "master")
      end
    end
  end

  def test_remove_clears_path_from_list
    with_initialized_project do |dir, root|
      wt = Hive::Worktree.new(dir, "feat-r", worktree_root: root)
      wt.create!("feat-r", default_branch: "master")
      wt.remove!
      refute_includes wt.list_worktree_paths, wt.path
    end
  end

  def test_pointer_validation_blocks_path_traversal
    Dir.mktmpdir do |root|
      assert_raises(Hive::WorktreeError) do
        Hive::Worktree.validate_pointer_path("/etc", root)
      end
      ok = Hive::Worktree.validate_pointer_path("#{root}/inside", root)
      assert_equal "#{root}/inside", ok
    end
  end

  def test_master_log_clean_after_feature_commits
    with_initialized_project do |dir, root|
      wt = Hive::Worktree.new(dir, "feat-q", worktree_root: root)
      wt.create!("feat-q", default_branch: "master")
      File.write(File.join(wt.path, "newfile.txt"), "x\n")
      `git -C #{wt.path} add . && git -C #{wt.path} -c user.email=t@t -c user.name=t commit -m "feat-q work"`
      hive_msgs = `git -C #{dir} log --format=%s master`.strip.split("\n").select { |m| m.start_with?("hive:") }
      assert_empty hive_msgs
    end
  end
end
