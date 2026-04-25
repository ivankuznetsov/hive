require "test_helper"
require "hive/git_ops"

class GitOpsTest < Minitest::Test
  include HiveTestHelper

  def test_default_branch_from_local_head
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      assert_equal "master", ops.default_branch
    end
  end

  def test_default_branch_falls_back_to_master_constant
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      branch = ops.default_branch
      refute_empty branch
    end
  end

  def test_hive_state_init_creates_orphan_branch_and_worktree
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      assert_equal :created, ops.hive_state_init
      assert ops.hive_state_branch_exists?, "hive/state branch should exist"
      assert File.directory?(File.join(dir, ".hive-state")), ".hive-state worktree should be created"
      Hive::Stages::DIRS.each do |stage|
        assert File.directory?(File.join(dir, ".hive-state", "stages", stage)),
               "stage dir #{stage} should exist"
      end
      log = `git -C #{dir} log --format=%s hive/state`.strip
      assert_includes log, "hive: bootstrap"
    end
  end

  def test_hive_state_init_idempotent
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      assert_equal :existed, ops.hive_state_init, "second init should report :existed"
    end
  end

  def test_add_hive_state_to_master_gitignore
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      assert_equal :added, ops.add_hive_state_to_master_gitignore!
      content = File.read(File.join(dir, ".gitignore"))
      assert_includes content, "/.hive-state/"
      assert_equal :already, ops.add_hive_state_to_master_gitignore!, "should be idempotent on re-run"
    end
  end

  def test_hive_commit_creates_commit_when_diff_present
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      task_dir = File.join(dir, ".hive-state", "stages", "1-inbox", "foo-260424-aaaa")
      FileUtils.mkdir_p(task_dir)
      File.write(File.join(task_dir, "idea.md"), "# Foo\n<!-- WAITING -->\n")
      result = ops.hive_commit(stage_name: "1-inbox", slug: "foo-260424-aaaa", action: "captured")
      assert_equal :committed, result
      log = `git -C #{File.join(dir, ".hive-state")} log --format=%s -1`.strip
      assert_equal "hive: 1-inbox/foo-260424-aaaa captured", log
    end
  end

  def test_hive_commit_skips_when_diff_empty
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      result = ops.hive_commit(stage_name: "1-inbox", slug: "x", action: "noop")
      assert_equal :nothing_to_commit, result
    end
  end

  def test_master_log_unaffected_by_hive_commits
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      ops.add_hive_state_to_master_gitignore!
      File.write(File.join(dir, ".hive-state", "stages", "1-inbox", "x.md"), "x")
      ops.hive_commit(stage_name: "1-inbox", slug: "x", action: "captured")

      master_log = `git -C #{dir} log --format=%s master`.strip.split("\n")
      hive_msgs = master_log.select { |m| m.start_with?("hive:") }
      assert_empty hive_msgs, "master must not contain hive: commits"
    end
  end
end
