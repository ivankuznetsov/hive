require "test_helper"
require "digest"
require "hive/protected_files"

# Direct coverage for Hive::ProtectedFiles. Multiple stages depend on
# this snapshot/diff primitive to detect a sub-agent tampering with
# orchestrator-owned files; the tests below pin the hash shape, the
# missing-file=nil contract, and the diff semantics.
class ProtectedFilesTest < Minitest::Test
  include HiveTestHelper

  def test_orchestrator_owned_lists_the_three_canonical_files
    assert_equal %w[plan.md worktree.yml task.md],
                 Hive::ProtectedFiles::ORCHESTRATOR_OWNED,
                 "ORCHESTRATOR_OWNED is the single source of truth for the protected set"
  end

  def test_snapshot_returns_hash_keyed_by_name_with_sha256_hex
    with_tmp_dir do |dir|
      File.write(File.join(dir, "plan.md"), "plan body\n")
      File.write(File.join(dir, "worktree.yml"), "path: /x\n")
      File.write(File.join(dir, "task.md"), "## task\n")

      snap = Hive::ProtectedFiles.snapshot(dir)
      assert_kind_of Hash, snap
      assert_equal Hive::ProtectedFiles::ORCHESTRATOR_OWNED.sort, snap.keys.sort

      snap.each do |name, hex|
        assert_kind_of String, hex, "#{name} must hash to a String"
        assert_match(/\A[0-9a-f]{64}\z/, hex,
                     "#{name} must hash to a 64-char SHA-256 hex string")
      end

      assert_equal Digest::SHA256.hexdigest("plan body\n"), snap["plan.md"],
                   "snapshot value matches Digest::SHA256.hexdigest of file contents"
    end
  end

  def test_missing_file_records_nil_for_deletion_detection
    with_tmp_dir do |dir|
      # Only plan.md exists; task.md and worktree.yml are missing.
      File.write(File.join(dir, "plan.md"), "plan body\n")
      snap = Hive::ProtectedFiles.snapshot(dir)

      refute_nil snap["plan.md"], "present file gets a hash"
      assert_nil snap["task.md"],
                 "missing file records nil so a later add yields a diff"
      assert_nil snap["worktree.yml"],
                 "missing file records nil so a later add yields a diff"
    end
  end

  def test_diff_returns_only_names_whose_hashes_changed
    with_tmp_dir do |dir|
      File.write(File.join(dir, "plan.md"), "plan body\n")
      File.write(File.join(dir, "worktree.yml"), "path: /x\n")
      File.write(File.join(dir, "task.md"), "## task\n")

      before = Hive::ProtectedFiles.snapshot(dir)
      File.write(File.join(dir, "plan.md"), "plan body MUTATED\n")
      after = Hive::ProtectedFiles.snapshot(dir)

      assert_equal [ "plan.md" ], Hive::ProtectedFiles.diff(before, after),
                   "only mutated file appears in the diff; identical hashes are filtered"
    end
  end

  def test_diff_detects_deletion_via_nil_transition
    with_tmp_dir do |dir|
      File.write(File.join(dir, "plan.md"), "plan body\n")
      File.write(File.join(dir, "worktree.yml"), "path: /x\n")
      File.write(File.join(dir, "task.md"), "## task\n")

      before = Hive::ProtectedFiles.snapshot(dir)
      File.delete(File.join(dir, "task.md"))
      after = Hive::ProtectedFiles.snapshot(dir)

      assert_includes Hive::ProtectedFiles.diff(before, after), "task.md",
                      "deletion (hex → nil) must surface in the diff"
    end
  end

  def test_snapshot_accepts_custom_names_array
    with_tmp_dir do |dir|
      File.write(File.join(dir, "a.md"), "a\n")
      File.write(File.join(dir, "b.md"), "b\n")

      snap = Hive::ProtectedFiles.snapshot(dir, %w[a.md b.md])
      assert_equal %w[a.md b.md].sort, snap.keys.sort
      assert_equal Digest::SHA256.hexdigest("a\n"), snap["a.md"]
      assert_equal Digest::SHA256.hexdigest("b\n"), snap["b.md"]
    end
  end
end
