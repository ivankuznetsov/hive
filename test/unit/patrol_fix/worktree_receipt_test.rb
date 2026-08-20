require "test_helper"
require "open3"
require "hive/patrol_fix/worktree_receipt"

class PatrolFixWorktreeReceiptTest < Minitest::Test
  def test_prepares_one_exact_local_generation_without_remote_authentication_and_reuses_it
    Dir.mktmpdir do |dir|
      repo = initialize_repo(File.join(dir, "repo"))
      task = File.join(dir, "state", "stages", "2-fix", "repair-one")
      FileUtils.mkdir_p(task)
      base = git(repo, "rev-parse", "HEAD").strip
      store = Hive::PatrolFix::WorktreeReceipt.new(
        task_folder: task, project_root: repo, slug: "repair-one",
        worktree_root: File.join(dir, "worktrees")
      )

      first = store.prepare!(generation: 1, evidence_digest: "a" * 64, base_revision: base)
      second = store.prepare!(generation: 1, evidence_digest: "a" * 64, base_revision: base)

      assert_equal first, second
      assert_equal base, first.fetch("base_revision")
      assert_equal "hive/patrol-fix/repair-one/g1", first.fetch("branch")
      assert File.directory?(first.fetch("worktree"))
      assert_equal 2, git(repo, "worktree", "list", "--porcelain").scan(/^worktree /).length
    end
  end

  def test_capture_requires_a_clean_committed_descendant_and_binds_diff
    Dir.mktmpdir do |dir|
      repo = initialize_repo(File.join(dir, "repo"))
      task = File.join(dir, "state", "stages", "2-fix", "repair-one")
      FileUtils.mkdir_p(task)
      base = git(repo, "rev-parse", "HEAD").strip
      store = Hive::PatrolFix::WorktreeReceipt.new(
        task_folder: task, project_root: repo, slug: "repair-one",
        worktree_root: File.join(dir, "worktrees")
      )
      ownership = store.prepare!(generation: 1, evidence_digest: "a" * 64, base_revision: base)
      worktree = ownership.fetch("worktree")
      File.write(File.join(worktree, "app.rb"), "puts :fixed\n")

      assert_raises(Hive::PatrolFix::WorktreeReceipt::InvalidWorktree) do
        store.capture!(generation: 1, evidence_digest: "a" * 64)
      end

      git(worktree, "add", "app.rb")
      git(worktree, "commit", "-m", "Fix defect")
      receipt = store.capture!(generation: 1, evidence_digest: "a" * 64)
      assert_match(/\A[0-9a-f]{40}\z/, receipt.fetch("head_revision"))
      refute_equal base, receipt.fetch("head_revision")
      assert_match(/\A[0-9a-f]{64}\z/, receipt.fetch("diff_digest"))
    end
  end

  def test_ownership_receipt_is_bounded_and_never_follows_links
    Dir.mktmpdir do |dir|
      repo = initialize_repo(File.join(dir, "repo"))
      task = File.join(dir, "state", "stages", "2-fix", "repair-one")
      FileUtils.mkdir_p(task)
      store = Hive::PatrolFix::WorktreeReceipt.new(
        task_folder: task, project_root: repo, slug: "repair-one",
        worktree_root: File.join(dir, "worktrees")
      )
      path = File.join(task, Hive::PatrolFix::WorktreeReceipt::FILENAME)
      target = File.join(dir, "foreign.json")
      File.write(target, "{}")
      File.symlink(target, path)

      assert_raises(Hive::PatrolFix::WorktreeReceipt::InvalidWorktree) { store.read }
      File.unlink(path)
      File.write(path, "x" * (Hive::PatrolFix::WorktreeReceipt::MAX_RECEIPT_BYTES + 1))
      assert_raises(Hive::PatrolFix::WorktreeReceipt::InvalidWorktree) { store.read }
    end
  end

  private

  def initialize_repo(path)
    FileUtils.mkdir_p(path)
    git(path, "init", "-b", "main")
    git(path, "config", "user.email", "test@example.com")
    git(path, "config", "user.name", "Test")
    File.write(File.join(path, "app.rb"), "puts :broken\n")
    git(path, "add", "app.rb")
    git(path, "commit", "-m", "Initial")
    path
  end

  def git(path, *args)
    out, err, status = Open3.capture3("git", "-C", path, *args)
    raise err unless status.success?

    out
  end
end
