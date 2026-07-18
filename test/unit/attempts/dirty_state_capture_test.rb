require "test_helper"
require "json"
require "hive/attempts/dirty_state_capture"
require "hive/attempts/store"

class AttemptsDirtyStateCaptureTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 16, 12, 0, 0)

  def test_captures_committed_staged_unstaged_untracked_and_binary_state_without_mutation
    with_tmp_git_repo do |worktree|
      File.write(File.join(worktree, "committed.txt"), "committed\n")
      run!("git", "-C", worktree, "add", "committed.txt")
      run!("git", "-C", worktree, "commit", "-m", "partial work", "--quiet")
      File.write(File.join(worktree, "staged.txt"), "staged\n")
      run!("git", "-C", worktree, "add", "staged.txt")
      File.write(File.join(worktree, "README.md"), "unstaged\n")
      File.binwrite(File.join(worktree, "binary.bin"), "\x00\xFFpartial".b)
      File.write(File.join(worktree, "untracked.txt"), "untracked\n")
      File.symlink("untracked.txt", File.join(worktree, "untracked-link"))

      before_revision = run!("git", "-C", worktree, "rev-parse", "HEAD")
      before_status = run!("git", "-C", worktree, "status", "--porcelain=v2", "--untracked-files=all")
      untracked_hash = Digest::SHA256.file(File.join(worktree, "binary.bin")).hexdigest

      with_tmp_dir do |root|
        store = Hive::Attempts::Store.new(root: root)
        capture = Hive::Attempts::DirtyStateCapture.new(store: store).capture(
          attempt: lost_attempt(store), worktree: worktree, now: NOW
        )

        assert_equal before_revision, run!("git", "-C", worktree, "rev-parse", "HEAD")
        assert_equal before_status,
                     run!("git", "-C", worktree, "status", "--porcelain=v2", "--untracked-files=all")
        assert capture.references.all? { |reference| Hive::Attempts::OutputReference.verify(reference, root: root) }
        manifest = JSON.parse(File.binread(File.join(capture.directory, "manifest.json")))
        binary = manifest.fetch("untracked").find do |entry|
          Base64.strict_decode64(entry.fetch("path_base64")) == "binary.bin"
        end
        assert_equal untracked_hash, binary.fetch("sha256")
        symlink = manifest.fetch("untracked").find do |entry|
          Base64.strict_decode64(entry.fetch("path_base64")) == "untracked-link"
        end
        assert_equal "untracked.txt", Base64.strict_decode64(symlink.fetch("target_base64"))
        assert_operator File.size(File.join(capture.directory, "staged.patch")), :>, 0
        assert_operator File.size(File.join(capture.directory, "unstaged.patch")), :>, 0

        capture_service = Hive::Attempts::DirtyStateCapture.new(store: store)
        with_replaced_singleton_method(File, :lstat, ->(_path) { raise Errno::EACCES }) do
          unreadable = capture_service.send(:untracked_metadata, worktree, "vanished")
          assert_equal "Errno::EACCES", unreadable.fetch("unreadable")
        end
      end
    end
  end

  private

  def lost_attempt(store)
    attempt = store.create_launching(
      attempt_id: "lost-1", request_id: "request-1", predecessor_attempt_id: nil,
      task_id: "42", project: "demo", task_slug: "durable-task",
      intended_stage: "4-execute", task_generation: "generation-1",
      progress_token: "progress", provider: "codex",
      worker_argv: [ "hive", "run", "durable-task" ],
      claim_capability_digest: Hive::Attempts::Capability.digest("c" * 64),
      starting_revision: nil,
      retry_charge: 0, inherited_outputs: [], launch_timeout_sec: 30, now: NOW
    )
    store.mark_lost(attempt, reason: "launch_timeout", now: NOW + 31)
  end
end
