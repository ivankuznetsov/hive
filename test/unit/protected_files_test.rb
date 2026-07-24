require "test_helper"
require "digest"
require "hive/protected_files"

# Direct coverage for Hive::ProtectedFiles. Multiple stages depend on
# this snapshot/diff primitive to detect a sub-agent tampering with
# orchestrator-owned files; the tests below pin the hash shape, the
# missing-file=nil contract, and the diff semantics.
class ProtectedFilesTest < Minitest::Test
  include HiveTestHelper

  def test_orchestrator_owned_lists_canonical_state_and_identity_files
    assert_equal %w[plan.md worktree.yml handoff.yml task.md task-journal.jsonl task-projection.json],
                 Hive::ProtectedFiles::ORCHESTRATOR_OWNED,
                 "ORCHESTRATOR_OWNED is the single source of truth for the protected set"
  end

  def test_snapshot_returns_hash_keyed_by_name_with_sha256_hex
    with_tmp_dir do |dir|
      File.write(File.join(dir, "plan.md"), "plan body\n")
      File.write(File.join(dir, "worktree.yml"), "path: /x\n")
      File.write(File.join(dir, "handoff.yml"), "phase: worktree_created\n")
      File.write(File.join(dir, "task.md"), "## task\n")
      File.write(File.join(dir, "task-journal.jsonl"), "{}\n")
      File.write(File.join(dir, "task-projection.json"), "{}\n")

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
      assert_nil snap["handoff.yml"]
      assert_nil snap["task-journal.jsonl"]
      assert_nil snap["task-projection.json"]
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

  def test_diff_detects_regular_file_replaced_by_same_content_symlink
    with_tmp_dir do |dir|
      plan = File.join(dir, "plan.md")
      target = File.join(dir, "outside.md")
      File.write(plan, "same\n")
      File.write(target, "same\n")
      before = Hive::ProtectedFiles.snapshot(dir, [ "plan.md" ])
      FileUtils.rm_f(plan)
      File.symlink(target, plan)
      after = Hive::ProtectedFiles.snapshot(dir, [ "plan.md" ])

      assert_equal [ "plan.md" ], Hive::ProtectedFiles.diff(before, after)
    end
  end

  def test_snapshot_paths_detects_labeled_absolute_control_file_changes
    with_tmp_dir do |dir|
      config = File.join(dir, "config")
      File.write(config, "safe\n")
      before = Hive::ProtectedFiles.snapshot_paths("repository config" => config)
      File.write(config, "unsafe\n")
      after = Hive::ProtectedFiles.snapshot_paths("repository config" => config)

      assert_equal [ "repository config" ], Hive::ProtectedFiles.diff(before, after)
    end
  end

  def test_capture_restores_changed_deleted_and_new_files
    with_tmp_dir do |dir|
      File.write(File.join(dir, "plan.md"), "trusted plan\n")
      File.write(File.join(dir, "task.md"), "trusted task\n")
      captured = Hive::ProtectedFiles.capture(
        dir, %w[plan.md task.md worktree.yml]
      )

      File.write(File.join(dir, "plan.md"), "tampered\n")
      FileUtils.rm_f(File.join(dir, "task.md"))
      File.write(File.join(dir, "worktree.yml"), "path: /attacker\n")

      restored, error = Hive::ProtectedFiles.restore_safely(
        dir, captured, %w[plan.md task.md worktree.yml]
      )

      assert_equal true, restored
      assert_nil error
      assert_equal "trusted plan\n", File.read(File.join(dir, "plan.md"))
      assert_equal "trusted task\n", File.read(File.join(dir, "task.md"))
      refute File.exist?(File.join(dir, "worktree.yml"))
    end
  end

  def test_restore_fails_closed_for_agent_created_directory
    with_tmp_dir do |dir|
      captured = Hive::ProtectedFiles.capture(dir, [ "plan.md" ])
      FileUtils.mkdir_p(File.join(dir, "plan.md", "nested"))

      restored, error = Hive::ProtectedFiles.restore_safely(
        dir, captured, [ "plan.md" ]
      )

      assert_equal false, restored
      assert_includes error, "refusing to replace protected path directory"
      assert File.directory?(File.join(dir, "plan.md"))
    end
  end

  def test_restore_paths_safely_reports_absolute_control_path_failure
    with_tmp_dir do |dir|
      path = File.join(dir, "config")
      paths = { "repository config" => path }
      captured = Hive::ProtectedFiles.capture_paths(paths)
      FileUtils.mkdir_p(path)

      restored, error = Hive::ProtectedFiles.restore_paths_safely(
        paths, captured, [ "repository config" ]
      )

      assert_equal false, restored
      assert_includes error, "refusing to replace protected path directory"
    end
  end

  def test_restore_rejects_unreconstructable_and_unknown_capture_types
    with_tmp_dir do |dir|
      target = File.join(dir, "target")
      File.write(target, "outside\n")
      File.symlink(target, File.join(dir, "plan.md"))
      captured = Hive::ProtectedFiles.capture(dir, [ "plan.md" ])

      restored, error = Hive::ProtectedFiles.restore_safely(
        dir, captured, [ "plan.md" ]
      )
      assert_equal false, restored
      assert_includes error, "non-file path cannot be reconstructed"

      unknown = {
        "task.md" => { kind: :future_capture_type, fingerprint: nil }
      }
      restored, error = Hive::ProtectedFiles.restore_safely(
        dir, unknown, [ "task.md" ]
      )
      assert_equal false, restored
      assert_includes error, "unknown protected capture type"
    end
  end

  def test_capture_rejects_parent_traversal
    with_tmp_dir do |dir|
      error = assert_raises(ArgumentError) do
        Hive::ProtectedFiles.capture(dir, [ "../outside" ])
      end

      assert_includes error.message, "must stay relative"
    end
  end
end
