require "test_helper"
require "hive/commands/init"
require "hive/finalization/archive_cleanup"
require "hive/task"

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

  def test_cleanup_rejects_missing_stale_and_nonterminal_job_ownership
    with_ready_task do |_dir, task, context|
      job = context.fetch(:store).read(context.dig(:job, "job_id"))
      [
        nil,
        job.merge("head_sha" => "b" * 40),
        job.merge("state" => "active")
      ].each do |current|
        store = fake_job_store(current, current ? [ current ] : [])
        assert_raises(Hive::Finalization::StaleEvidence) do
          Hive::Finalization::ArchiveCleanup.new(task: task, clock: -> { NOW }, job_store: store).call
        end
      end
    end
  end

  def test_cleanup_rejects_corrupt_claim_timestamps
    with_ready_task do |_dir, task, context|
      job = context.fetch(:store).read(context.dig(:job, "job_id"))
      corrupt = job.merge("claims" => [ { "state" => "active", "expires_at" => "not-time" } ])

      error = assert_raises(Hive::Finalization::StaleEvidence) do
        Hive::Finalization::ArchiveCleanup.new(
          task: task, clock: -> { NOW }, job_store: fake_job_store(corrupt, [ corrupt ])
        ).call
      end
      assert_includes error.message, "claim evidence"
    end
  end

  def test_cleanup_pointer_must_match_the_exact_task_path_and_branch
    with_ready_task do |dir, task, context|
      canonical_root = Hive::Worktree.canonical_root(dir)
      FileUtils.mkdir_p(File.join(canonical_root, "other-task"))
      File.write(File.join(task.folder, "worktree.yml"),
                 { "path" => File.join(canonical_root, "other-task"), "branch" => task.slug }.to_yaml)
      assert_raises(Hive::WorktreeError) do
        Hive::Finalization::ArchiveCleanup.new(task: task, clock: -> { NOW }).call
      end

      File.write(File.join(task.folder, "worktree.yml"),
                 { "path" => File.join(canonical_root, task.slug), "branch" => "other-branch" }.to_yaml)
      assert_raises(Hive::WorktreeError) do
        Hive::Finalization::ArchiveCleanup.new(task: task, clock: -> { NOW }).call
      end
      refute_nil context
    end
  end

  def test_worktree_removal_handles_stale_registration_and_refuses_unregistered_paths
    with_done_task do |dir, task|
      expected = File.join(Hive::Worktree.canonical_root(dir), task.slug)
      worktree = Object.new
      worktree.define_singleton_method(:list_worktree_paths) { [ expected ] }
      worktree.define_singleton_method(:remove!) { |**_kwargs| nil }
      prunes = 0
      git = Object.new
      git.define_singleton_method(:prune_worktrees_strict!) { prunes += 1 }
      cleanup = Hive::Finalization::ArchiveCleanup.new(
        task: task, worktree_factory: ->(_root, _slug) { worktree }, git_ops: git
      )
      cleanup.send(:remove_worktree!, expected)
      assert_equal 1, prunes
      assert_raises(Hive::WorktreeError) { cleanup.send(:ensure_worktree_absent!, expected) }

      FileUtils.mkdir_p(expected)
      unregistered = Object.new
      unregistered.define_singleton_method(:list_worktree_paths) { [] }
      refusing = Hive::Finalization::ArchiveCleanup.new(
        task: task, worktree_factory: ->(_root, _slug) { unregistered }, git_ops: git
      )
      assert_raises(Hive::WorktreeError) { refusing.send(:remove_worktree!, expected) }
    end
  end

  def test_cleanup_receipt_requires_archive_task_identity
    with_done_task do |_dir, task|
      cleanup = Hive::Finalization::ArchiveCleanup.new(task: task)
      finalization = {
        "job_id" => "job", "repository" => "github.com/acme/demo", "pr_number" => 12,
        "pr_url" => "https://github.com/acme/demo/pull/12", "head_sha" => "a" * 40,
        "head_generation" => 1, "finalize_attempt_id" => "attempt-1", "task_generation" => 1,
        "evidence" => { "archive_ready_event_id" => "archive" }
      }
      assert_raises(Hive::Finalization::StaleEvidence) do
        cleanup.send(:append_receipt!, [ { "event_id" => "archive" } ], finalization,
                     "/tmp/worktree", "branch")
      end
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

  def fake_job_store(current, jobs)
    Object.new.tap do |store|
      store.define_singleton_method(:current_job) { |**_kwargs| current }
      store.define_singleton_method(:jobs) { jobs }
    end
  end
end
