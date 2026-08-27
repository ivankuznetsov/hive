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
      second = store.prepare!(generation: 1, evidence_digest: "a" * 64) do
        flunk "must not resolve a new base for existing custody"
      end

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

  def test_rework_rotates_generation_ownership_without_discarding_the_owned_worktree
    Dir.mktmpdir do |dir|
      repo = initialize_repo(File.join(dir, "repo"))
      task = File.join(dir, "state", "stages", "4-review", "repair-one")
      FileUtils.mkdir_p(task)
      base = git(repo, "rev-parse", "HEAD").strip
      store = Hive::PatrolFix::WorktreeReceipt.new(
        task_folder: task, project_root: repo, slug: "repair-one",
        worktree_root: File.join(dir, "worktrees")
      )
      first = store.prepare!(generation: 1, evidence_digest: "a" * 64, base_revision: base)

      second = store.rotate!(generation: 2, evidence_digest: "b" * 64)

      assert_equal first.fetch("worktree"), second.fetch("worktree")
      assert_equal first.fetch("branch"), second.fetch("branch")
      assert_equal 2, second.fetch("generation")
      archive = File.join(task, "patrol-fix-worktrees", "generation-1.json")
      assert_equal first, JSON.parse(File.read(archive))
      assert_equal second, store.prepare!(
        generation: 2, evidence_digest: "b" * 64, base_revision: base
      )
    end
  end

  def test_read_translates_missing_malformed_and_io_failures
    Dir.mktmpdir do |dir|
      task = File.join(dir, "task")
      FileUtils.mkdir_p(task)
      store = Hive::PatrolFix::WorktreeReceipt.new(
        task_folder: task, project_root: dir, slug: "repair-one"
      )
      assert_raises(Hive::PatrolFix::WorktreeReceipt::InvalidWorktree) { store.read }

      path = File.join(task, Hive::PatrolFix::WorktreeReceipt::FILENAME)
      File.write(path, "{")
      assert_raises(Hive::PatrolFix::WorktreeReceipt::InvalidWorktree) { store.read }

      original = File.method(:open)
      File.define_singleton_method(:open, ->(*) { raise IOError, "closed" })
      begin
        assert_raises(Hive::PatrolFix::WorktreeReceipt::InvalidWorktree) { store.read }
      ensure
        File.define_singleton_method(:open, original)
      end
    end
  end

  def test_translates_hardened_git_failures_at_each_public_boundary
    Dir.mktmpdir do |dir|
      task = File.join(dir, "task")
      FileUtils.mkdir_p(task)
      base = "1" * 40
      store = Hive::PatrolFix::WorktreeReceipt.new(
        task_folder: task, project_root: dir, slug: "repair-one"
      )
      failed_worktree = Object.new
      failed_worktree.define_singleton_method(:create_exact!) do |*|
        raise Hive::AgentGitGate::Error, "hardened git failed"
      end
      store.define_singleton_method(:worktree) { |_| failed_worktree }
      assert_raises(Hive::PatrolFix::WorktreeReceipt::InvalidWorktree) do
        store.prepare!(generation: 1, evidence_digest: "a" * 64, base_revision: base)
      end

      store.define_singleton_method(:read) { raise Hive::AgentGitGate::Error, "hardened git failed" }
      assert_raises(Hive::PatrolFix::WorktreeReceipt::InvalidWorktree) do
        store.rotate!(generation: 2, evidence_digest: "b" * 64)
      end
      assert_raises(Hive::PatrolFix::WorktreeReceipt::InvalidWorktree) do
        store.capture!(generation: 1, evidence_digest: "a" * 64)
      end
    end
  end

  def test_archive_helpers_are_idempotent_and_fail_closed
    Dir.mktmpdir do |dir|
      task = File.join(dir, "task")
      FileUtils.mkdir_p(task)
      store = Hive::PatrolFix::WorktreeReceipt.new(
        task_folder: task, project_root: dir, slug: "repair-one"
      )
      archive_dir = File.join(task, "patrol-fix-worktrees")
      File.write(archive_dir, "not a directory")
      assert_raises(Hive::PatrolFix::WorktreeReceipt::InvalidWorktree) do
        store.send(:ensure_archive_dir!, archive_dir)
      end

      original_lstat = File.method(:lstat)
      File.define_singleton_method(:lstat, ->(*) { raise IOError, "unavailable" })
      begin
        assert_raises(Hive::PatrolFix::WorktreeReceipt::InvalidWorktree) do
          store.send(:ensure_archive_dir!, File.join(task, "other"))
        end
      ensure
        File.define_singleton_method(:lstat, original_lstat)
      end

      document = { "generation" => 1 }
      retained = File.join(task, "retained.json")
      File.write(retained, Hive::PatrolFix.canonical_json(document))
      assert_nil store.send(:write_exact_or_match!, retained, document, "archive")

      File.write(retained, "different")
      assert_raises(Hive::PatrolFix::WorktreeReceipt::InvalidWorktree) do
        store.send(:write_exact_or_match!, retained, document, "archive")
      end

      File.delete(retained)
      target = File.join(task, "target")
      File.write(target, "target")
      File.symlink(target, retained)
      assert_raises(Hive::PatrolFix::WorktreeReceipt::InvalidWorktree) do
        store.send(:write_exact_or_match!, retained, document, "archive")
      end
      File.unlink(retained)
      File.write(retained, "different")

      original_binread = File.method(:binread)
      File.define_singleton_method(:binread, ->(*) { raise IOError, "unavailable" })
      begin
        assert_raises(Hive::PatrolFix::WorktreeReceipt::InvalidWorktree) do
          store.send(:write_exact_or_match!, retained, document, "archive")
        end
      ensure
        File.define_singleton_method(:binread, original_binread)
      end
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
