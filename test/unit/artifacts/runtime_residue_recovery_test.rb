require "test_helper"
require "json"
require "tmpdir"
require "hive/artifacts/runtime_residue_recovery"
require "hive/markers"

class ArtifactsRuntimeResidueRecoveryTest < Minitest::Test
  include HiveTestHelper

  FakeTask = Data.define(:folder, :worktree_path)
  Recovery = Hive::Artifacts::RuntimeResidueRecovery

  def test_quarantines_only_untracked_runtime_files_and_leaves_a_clean_worktree
    with_fixture do |task, worktree, marker|
      blob = File.join(worktree, "storage", "as", "aa", "runtime-blob")
      FileUtils.mkdir_p(File.dirname(blob))
      File.binwrite(blob, "runtime bytes")

      result = Recovery.new.recover(
        task:, marker:, intended_stage: "7-artifacts"
      )

      assert_equal :quarantined, result.status
      assert_equal [ "storage/as/aa/runtime-blob" ], result.paths
      refute_path_exists blob
      assert_path_exists File.join(worktree, "storage", ".keep")
      assert_empty git(worktree, "status", "--porcelain", "--untracked-files=all")
      receipt = JSON.parse(File.binread(result.receipt_path))
      assert_equal "quarantined", receipt.fetch("status")
      assert_equal Digest::SHA256.hexdigest("runtime bytes"),
                   receipt.fetch("entries").first.fetch("sha256")
      quarantined = File.join(File.dirname(result.receipt_path), result.paths.first)
      assert_equal "runtime bytes", File.binread(quarantined)

      replay = Recovery.new.recover(task:, marker:, intended_stage: "7-artifacts")
      assert_equal :quarantined, replay.status
      assert_equal result.receipt_path, replay.receipt_path
      assert_equal result.paths, replay.paths
    end
  end

  def test_refuses_tracked_edits_other_paths_symlinks_and_oversized_files
    scenarios = {
      tracked: lambda do |worktree|
        File.write(File.join(worktree, "storage", ".keep"), "edited")
      end,
      other_path: lambda do |worktree|
        File.write(File.join(worktree, "operator-note.txt"), "keep")
      end,
      symlink: lambda do |worktree|
        File.symlink(".keep", File.join(worktree, "storage", "linked"))
      end,
      oversized: lambda do |worktree|
        path = File.join(worktree, "storage", "large")
        File.open(path, "wb") { |file| file.truncate(Recovery::MAX_FILE_BYTES + 1) }
      end
    }

    scenarios.each do |name, prepare|
      with_fixture do |task, worktree, marker|
        prepare.call(worktree)

        error = assert_raises(Recovery::RecoveryError, name.to_s) do
          Recovery.new.recover(task:, marker:, intended_stage: "7-artifacts")
        end

        refute_empty error.message
        refute_empty git(worktree, "status", "--porcelain", "--untracked-files=all")
      end
    end
  end

  def test_non_artifact_marker_never_touches_the_worktree
    with_fixture do |task, worktree, marker|
      blob = File.join(worktree, "storage", "runtime-blob")
      File.binwrite(blob, "runtime")

      result = Recovery.new.recover(
        task:, marker:, intended_stage: "6-review"
      )

      assert_equal :not_applicable, result.status
      assert_path_exists blob
    end
  end

  private

  def with_fixture
    Dir.mktmpdir("hive-artifact-runtime-residue") do |root|
      worktree = File.join(root, "worktree")
      task_folder = File.join(root, "state", "7-artifacts", "demo")
      FileUtils.mkdir_p([ File.join(worktree, "storage"), task_folder ])
      git(worktree, "init", "-q")
      git(worktree, "config", "user.email", "hive@example.test")
      git(worktree, "config", "user.name", "Hive Test")
      File.write(File.join(worktree, "storage", ".keep"), "")
      git(worktree, "add", ".")
      git(worktree, "commit", "-qm", "base")
      marker = Hive::Markers::State.new(
        name: :error,
        attrs: {
          "reason" => Recovery::MARKER_REASON,
          "diagnostic" => Recovery::MARKER_DIAGNOSTIC,
          "marker_id" => "a" * 16
        },
        raw: "marker"
      )
      yield FakeTask.new(folder: task_folder, worktree_path: worktree), worktree, marker
    end
  end

  def git(root, *args)
    output = IO.popen([ "git", "-C", root, *args ], err: [ :child, :out ], &:read)
    raise "git #{args.join(' ')} failed: #{output}" unless $CHILD_STATUS.success?

    output
  end
end
