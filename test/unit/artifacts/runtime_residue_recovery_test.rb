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

  def test_clean_worktree_without_a_journal_reports_nothing_to_recover
    with_fixture do |task, _worktree, marker|
      result = Recovery.new.recover(task:, marker:, intended_stage: "7-artifacts")

      assert_equal :clean, result.status
      assert_nil result.receipt_path
      assert_empty result.paths
    end
  end

  def test_unreadable_git_status_fails_closed_including_bounded_overflow
    failed = Hive::AgentGitGate::ReadResult.new(
      operation: :status, stdout: "", stderr: "fatal: not a git repository\n",
      exitstatus: 128, overflow: false
    )
    overflowed = Hive::AgentGitGate::ReadResult.new(
      operation: :status, stdout: "", stderr: "", exitstatus: 0, overflow: true
    )

    { "fatal: not a git repository" => failed, "bounded output exceeded" => overflowed }
      .each do |expected, stubbed|
      with_fixture do |task, _worktree, marker|
        error = with_replaced_singleton_method(
          Hive::AgentGitGate, :read, ->(*, **) { stubbed }
        ) do
          assert_raises(Recovery::RecoveryError) do
            Recovery.new.recover(task:, marker:, intended_stage: "7-artifacts")
          end
        end

        assert_includes error.message, expected
      end
    end
  end

  def test_residue_path_that_is_not_valid_utf8_fails_closed
    with_fixture do |task, worktree, marker|
      File.binwrite(File.join(worktree, "storage").b + "/blob-\xFF".b, "runtime")

      error = assert_raises(Recovery::RecoveryError) do
        Recovery.new.recover(task:, marker:, intended_stage: "7-artifacts")
      end

      assert_includes error.message, "not valid UTF-8"
    end
  end

  def test_prepared_journal_is_resumed_rather_than_rewritten
    with_fixture do |task, worktree, marker|
      blob = File.join(worktree, "storage", "runtime-blob")
      File.binwrite(blob, "runtime bytes")
      prepared = journal(task, worktree, marker, [ "storage/runtime-blob" ])

      result = Recovery.new.recover(task:, marker:, intended_stage: "7-artifacts")

      assert_equal :quarantined, result.status
      receipt = JSON.parse(File.binread(result.receipt_path))
      assert_equal prepared.fetch("prepared_at"), receipt.fetch("prepared_at")
      assert_equal "quarantined", receipt.fetch("status")
      refute_path_exists blob
    end
  end

  def test_journal_that_disagrees_with_the_dirty_worktree_fails_closed
    conflicts = {
      "foreign marker" => { "marker_id" => "b" * 16 },
      "missing path" => { "paths" => [ "storage/other-blob" ] }
    }

    conflicts.each do |name, overrides|
      with_fixture do |task, worktree, marker|
        File.binwrite(File.join(worktree, "storage", "runtime-blob"), "runtime bytes")
        journal(task, worktree, marker, [ "storage/runtime-blob" ], **overrides)

        error = assert_raises(Recovery::RecoveryError, name) do
          Recovery.new.recover(task:, marker:, intended_stage: "7-artifacts")
        end

        assert_includes error.message, "quarantine receipt conflicts"
      end
    end
  end

  def test_unreadable_journal_surfaces_as_a_recovery_error
    with_fixture do |task, worktree, marker|
      File.binwrite(File.join(worktree, "storage", "runtime-blob"), "runtime bytes")
      path = receipt_path(task, marker)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      File.binwrite(path, "{ not json")

      error = assert_raises(Recovery::RecoveryError) do
        Recovery.new.recover(task:, marker:, intended_stage: "7-artifacts")
      end

      assert_includes error.message, "artifact runtime residue recovery failed"
    end
  end

  def test_residue_rewritten_after_journaling_is_never_quarantined
    with_fixture do |task, worktree, marker|
      blob = File.join(worktree, "storage", "runtime-blob")
      File.binwrite(blob, "runtime bytes")
      journal(task, worktree, marker, [ "storage/runtime-blob" ])
      File.binwrite(blob, "RUNTIME BYTES")

      error = assert_raises(Recovery::RecoveryError) do
        Recovery.new.recover(task:, marker:, intended_stage: "7-artifacts")
      end

      assert_includes error.message, "changed after it was journaled"
      assert_path_exists blob
    end
  end

  def test_quarantine_entry_that_does_not_match_the_journal_fails_closed
    with_fixture do |task, worktree, marker|
      File.binwrite(File.join(worktree, "storage", "runtime-blob"), "runtime bytes")
      journal(task, worktree, marker, [ "storage/runtime-blob" ])
      destination = File.join(
        File.dirname(receipt_path(task, marker)), "storage", "runtime-blob"
      )
      FileUtils.mkdir_p(File.dirname(destination), mode: 0o700)
      File.binwrite(destination, "corrupted")

      error = assert_raises(Recovery::RecoveryError) do
        Recovery.new.recover(task:, marker:, intended_stage: "7-artifacts")
      end

      assert_includes error.message, "quarantine entry is invalid"
    end
  end

  def test_journalled_entries_can_never_reach_outside_their_roots
    with_fixture do |task, worktree, marker|
      File.binwrite(File.join(worktree, "storage", "runtime-blob"), "runtime bytes")
      journal(task, worktree, marker, [ "storage/runtime-blob" ]) do |receipt|
        receipt.merge("entries" => [ receipt.fetch("entries").first.merge("path" => "../escape") ])
      end

      error = assert_raises(Recovery::RecoveryError) do
        Recovery.new.recover(task:, marker:, intended_stage: "7-artifacts")
      end

      assert_includes error.message, "path escapes its root"
    end
  end

  def test_journalled_entries_can_never_reach_through_a_symlinked_parent
    with_fixture do |task, worktree, marker|
      outside = File.join(File.dirname(worktree), "outside")
      FileUtils.mkdir_p(outside)
      File.binwrite(File.join(outside, "blob"), "runtime bytes")
      File.symlink(outside, File.join(worktree, "storage", "link"))
      journal(
        task, worktree, marker, [ "storage/link" ],
        entries: [ entry(File.join(outside, "blob")).merge("path" => "storage/link/blob") ]
      )

      error = assert_raises(Recovery::RecoveryError) do
        Recovery.new.recover(task:, marker:, intended_stage: "7-artifacts")
      end

      assert_includes error.message, "parent escapes its root"
    end
  end

  def test_residue_larger_than_the_quarantine_budget_fails_closed
    with_fixture do |task, worktree, marker|
      3.times do |index|
        path = File.join(worktree, "storage", "bulk-#{index}")
        File.open(path, "wb") { |file| file.truncate(Recovery::MAX_FILE_BYTES) }
      end

      error = assert_raises(Recovery::RecoveryError) do
        Recovery.new.recover(task:, marker:, intended_stage: "7-artifacts")
      end

      assert_includes error.message, "exceeds the quarantine byte limit"
    end
  end

  def test_quarantine_keeps_runtime_parents_that_still_hold_tracked_files
    with_fixture do |task, worktree, marker|
      tracked = File.join(worktree, "storage", "as", ".keep")
      FileUtils.mkdir_p(File.dirname(tracked))
      File.write(tracked, "")
      git(worktree, "add", ".")
      git(worktree, "commit", "-qm", "tracked runtime parent")
      blob = File.join(worktree, "storage", "as", "aa", "runtime-blob")
      FileUtils.mkdir_p(File.dirname(blob))
      File.binwrite(blob, "runtime bytes")

      result = Recovery.new.recover(task:, marker:, intended_stage: "7-artifacts")

      assert_equal :quarantined, result.status
      refute_path_exists File.join(worktree, "storage", "as", "aa")
      assert_path_exists tracked
      assert_empty git(worktree, "status", "--porcelain", "--untracked-files=all")
    end
  end

  def test_quarantine_that_leaves_the_worktree_dirty_fails_closed
    leaky = Class.new(Recovery) do
      private def prune_empty_runtime_parents(worktree, paths)
        super
        File.binwrite(File.join(worktree, "storage", "left-behind"), "residue")
      end
    end

    with_fixture do |task, worktree, marker|
      File.binwrite(File.join(worktree, "storage", "runtime-blob"), "runtime bytes")

      error = assert_raises(Recovery::RecoveryError) do
        leaky.new.recover(task:, marker:, intended_stage: "7-artifacts")
      end

      assert_includes error.message, "left the implementation worktree dirty"
    end
  end

  private

  # Writes the prepared quarantine journal that a killed recovery would leave
  # behind, so resume, conflict, and containment paths can be exercised
  # without racing a real interruption. The optional block rewrites the
  # receipt after it is built, which is how entries that a correct run could
  # never journal are forged.
  def journal(task, worktree, marker, paths, **overrides)
    overrides = overrides.transform_keys(&:to_s)
    entries = overrides["entries"] ||
              paths.map { |path| entry(File.join(worktree, path)).merge("path" => path) }
    receipt = {
      "schema" => "hive-artifact-runtime-residue",
      "schema_version" => 1,
      "status" => "prepared",
      "marker_id" => marker.attrs.fetch("marker_id"),
      "worktree" => File.realpath(worktree),
      "paths" => paths,
      "entries" => entries,
      "prepared_at" => Time.now.utc.iso8601(6)
    }.merge(overrides)
    receipt = yield(receipt) if block_given?
    path = receipt_path(task, marker)
    FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
    File.binwrite(path, JSON.pretty_generate(receipt) + "\n")
    receipt
  end

  def entry(source)
    stat = File.lstat(source)
    {
      "size" => stat.size, "mode" => stat.mode & 0o7777,
      "sha256" => Digest::SHA256.file(source).hexdigest,
      "device" => stat.dev, "inode" => stat.ino
    }
  end

  def receipt_path(task, marker)
    File.join(
      task.folder, "outcome-evidence", "runtime-residue-quarantine",
      marker.attrs.fetch("marker_id"), "receipt.json"
    )
  end

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
