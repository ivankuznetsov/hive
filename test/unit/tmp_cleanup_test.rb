require "test_helper"

class HiveTestTmpCleanupTest < Minitest::Test
  include HiveTestHelper

  def test_remove_deletes_read_only_managed_tree_and_verifies_absence
    path = Dir.mktmpdir("hive-test-cleanup")
    nested = File.join(path, "store", "version")
    FileUtils.mkdir_p(nested)
    File.write(File.join(nested, "manifest.json"), "{}\n")
    FileUtils.chmod(0o444, File.join(nested, "manifest.json"))
    FileUtils.chmod(0o555, nested)
    FileUtils.chmod(0o555, File.dirname(nested))
    FileUtils.chmod(0o555, path)

    assert HiveTestTmpCleanup.remove!(path)
    refute File.exist?(path)
  ensure
    FileUtils.chmod_R(0o700, path, force: true) if path && File.exist?(path)
    FileUtils.rm_rf(path) if path
  end

  def test_remove_refuses_paths_without_a_test_tmp_name
    Dir.mktmpdir("ordinary-directory") do |path|
      error = assert_raises(HiveTestTmpCleanup::UnsafePath) do
        HiveTestTmpCleanup.remove!(path)
      end

      assert_match(/refusing to remove non-test tmp path/, error.message)
      assert Dir.exist?(path)
    end
  end

  def test_remove_raises_when_fileutils_silently_leaves_the_path
    path = Dir.mktmpdir("hive-test-cleanup")
    replacement = ->(*) { nil }

    with_replaced_singleton_method(FileUtils, :rm_rf, replacement) do
      error = assert_raises(HiveTestTmpCleanup::CleanupError) do
        HiveTestTmpCleanup.remove!(path)
      end
      assert_match(/still exists after removal/, error.message)
    end
  ensure
    FileUtils.rm_rf(path) if path
  end

  def test_remove_with_related_deletes_known_worktree_and_lock_siblings
    path = Dir.mktmpdir("hive-test-cleanup")
    worktrees = "#{path}-worktrees"
    lock = "#{path}.patrol-0123456789abcdef.lock"
    unrelated = "#{path}-notes"
    FileUtils.mkdir_p(worktrees)
    File.write(lock, "")
    File.write(unrelated, "keep\n")

    HiveTestTmpCleanup.remove_with_related!(path)

    refute File.exist?(path)
    refute File.exist?(worktrees)
    refute File.exist?(lock)
    assert File.exist?(unrelated)
  ensure
    FileUtils.rm_rf(path) if path
    FileUtils.rm_rf(worktrees) if worktrees
    FileUtils.rm_f(lock) if lock
    FileUtils.rm_f(unrelated) if unrelated
  end

  def test_sweep_removes_only_old_inactive_test_paths
    now = Time.utc(2026, 8, 10, 12, 0, 0)
    Dir.mktmpdir("tmp-cleanup-sweep") do |root|
      old = create_candidate(root, "hive-test-old", pid: 101, mtime: now - 86_401)
      old_worktrees = "#{old}-worktrees"
      FileUtils.mkdir_p(old_worktrees)
      File.utime(now - 86_401, now - 86_401, old_worktrees)
      recent = create_candidate(root, "hive-global", pid: 102, mtime: now - 60)
      live = create_candidate(root, "hive-web-src", pid: 103, mtime: now - 86_401)
      unrelated = File.join(root, "hive-production-data")
      FileUtils.mkdir_p(unrelated)
      File.utime(now - 86_401, now - 86_401, unrelated)

      result = HiveTestTmpCleanup.sweep(
        tmp_root: root,
        legacy_root: nil,
        now: now,
        process_alive: ->(pid) { pid == 103 }
      )

      assert_equal [ old, old_worktrees ].sort, result.removed.sort
      assert_equal [ live ], result.skipped_live
      assert_equal [ recent ], result.skipped_recent
      assert_empty result.skipped_unowned
      assert_empty result.failed
      refute File.exist?(old)
      refute File.exist?(old_worktrees)
      assert Dir.exist?(recent)
      assert Dir.exist?(live)
      assert Dir.exist?(unrelated)
    end
  end

  def test_sweep_removes_the_legacy_test_worktree_shape
    now = Time.utc(2026, 8, 10, 12, 0, 0)
    Dir.mktmpdir("tmp-cleanup-root") do |tmp_root|
      Dir.mktmpdir("tmp-cleanup-legacy") do |legacy_root|
        legacy = create_candidate(
          legacy_root,
          "hive-test-project",
          pid: 104,
          mtime: now - 86_401,
          suffix: ".worktrees"
        )

        result = HiveTestTmpCleanup.sweep(
          tmp_root: tmp_root,
          legacy_root: legacy_root,
          now: now,
          process_alive: ->(_pid) { false }
        )

        assert_equal [ legacy ], result.removed
        assert_empty result.failed
        refute File.exist?(legacy)
      end
    end
  end

  def test_sweep_reports_a_path_that_removal_leaves_behind
    now = Time.utc(2026, 8, 10, 12, 0, 0)
    Dir.mktmpdir("tmp-cleanup-failure") do |root|
      path = create_candidate(root, "hive-test-failure", pid: 105, mtime: now - 86_401)

      with_replaced_singleton_method(FileUtils, :rm_rf, ->(*) { nil }) do
        result = HiveTestTmpCleanup.sweep(
          tmp_root: root,
          legacy_root: nil,
          now: now,
          process_alive: ->(_pid) { false }
        )

        assert_empty result.removed
        assert_equal [ path ], result.failed.map { |failure| failure.fetch(:path) }
        assert_match(/still exists after removal/, result.failed.first.fetch(:error))
      end
    end
  end

  private

  def create_candidate(root, prefix, pid:, mtime:, suffix: "")
    path = File.join(root, "#{prefix}20260810-#{pid}-abc123#{suffix}")
    FileUtils.mkdir_p(path)
    File.utime(mtime, mtime, path)
    path
  end
end
