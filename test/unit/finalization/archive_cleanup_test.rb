require "test_helper"
require "hive/commands/init"
require "hive/finalization/archive_cleanup"

class FinalizationArchiveCleanupTest < Minitest::Test
  include HiveTestHelper

  NOW = HiveFinalizationTestHelper::FINALIZATION_TEST_NOW

  def test_cleanup_requires_archive_ready_before_any_mutation
    with_done_task do |dir, task|
      path = Hive::Worktree.new(dir, task.slug).path
      Hive::Worktree.new(dir, task.slug).create!(task.slug, default_branch: "master")
      File.write(File.join(task.folder, "worktree.yml"),
                 { "path" => path, "branch" => task.slug }.to_yaml)

      error = assert_raises(Hive::Finalization::StaleEvidence) do
        Hive::Finalization::ArchiveCleanup.new(task: task, clock: -> { NOW }).call
      end

      assert_includes error.message, "archive_ready"
      assert File.directory?(path)
      assert Hive::GitOps.new(dir).ref_exists?("refs/heads/#{task.slug}")
    end
  end

  def test_cleanup_removes_exact_registered_worktree_and_branch_once
    with_ready_task(create_worktree: true) do |dir, task, _context|
      path = Hive::Worktree.read_pointer(task.folder).fetch("path")
      cleanup = Hive::Finalization::ArchiveCleanup.new(task: task, clock: -> { NOW })

      first = cleanup.call
      second = cleanup.call

      assert_equal :completed, first.status
      assert_equal :already_completed, second.status
      assert_equal first.event_id, second.event_id
      refute File.exist?(path)
      refute Hive::GitOps.new(dir).ref_exists?("refs/heads/#{task.slug}")
      records = Hive::TaskProjection.read_journal(File.join(task.folder, "events.jsonl"))
      assert_equal 1, records.count { |record| record["event_type"] == "cleanup_completed" }
    end
  end

  def test_cleanup_resumes_after_crash_following_worktree_removal
    with_ready_task(create_worktree: true) do |dir, task, _context|
      path = Hive::Worktree.read_pointer(task.folder).fetch("path")
      crashing = Hive::Finalization::ArchiveCleanup.new(
        task: task, clock: -> { NOW },
        after_step: ->(step) { raise "crash after worktree" if step == :worktree_removed }
      )

      assert_raises(RuntimeError) { crashing.call }
      refute File.exist?(path)
      assert Hive::GitOps.new(dir).ref_exists?("refs/heads/#{task.slug}")

      result = Hive::Finalization::ArchiveCleanup.new(task: task, clock: -> { NOW }).call
      assert_equal :completed, result.status
      refute Hive::GitOps.new(dir).ref_exists?("refs/heads/#{task.slug}")
    end
  end

  def test_cleanup_resumes_after_crash_following_branch_deletion
    with_ready_task(create_worktree: true) do |dir, task, _context|
      crashing = Hive::Finalization::ArchiveCleanup.new(
        task: task, clock: -> { NOW },
        after_step: ->(step) { raise "crash after branch" if step == :branch_deleted }
      )

      assert_raises(RuntimeError) { crashing.call }
      refute Hive::GitOps.new(dir).ref_exists?("refs/heads/#{task.slug}")
      records = Hive::TaskProjection.read_journal(File.join(task.folder, "events.jsonl"))
      refute records.any? { |record| record["event_type"] == "cleanup_completed" }

      result = Hive::Finalization::ArchiveCleanup.new(task: task, clock: -> { NOW }).call
      assert_equal :completed, result.status
    end
  end

  def test_cleanup_rejects_pointer_outside_canonical_root
    with_ready_task do |_dir, task, _context|
      File.write(File.join(task.folder, "worktree.yml"),
                 { "path" => "/tmp/not-this-task", "branch" => task.slug }.to_yaml)

      assert_raises(Hive::WorktreeError) do
        Hive::Finalization::ArchiveCleanup.new(task: task, clock: -> { NOW }).call
      end
      assert_nil cleanup_event(task)
    end
  end

  def test_cleanup_rejects_live_claim_and_newer_generation_owner
    with_ready_task(release_claim: false) do |dir, task, _context|
      error = assert_raises(Hive::Finalization::StaleEvidence) do
        Hive::Finalization::ArchiveCleanup.new(task: task, clock: -> { NOW + 1 }).call
      end
      assert_includes error.message, "live babysitter claim"

      # Once the old live claim is no longer relevant, a later generation is
      # still an independent fence against deleting its same-named branch.
      store = Hive::Babysitter::JobStore.new(project_root: dir, clock: -> { NOW + 400 })
      store.release!(_context.fetch(:token), outcome: "expired test owner", now: NOW + 400)
      store.reserve!(
        project: File.basename(dir), task_id: "42", task_slug: task.slug, task_generation: 2,
        repository: "github.com/acme/demo", pr_number: 43,
        pr_url: "https://github.com/acme/demo/pull/43", branch: task.slug,
        head_sha: "b" * 40, head_generation: 1, finalize_attempt_id: "attempt-2",
        task_folder: task.folder, now: NOW + 400
      )
      error = assert_raises(Hive::Finalization::StaleEvidence) do
        Hive::Finalization::ArchiveCleanup.new(task: task, clock: -> { NOW + 400 }).call
      end
      assert_includes error.message, "newer task generation"
      assert_nil cleanup_event(task)
    end
  end

  def test_cleanup_rejects_branch_checked_out_in_an_unrelated_worktree
    with_ready_task do |dir, task, _context|
      unrelated_root = Dir.mktmpdir("hive-unrelated-worktrees")
      unrelated = Hive::Worktree.new(dir, "other", worktree_root: unrelated_root)
      unrelated.create!(task.slug, default_branch: "master")

      error = assert_raises(Hive::GitError) do
        capture_io do
          Hive::Finalization::ArchiveCleanup.new(task: task, clock: -> { NOW }).call
        end
      end

      assert_includes error.message, "remains checked out or owned"
      assert File.directory?(unrelated.path)
      assert Hive::GitOps.new(dir).ref_exists?("refs/heads/#{task.slug}")
      assert_nil cleanup_event(task)
    ensure
      FileUtils.rm_rf(unrelated_root)
    end
  end

  private

  def with_done_task
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        slug = "cleanup-task-260717-aaaa"
        folder = File.join(dir, ".hive-state", "stages", "9-done", slug)
        FileUtils.mkdir_p(folder)
        File.write(File.join(folder, "task.md"), "## done\n")
        yield dir, Hive::Task.new(folder)
      end
    end
  end

  def with_ready_task(create_worktree: false, release_claim: true)
    with_done_task do |dir, task|
      Hive::Worktree.new(dir, task.slug).create!(task.slug, default_branch: "master") if create_worktree
      context = prepare_archive_ready(
        project_root: dir, task_folder: task.folder, slug: task.slug,
        now: NOW, release_claim: release_claim
      )
      yield dir, task, context
    end
  end

  def cleanup_event(task)
    Hive::TaskProjection.read_journal(File.join(task.folder, "events.jsonl"))
                        .find { |record| record["event_type"] == "cleanup_completed" }
  end
end
