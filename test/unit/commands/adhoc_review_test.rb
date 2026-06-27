require "test_helper"
require "hive/commands/adhoc_review"

class AdhocReviewCommandTest < Minitest::Test
  include HiveTestHelper

  def metadata(number: 197, head: "head-197", fork: false)
    Hive::Gh::PrMetadata.new(
      number: number,
      url: "https://github.com/o/r/pull/#{number}",
      base_ref_name: "main",
      head_ref_oid: head,
      is_cross_repository: fork,
      state: "OPEN"
    )
  end

  def with_registered_project
    with_tmp_global_config do
      with_tmp_git_repo do |repo|
        hive_state = File.join(repo, ".hive-state")
        worktree_root = File.join(repo, "adhoc-worktrees")
        FileUtils.mkdir_p(File.join(hive_state, "stages", "6-review"))
        File.write(File.join(hive_state, "config.yml"), { "worktree_root" => worktree_root }.to_yaml)
        Hive::Config.register_project(name: "demo", path: repo)
        Dir.chdir(repo) { yield(repo, hive_state, worktree_root) }
      end
    end
  end

  def frontmatter(path)
    Hive::Gh.pr_frontmatter(path)
  end

  def write_frontmatter(path, data)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{data.to_yaml}---\n\nbody\n")
  end

  def test_enqueue_creates_synthetic_review_task_and_reuses_it
    with_registered_project do |_repo, hive_state, worktree_root|
      calls = []
      now = Time.utc(2026, 1, 2, 3, 4, 5)
      pr_metadata = metadata(fork: true)

      with_replaced_singleton_method(Hive::Gh, :pr_metadata, ->(_number, **_kwargs) { pr_metadata }) do
        with_replaced_singleton_method(Hive::Worktree, :materialize_pr, lambda { |**kwargs|
          calls << kwargs
          { path: kwargs.fetch(:path), branch: kwargs.fetch(:branch), head_sha: "head-197" }
        }) do
          first = Hive::Commands::AdhocReview.new(pr: "#197").enqueue(now: now)
          second = Hive::Commands::AdhocReview.new(pr: "https://github.com/o/r/pull/197").enqueue(now: now)
          called_slug = Hive::Commands::AdhocReview.new(pr: "197").call

          assert_equal "adhoc-review-pr-197", first.fetch(:slug)
          assert_equal "adhoc-review-pr-197", second.fetch(:slug)
          assert_equal "adhoc-review-pr-197", called_slug
          assert_equal false, first.fetch(:reused)
          assert_equal true, second.fetch(:reused)
        end
      end

      task_folder = File.join(hive_state, "stages", "6-review", "adhoc-review-pr-197")
      assert_equal 1, calls.size, "reusing an existing ad-hoc task must not materialize or allocate again"
      assert_equal File.join(worktree_root, "adhoc-review-pr-197"), calls.first.fetch(:path)
      assert_equal "hive/review/pr-197", calls.first.fetch(:branch)
      assert_equal 2, Hive::TaskCounter.peek, "second enqueue must not burn another task id"

      meta = YAML.safe_load(File.read(File.join(task_folder, "meta.yml")))
      assert_equal 1, meta.fetch("id")
      assert_equal "adhoc-review-pr-197", meta.fetch("slug")
      assert_equal "Ad-hoc review: PR #197", meta.fetch("display_name")
      assert_equal "coding", meta.fetch("workflow")

      idea = frontmatter(File.join(task_folder, "idea.md"))
      assert_equal "ad-hoc", idea.fetch("source")
      assert_equal "review PR #197", idea.fetch("original_text")

      task = frontmatter(File.join(task_folder, "task.md"))
      assert_equal "ad-hoc", task.fetch("source")
      assert_equal "https://github.com/o/r/pull/197", task.fetch("pr_url")

      pr = frontmatter(File.join(task_folder, "pr.md"))
      assert_equal "ad-hoc", pr.fetch("source")
      assert_equal 197, pr.fetch("pr_number")
      assert_equal "main", pr.fetch("base_ref_name")
      assert_equal "head-197", pr.fetch("head_ref_oid")
      assert_equal true, pr.fetch("is_cross_repository")
      assert_equal "OPEN", pr.fetch("state")

      worktree = YAML.safe_load(File.read(File.join(task_folder, "worktree.yml")))
      assert_equal File.join(worktree_root, "adhoc-review-pr-197"), worktree.fetch("path")
      assert_equal "hive/review/pr-197", worktree.fetch("branch")
      assert_equal "head-197", worktree.fetch("execute_base_head")
      assert_equal now.utc.iso8601, worktree.fetch("created_at")
      assert_empty Dir.children(File.join(task_folder, "reviews"))
    end
  end

  def test_enqueue_refuses_pr_owned_by_different_task
    with_registered_project do |_repo, hive_state, _worktree_root|
      write_frontmatter(
        File.join(hive_state, "stages", "5-open-pr", "owned-task", "pr.md"),
        "pr_number" => 197,
        "pr_url" => "https://github.com/o/r/pull/197"
      )

      pr_metadata = metadata
      with_replaced_singleton_method(Hive::Gh, :pr_metadata, ->(_number, **_kwargs) { pr_metadata }) do
        with_replaced_singleton_method(Hive::Worktree, :materialize_pr, ->(**_kwargs) { flunk "must not materialize" }) do
          err = assert_raises(Hive::Commands::AdhocReview::CollisionError) do
            Hive::Commands::AdhocReview.new(pr: "197").enqueue
          end

          assert_match(/owned by hive task owned-task at 5-open-pr/, err.message)
          assert_match(/hive review owned-task/, err.message)
          refute Dir.exist?(File.join(hive_state, "stages", "6-review", "adhoc-review-pr-197"))
        end
      end
    end
  end

  def test_enqueue_refuses_same_adhoc_slug_in_another_stage
    with_registered_project do |_repo, hive_state, _worktree_root|
      FileUtils.mkdir_p(File.join(hive_state, "stages", "7-artifacts", "adhoc-review-pr-197"))

      pr_metadata = metadata
      with_replaced_singleton_method(Hive::Gh, :pr_metadata, ->(_number, **_kwargs) { pr_metadata }) do
        err = assert_raises(Hive::Commands::AdhocReview::CollisionError) do
          Hive::Commands::AdhocReview.new(pr: "197").enqueue
        end

        assert_match(/adhoc-review-pr-197 at 7-artifacts/, err.message)
      end
    end
  end

  def test_enqueue_removes_fresh_task_folder_when_materialized_head_mismatches_metadata
    with_registered_project do |_repo, hive_state, _worktree_root|
      pr_metadata = metadata(head: "expected")
      with_replaced_singleton_method(Hive::Gh, :pr_metadata, ->(_number, **_kwargs) { pr_metadata }) do
        with_replaced_singleton_method(Hive::Worktree, :materialize_pr, lambda { |**kwargs|
          { path: kwargs.fetch(:path), branch: kwargs.fetch(:branch), head_sha: "actual" }
        }) do
          err = assert_raises(Hive::WorktreeError) do
            Hive::Commands::AdhocReview.new(pr: "197").enqueue
          end

          assert_match(/GitHub reported head expected/, err.message)
          refute Dir.exist?(File.join(hive_state, "stages", "6-review", "adhoc-review-pr-197"))
        end
      end
    end
  end

  def test_enqueue_maps_invalid_pr_identifier_to_usage_error
    with_registered_project do
      err = assert_raises(Hive::InvalidTaskPath) do
        Hive::Commands::AdhocReview.new(pr: "not-a-pr").enqueue
      end

      assert_match(/invalid PR identifier/, err.message)
    end
  end

  def test_enqueue_cleans_up_worktree_branch_and_ref_when_create_fails
    with_registered_project do |repo, hive_state, worktree_root|
      pr_metadata = metadata(head: "expected-head")
      branch = "hive/review/pr-197"
      worktree_path = File.join(worktree_root, "adhoc-review-pr-197")

      with_replaced_singleton_method(Hive::Gh, :pr_metadata, ->(_number, **_kwargs) { pr_metadata }) do
        with_replaced_singleton_method(Hive::Worktree, :materialize_pr, lambda { |repo_root:, pr_number:, path:, branch:|
          # Create the real worktree + branch + ref production materialize_pr
          # leaves behind, but with a head that won't match metadata so
          # verify_head! aborts *after* `git worktree add` succeeded.
          Hive::Worktree.run_materialize_git!(repo_root, "update-ref", "refs/#{branch}", "HEAD")
          Hive::Worktree.run_materialize_git!(repo_root, "worktree", "add", "-B", branch, path, "refs/#{branch}")
          { path: path, branch: branch, head_sha: "actual-head" }
        }) do
          assert_raises(Hive::WorktreeError) { Hive::Commands::AdhocReview.new(pr: "197").enqueue }
        end
      end

      refute Dir.exist?(File.join(hive_state, "stages", "6-review", "adhoc-review-pr-197")),
             "task folder must be removed on create failure"
      refute Dir.exist?(worktree_path), "orphaned worktree must be removed on create failure"
      refute Hive::Worktree.local_branch_ref_exists?(repo, branch),
             "orphaned branch must be removed so a retry is not wedged"

      # The wedge this guards against: a leftover worktree/branch makes the
      # next `git worktree add` fail with "already exists". Prove a retry is
      # clean against a freshly-recreated ref.
      Hive::Worktree.run_materialize_git!(repo, "update-ref", "refs/#{branch}", "HEAD")
      out, _err, status = Open3.capture3("git", "-C", repo, "worktree", "add", "-B", branch, worktree_path, "refs/#{branch}")
      assert status.success?, "retry `git worktree add` must succeed after cleanup: #{out}"
    end
  end

  def test_enqueue_refuses_to_reuse_non_adhoc_folder_at_same_slug
    with_registered_project do |_repo, hive_state, _worktree_root|
      # A normal (non-ad-hoc) task happens to occupy the deterministic ad-hoc
      # slug; it must not be silently adopted and re-run as the ad-hoc review.
      write_frontmatter(
        File.join(hive_state, "stages", "6-review", "adhoc-review-pr-197", "pr.md"),
        "pr_number" => 197,
        "pr_url" => "https://github.com/o/r/pull/197",
        "source" => "telegram"
      )

      with_replaced_singleton_method(Hive::Worktree, :materialize_pr, ->(**_kwargs) { flunk "must not materialize" }) do
        err = assert_raises(Hive::Commands::AdhocReview::CollisionError) do
          Hive::Commands::AdhocReview.new(pr: "197").enqueue
        end

        assert_match(/not an ad-hoc review for PR #197/, err.message)
        assert_match(/hive drop adhoc-review-pr-197/, err.message)
      end
    end
  end
end
