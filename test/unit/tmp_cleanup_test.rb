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

  def test_remove_deletes_read_only_tree_under_private_tmp_root
    Dir.mktmpdir("tmp-cleanup-private") do |root|
      path = Dir.mktmpdir("hive-test-cleanup", root)
      nested = File.join(path, "store", "version")
      FileUtils.mkdir_p(nested)
      File.write(File.join(nested, "manifest.json"), "{}\n")
      FileUtils.chmod(0o444, File.join(nested, "manifest.json"))
      FileUtils.chmod(0o555, nested)
      FileUtils.chmod(0o555, File.dirname(nested))
      FileUtils.chmod(0o555, path)

      assert HiveTestTmpCleanup.remove!(path, root: root)
      refute File.exist?(path)
    ensure
      FileUtils.chmod_R(0o700, path, force: true) if path && File.exist?(path)
      FileUtils.rm_rf(path) if path
    end
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

  def test_remove_refuses_test_shaped_path_below_a_nested_directory
    Dir.mktmpdir("tmp-cleanup-nested") do |root|
      nested_root = File.join(root, "nested")
      FileUtils.mkdir_p(nested_root)
      path = create_candidate(nested_root, "hive-test-nested", pid: 99, mtime: Time.now)

      assert_raises(HiveTestTmpCleanup::UnsafePath) do
        HiveTestTmpCleanup.remove!(path, root: root)
      end
      assert Dir.exist?(path)
    end
  end

  def test_remove_unlinks_test_shaped_symlink_without_following_it
    Dir.mktmpdir("tmp-cleanup-symlink") do |root|
      Dir.mktmpdir("tmp-cleanup-external") do |external|
        marker = File.join(external, "keep.txt")
        File.write(marker, "keep\n")
        path = File.join(root, "hive-test-link20260810-98-abc123")
        File.symlink(external, path)

        assert HiveTestTmpCleanup.remove!(path, root: root)
        refute File.symlink?(path)
        assert_equal "keep\n", File.read(marker)
      end
    end
  end

  def test_remove_returns_false_when_path_already_disappeared
    path = File.join(Dir.tmpdir, "hive-test-gone20260810-97-abc123")
    FileUtils.rm_rf(path)

    refute HiveTestTmpCleanup.remove!(path)
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
    related = [
      "#{path}-worktrees",
      "#{path}.worktrees",
      "#{path}.managed-worktrees",
      "#{path}.origin.git",
      "#{path}.strict-origin.git",
      "#{path}.agent-worktree-origin.git"
    ]
    lock = "#{path}.patrol-0123456789abcdef.lock"
    unrelated = "#{path}-notes"
    related.each { |entry| FileUtils.mkdir_p(entry) }
    File.write(lock, "")
    File.write(unrelated, "keep\n")

    HiveTestTmpCleanup.remove_with_related!(path)

    refute File.exist?(path)
    related.each { |entry| refute File.exist?(entry), "expected cleanup of #{entry}" }
    refute File.exist?(lock)
    assert File.exist?(unrelated)
  ensure
    FileUtils.rm_rf(path) if path
    related&.each { |entry| FileUtils.rm_rf(entry) }
    FileUtils.rm_f(lock) if lock
    FileUtils.rm_f(unrelated) if unrelated
  end

  def test_remove_all_attempts_every_root_before_raising
    paths = %w[
      hive-test-first20260810-95-abc123
      hive-test-second20260810-96-abc123
    ].map { |name| File.join(Dir.tmpdir, name) }
    attempted = []
    replacement = lambda do |path|
      attempted << path
      raise HiveTestTmpCleanup::CleanupError, "first failed" if path == paths.last
    end

    with_replaced_singleton_method(HiveTestTmpCleanup, :remove_with_related!, replacement) do
      error = assert_raises(HiveTestTmpCleanup::CleanupError) do
        HiveTestTmpCleanup.remove_all!(paths)
      end

      assert_equal paths.reverse, attempted
      assert_match(/first failed/, error.message)
    end
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
      production = [
        File.join(root, "hive-web-capture-20260810-4242-abc123"),
        File.join(root, "hive-terminal-state-20260810-4242-abc123")
      ]
      [ unrelated, *production ].each do |entry|
        FileUtils.mkdir_p(entry)
        File.utime(now - 86_401, now - 86_401, entry)
      end

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
      production.each { |entry| assert Dir.exist?(entry), "production tmp path must survive: #{entry}" }
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
        production = [
          File.join(legacy_root, "hive.worktrees"),
          File.join(legacy_root, "hive-test.worktrees")
        ]
        production.each { |entry| FileUtils.mkdir_p(entry) }

        result = HiveTestTmpCleanup.sweep(
          tmp_root: tmp_root,
          legacy_root: legacy_root,
          now: now,
          process_alive: ->(_pid) { false }
        )

        assert_equal [ legacy ], result.removed
        assert_empty result.failed
        refute File.exist?(legacy)
        production.each { |entry| assert Dir.exist?(entry), "non-test worktree root must survive: #{entry}" }
      end
    end
  end

  def test_process_alive_treats_out_of_range_pid_as_inactive
    refute HiveTestTmpCleanup.process_alive?(10**100)
  end

  def test_tracked_tmp_dir_rejects_unrecognized_prefix_without_leaking
    path = File.join(Dir.tmpdir, "fixture-store20260810-94-abc123")
    replacement = lambda do |_prefix|
      FileUtils.mkdir_p(path)
      path
    end

    with_replaced_singleton_method(Dir, :mktmpdir, replacement) do
      error = assert_raises(ArgumentError) { tracked_tmp_dir("fixture-store") }
      assert_match(/not a recognized Hive test tmp shape/, error.message)
    end
    refute File.exist?(path)
  ensure
    FileUtils.rm_rf(path) if path
  end

  def test_cleanup_tmp_dir_preserves_the_active_test_error
    path = File.join(Dir.tmpdir, "hive-test-body-error20260810-93-abc123")
    replacement = ->(_path) { raise HiveTestTmpCleanup::CleanupError, "cleanup failed" }

    _out, err = capture_io do
      with_replaced_singleton_method(HiveTestTmpCleanup, :remove_with_related!, replacement) do
        error = assert_raises(RuntimeError) do
          begin
            raise "test body failed"
          ensure
            cleanup_tmp_dir!(path)
          end
        end
        assert_equal "test body failed", error.message
      end
    end
    assert_match(/cleanup also failed/, err)
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
