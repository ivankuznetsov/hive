require "test_helper"
require "yaml"
require "hive/dependency_snapshot"
require "hive/git_ops"
require "hive/task_meta"
require "hive/worktree"

# Real-git coverage for the execute-stage worktree base of a dependent task:
# `DependencySnapshot.stacked_base` selects the override and
# `Worktree#create!` resolves it, exactly as `Stages::Execute#run_init_pass`
# composes them. Live regression (2026-11-07): a prerequisite squash-merged
# into main and archived to 9-done, with its remote branch deleted, left a
# stale local branch behind; the dependent stacked on that local commit, which
# is not an ancestor of main, and its execute worktree lacked weeks of main.
class DependencyStackedBaseTest < Minitest::Test
  include HiveTestHelper

  DependentTask = Struct.new(:slug, :id, :depends_on, :folder, :project_root, keyword_init: true)

  def test_delivered_prerequisite_with_deleted_remote_and_stale_local_branch_bases_on_origin_default
    with_project_and_origin do |dir, root, origin|
      # The prerequisite branch was pushed, squash-merged, then deleted on the
      # remote; only the stale local branch survives.
      commit_on_branch(dir, "base-task", "base.txt")
      stale_sha = run!("git", "-C", dir, "rev-parse", "refs/heads/base-task").strip
      squash_merge_on_origin(origin, "base.txt", "main-only.txt")
      origin_sha = run!("git", "-C", origin, "rev-parse", "master").strip
      write_task(dir, "9-done", "base-task", id: 1)
      task = dependent_task(dir)

      override = nil
      _out, err = capture_io { override = Hive::DependencySnapshot.stacked_base(task, "master") }
      wt = create_and_record(dir, root, task, override)

      assert_nil override, "a delivered prerequisite must never be a stacked base"
      assert_match(/prerequisite base-task is already delivered \(stage 9-done\)/, err)
      head = run!("git", "-C", wt.path, "rev-parse", "HEAD").strip
      assert_equal origin_sha, head
      refute_equal stale_sha, head
      assert File.exist?(File.join(wt.path, "main-only.txt")),
             "the dependent must contain everything that landed on main"
      pointer = YAML.safe_load(File.read(File.join(task.folder, "worktree.yml")))
      assert_equal [ "master", origin_sha, "origin/master" ],
                   pointer.values_at("base_branch", "base_oid", "base_ref")
      assert system("git", "-C", dir, "merge-base", "--is-ancestor", pointer.fetch("base_oid"), "origin/master"),
             "the recorded base_oid must be on the recorded base_branch"
    end
  end

  def test_undelivered_prerequisite_with_a_remote_branch_stacks_on_it
    with_project_and_origin do |dir, root, origin|
      push_branch(origin, "base-task", "base.txt")
      prereq_sha = run!("git", "-C", origin, "rev-parse", "base-task").strip
      write_task(dir, "8-finalize", "base-task", id: 1)
      task = dependent_task(dir)

      override = Hive::DependencySnapshot.stacked_base(task, "master")
      wt = create_and_record(dir, root, task, override)

      assert_equal "base-task", override
      assert_equal prereq_sha, run!("git", "-C", wt.path, "rev-parse", "HEAD").strip
      pointer = YAML.safe_load(File.read(File.join(task.folder, "worktree.yml")))
      assert_equal [ "master", prereq_sha, "origin/base-task" ],
                   pointer.values_at("base_branch", "base_oid", "base_ref")
    end
  end

  # Documented order for an undelivered prerequisite: remote branch, then local
  # branch, then default. The local fallback is kept (offline / not-yet-pushed
  # prerequisites) but is loud and recorded, never silent.
  def test_undelivered_prerequisite_without_a_remote_branch_stacks_on_local_loudly
    with_project_and_origin do |dir, root, _origin|
      commit_on_branch(dir, "base-task", "base.txt")
      local_sha = run!("git", "-C", dir, "rev-parse", "refs/heads/base-task").strip
      write_task(dir, "8-finalize", "base-task", id: 1)
      task = dependent_task(dir)

      override = Hive::DependencySnapshot.stacked_base(task, "master")
      wt = nil
      _out, err = capture_io { wt = create_and_record(dir, root, task, override) }

      assert_equal "base-task", override
      assert_equal local_sha, run!("git", "-C", wt.path, "rev-parse", "HEAD").strip
      assert_match(/stacking on local base-task \(undelivered prerequisite with no remote branch; /, err)
      assert_match(/may be stale/, err)
      pointer = YAML.safe_load(File.read(File.join(task.folder, "worktree.yml")))
      assert_equal [ "master", local_sha, "refs/heads/base-task" ],
                   pointer.values_at("base_branch", "base_oid", "base_ref")
    end
  end

  def test_create_leaves_resolved_base_nil_when_attaching_an_existing_branch
    with_project_and_origin do |dir, root, _origin|
      run!("git", "-C", dir, "branch", "existing-task", "master")
      wt = Hive::Worktree.new(dir, "existing-task", worktree_root: root)

      wt.create!("existing-task", default_branch: "master")

      assert_nil wt.resolved_base
    end
  end

  def with_project_and_origin
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      ops.add_hive_state_to_master_gitignore!
      root = "#{dir}.worktrees"
      origin = "#{dir}.origin.git"
      begin
        run!("git", "clone", "--bare", "--quiet", dir, origin)
        run!("git", "-C", dir, "remote", "add", "origin", origin)
        run!("git", "-C", dir, "fetch", "--quiet", "origin")
        yield dir, root, origin
      ensure
        FileUtils.rm_rf(root)
        FileUtils.rm_rf(origin)
      end
    end
  end

  def commit_on_branch(dir, branch, file)
    run!("git", "-C", dir, "checkout", "--quiet", "-b", branch)
    File.write(File.join(dir, file), "#{branch}\n")
    run!("git", "-C", dir, "add", file)
    run!("git", "-C", dir, "commit", "--quiet", "-m", "#{branch} work")
    run!("git", "-C", dir, "checkout", "--quiet", "master")
  end

  def with_origin_clone(origin)
    scratch = Dir.mktmpdir("origin-pusher")
    run!("git", "clone", "--quiet", origin, scratch)
    run!("git", "-C", scratch, "config", "user.email", "test@example.com")
    run!("git", "-C", scratch, "config", "user.name", "Test")
    yield scratch
  ensure
    FileUtils.rm_rf(scratch) if scratch
  end

  def push_branch(origin, branch, file)
    with_origin_clone(origin) do |scratch|
      commit_on_branch(scratch, branch, file)
      run!("git", "-C", scratch, "push", "--quiet", "origin", "#{branch}:#{branch}")
    end
  end

  # A squash merge lands the prerequisite's content as a NEW commit on master
  # (so the local prerequisite commit is not an ancestor), followed by later
  # main-only work the dependent must not lose.
  def squash_merge_on_origin(origin, *files)
    with_origin_clone(origin) do |scratch|
      files.each do |file|
        File.write(File.join(scratch, file), "#{file}\n")
        run!("git", "-C", scratch, "add", file)
        run!("git", "-C", scratch, "commit", "--quiet", "-m", "land #{file}")
      end
      run!("git", "-C", scratch, "push", "--quiet", "origin", "master:master")
    end
  end

  def write_task(dir, stage, slug, id:)
    folder = File.join(dir, ".hive-state", "stages", stage, slug)
    FileUtils.mkdir_p(folder)
    Hive::TaskMeta.write(folder, id: id, slug: slug, display_name: nil)
    folder
  end

  def dependent_task(dir)
    folder = write_task(dir, "4-execute", "dependent-task", id: 2)
    DependentTask.new(slug: "dependent-task", id: 2, depends_on: "base-task", folder: folder, project_root: dir)
  end

  def create_and_record(dir, root, task, override)
    wt = Hive::Worktree.new(dir, task.slug, worktree_root: root)
    wt.create!(task.slug, default_branch: "master", base_override: override)
    base_oid = Hive::GitOps.new(wt.path).head_sha
    wt.write_pointer!(task.folder, task.slug, execute_base_head: base_oid, base_branch: "master",
                                              base_oid: base_oid, base_ref: wt.resolved_base)
    wt
  end
end
