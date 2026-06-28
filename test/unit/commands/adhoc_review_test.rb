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
          # Create the worktree dir like production does so the reuse path's
          # worktree-exists check (validate_reusable!) is satisfied on re-run.
          FileUtils.mkdir_p(kwargs.fetch(:path))
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

  def test_enqueue_refuses_to_reuse_adhoc_folder_owning_a_different_pr
    # A reuse folder that IS source: ad-hoc but whose pr.md records a different
    # PR than requested (corrupted/hand-edited) must not be silently reused
    # against the wrong PR's worktree — the PR-number half of the
    # refuse-to-shadow guard.
    with_registered_project do |_repo, hive_state, worktree_root|
      slug = "adhoc-review-pr-197"
      folder = File.join(hive_state, "stages", "6-review", slug)
      write_frontmatter(
        File.join(folder, "pr.md"),
        "pr_number" => 198, "source" => "ad-hoc",
        "pr_url" => "https://github.com/o/r/pull/198"
      )
      worktree_path = File.join(worktree_root, slug)
      FileUtils.mkdir_p(worktree_path)
      File.write(File.join(folder, "worktree.yml"),
                 { "path" => worktree_path, "branch" => "hive/review/pr-197" }.to_yaml)

      with_replaced_singleton_method(Hive::Worktree, :materialize_pr, ->(**_kwargs) { flunk "must not materialize" }) do
        err = assert_raises(Hive::Commands::AdhocReview::CollisionError) do
          Hive::Commands::AdhocReview.new(pr: "197").enqueue
        end

        assert_match(/not an ad-hoc review for PR #197/, err.message)
        assert_match(/pr_number=198/, err.message)
        assert_match(/hive drop adhoc-review-pr-197/, err.message)
      end
    end
  end

  def test_enqueue_reuse_refuses_when_the_worktree_pointer_is_missing
    # An ad-hoc reuse folder with NO worktree.yml at all must fail cleanly at
    # enqueue, naming the missing pointer (not a deleted worktree) so the
    # remediation matches the real cause.
    with_registered_project do |_repo, hive_state, _worktree_root|
      slug = "adhoc-review-pr-197"
      folder = File.join(hive_state, "stages", "6-review", slug)
      write_frontmatter(
        File.join(folder, "pr.md"),
        "pr_number" => 197, "source" => "ad-hoc",
        "pr_url" => "https://github.com/o/r/pull/197"
      )
      # No worktree.yml written.

      with_replaced_singleton_method(Hive::Worktree, :materialize_pr, ->(**_kwargs) { flunk "must not materialize" }) do
        err = assert_raises(Hive::Commands::AdhocReview::CollisionError) do
          Hive::Commands::AdhocReview.new(pr: "197").enqueue
        end

        assert_match(/worktree pointer/, err.message)
        assert_match(/is missing/, err.message)
        assert_match(/hive drop adhoc-review-pr-197/, err.message)
      end
    end
  end

  def test_enqueue_reuses_folder_whose_source_casing_drifted
    # The review stage routes `source: Ad-Hoc` as ad-hoc (strip + casecmp?);
    # the reuse validator must agree, not reject it as "not an ad-hoc review".
    with_registered_project do |_repo, hive_state, worktree_root|
      slug = "adhoc-review-pr-197"
      folder = File.join(hive_state, "stages", "6-review", slug)
      write_frontmatter(
        File.join(folder, "pr.md"),
        "pr_number" => 197, "source" => "Ad-Hoc",
        "pr_url" => "https://github.com/o/r/pull/197"
      )
      worktree_path = File.join(worktree_root, slug)
      FileUtils.mkdir_p(worktree_path)
      File.write(File.join(folder, "worktree.yml"),
                 { "path" => worktree_path, "branch" => "hive/review/pr-197" }.to_yaml)

      with_replaced_singleton_method(Hive::Worktree, :materialize_pr, ->(**_kwargs) { flunk "reuse must not materialize" }) do
        result = Hive::Commands::AdhocReview.new(pr: "197").enqueue

        assert_equal slug, result.fetch(:slug)
        assert_equal true, result.fetch(:reused)
      end
    end
  end

  def test_enqueue_reuse_refuses_when_the_carried_over_worktree_is_missing
    # A reuse folder whose worktree was pruned/removed must fail cleanly at
    # enqueue (pointing at `hive drop`) rather than deep in the review stage.
    with_registered_project do |_repo, hive_state, worktree_root|
      slug = "adhoc-review-pr-197"
      folder = File.join(hive_state, "stages", "6-review", slug)
      write_frontmatter(
        File.join(folder, "pr.md"),
        "pr_number" => 197, "source" => "ad-hoc",
        "pr_url" => "https://github.com/o/r/pull/197"
      )
      # worktree.yml points at a directory that no longer exists.
      File.write(File.join(folder, "worktree.yml"),
                 { "path" => File.join(worktree_root, slug), "branch" => "hive/review/pr-197" }.to_yaml)

      with_replaced_singleton_method(Hive::Worktree, :materialize_pr, ->(**_kwargs) { flunk "must not materialize" }) do
        err = assert_raises(Hive::Commands::AdhocReview::CollisionError) do
          Hive::Commands::AdhocReview.new(pr: "197").enqueue
        end

        assert_match(/worktree is missing/, err.message)
        assert_match(/hive drop adhoc-review-pr-197/, err.message)
      end
    end
  end

  def test_enqueue_queries_gh_in_the_resolved_project_root_not_cwd
    # The load-bearing chdir: kwarg is what makes --project query the right
    # repo; assert it reaches pr_metadata rather than defaulting to cwd.
    with_registered_project do |repo, _hive_state, _worktree_root|
      captured = {}
      pr_metadata = metadata
      with_replaced_singleton_method(Hive::Gh, :pr_metadata, lambda { |number, **kwargs|
        captured[:number] = number
        captured[:chdir] = kwargs[:chdir]
        pr_metadata
      }) do
        with_replaced_singleton_method(Hive::Worktree, :materialize_pr, lambda { |**kwargs|
          FileUtils.mkdir_p(kwargs.fetch(:path))
          { path: kwargs.fetch(:path), branch: kwargs.fetch(:branch), head_sha: "head-197" }
        }) do
          Hive::Commands::AdhocReview.new(pr: "197").enqueue
        end
      end

      assert_equal 197, captured[:number]
      assert_equal File.expand_path(repo), File.expand_path(captured.fetch(:chdir).to_s),
                   "pr_metadata must be queried in the resolved project root"
    end
  end

  def test_enqueue_resolves_relative_hive_state_path_against_project_root_not_cwd
    # register_project only ever writes absolute paths, but a hand-edited
    # *relative* hive_state_path must resolve against the project root (the
    # resolver registered_project! validates with), not the caller's cwd.
    with_tmp_global_config do |home|
      with_tmp_git_repo do |repo|
        hive_state = File.join(repo, ".hive-state")
        worktree_root = File.join(repo, "adhoc-worktrees")
        FileUtils.mkdir_p(File.join(hive_state, "stages", "6-review"))
        File.write(File.join(hive_state, "config.yml"), { "worktree_root" => worktree_root }.to_yaml)
        File.write(
          File.join(home, "config.yml"),
          {
            "registered_projects" => [
              { "name" => "demo", "path" => repo, "hive_state_path" => ".hive-state" }
            ]
          }.to_yaml
        )

        pr_metadata = metadata
        with_tmp_dir do |elsewhere|
          Dir.chdir(elsewhere) do
            with_replaced_singleton_method(Hive::Gh, :pr_metadata, ->(_number, **_kwargs) { pr_metadata }) do
              with_replaced_singleton_method(Hive::Worktree, :materialize_pr, lambda { |**kwargs|
                FileUtils.mkdir_p(kwargs.fetch(:path))
                { path: kwargs.fetch(:path), branch: kwargs.fetch(:branch), head_sha: "head-197" }
              }) do
                result = Hive::Commands::AdhocReview.new(pr: "197", project: "demo").enqueue

                expected = File.join(hive_state, "stages", "6-review", "adhoc-review-pr-197")
                assert_equal expected, result.fetch(:task_folder)
                assert File.directory?(expected),
                       "relative hive_state_path must resolve against the project root"
                refute File.directory?(File.join(elsewhere, ".hive-state")),
                       "must not write task state under the caller's cwd"
              end
            end
          end
        end
      end
    end
  end

  def test_enqueue_skips_head_check_and_warns_when_gh_reports_no_head_sha
    with_registered_project do |_repo, hive_state, _worktree_root|
      pr_metadata = metadata(head: "")
      with_replaced_singleton_method(Hive::Gh, :pr_metadata, ->(_number, **_kwargs) { pr_metadata }) do
        with_replaced_singleton_method(Hive::Worktree, :materialize_pr, lambda { |**kwargs|
          FileUtils.mkdir_p(kwargs.fetch(:path))
          { path: kwargs.fetch(:path), branch: kwargs.fetch(:branch), head_sha: "whatever-actual" }
        }) do
          result = nil
          _out, err = capture_io { result = Hive::Commands::AdhocReview.new(pr: "197").enqueue }

          assert_equal "adhoc-review-pr-197", result.fetch(:slug)
          assert_match(/gh reported no head SHA for PR #197/, err)
          assert Dir.exist?(File.join(hive_state, "stages", "6-review", "adhoc-review-pr-197")),
                 "an empty gh head must skip the head check, not abort task creation"
        end
      end
    end
  end

  def test_enqueue_collision_scan_skips_an_unreadable_pr_md_and_proceeds
    with_registered_project do |_repo, hive_state, _worktree_root|
      bad = File.join(hive_state, "stages", "5-open-pr", "other", "pr.md")
      write_frontmatter(bad, "pr_number" => 999, "pr_url" => "https://github.com/o/r/pull/999")
      pr_metadata = metadata
      original = Hive::Gh.method(:pr_frontmatter)

      with_replaced_singleton_method(Hive::Gh, :pr_frontmatter, lambda { |path|
        raise Errno::EACCES, path if path == bad

        original.call(path)
      }) do
        with_replaced_singleton_method(Hive::Gh, :pr_metadata, ->(_number, **_kwargs) { pr_metadata }) do
          with_replaced_singleton_method(Hive::Worktree, :materialize_pr, lambda { |**kwargs|
            FileUtils.mkdir_p(kwargs.fetch(:path))
            { path: kwargs.fetch(:path), branch: kwargs.fetch(:branch), head_sha: "head-197" }
          }) do
            result = nil
            _out, err = capture_io { result = Hive::Commands::AdhocReview.new(pr: "197").enqueue }

            assert_equal "adhoc-review-pr-197", result.fetch(:slug)
            assert_match(/collision scan skipping unreadable/, err)
            assert_match(/Errno::EACCES/, err)
          end
        end
      end
    end
  end

  def test_enqueue_refuses_slug_owner_before_pr_owner_when_both_collide
    with_registered_project do |_repo, hive_state, _worktree_root|
      # Same ad-hoc slug occupied in another stage (slug owner)...
      FileUtils.mkdir_p(File.join(hive_state, "stages", "7-artifacts", "adhoc-review-pr-197"))
      # ...AND a different task owning PR 197 (pr owner).
      write_frontmatter(
        File.join(hive_state, "stages", "5-open-pr", "owned-task", "pr.md"),
        "pr_number" => 197, "pr_url" => "https://github.com/o/r/pull/197"
      )

      pr_metadata = metadata
      with_replaced_singleton_method(Hive::Gh, :pr_metadata, ->(_number, **_kwargs) { pr_metadata }) do
        with_replaced_singleton_method(Hive::Worktree, :materialize_pr, ->(**_kwargs) { flunk "must not materialize" }) do
          err = assert_raises(Hive::Commands::AdhocReview::CollisionError) do
            Hive::Commands::AdhocReview.new(pr: "197").enqueue
          end

          # Slug-owner check runs first, so its message wins.
          assert_match(/adhoc-review-pr-197 at 7-artifacts/, err.message)
          refute_match(/owned-task/, err.message)
        end
      end
    end
  end

  def test_enqueue_self_heals_an_orphan_worktree_on_the_first_try
    with_registered_project do |repo, _hive_state, worktree_root|
      slug = "adhoc-review-pr-197"
      branch = "hive/review/pr-197"
      worktree_path = File.join(worktree_root, slug)

      # Wedge the slot the way a SIGKILL would: a real worktree whose dir is
      # then removed, leaving stale `.git/worktrees/<slug>` admin metadata.
      Hive::Worktree.run_materialize_git!(repo, "update-ref", "refs/#{branch}", "HEAD")
      Hive::Worktree.run_materialize_git!(repo, "worktree", "add", "-B", branch, worktree_path, "refs/#{branch}")
      FileUtils.rm_rf(worktree_path)

      pr_metadata = metadata
      with_replaced_singleton_method(Hive::Gh, :pr_metadata, ->(_number, **_kwargs) { pr_metadata }) do
        with_replaced_singleton_method(Hive::Worktree, :materialize_pr, lambda { |repo_root:, pr_number:, path:, branch:|
          # A real `git worktree add` exactly like production — this is the
          # call that fails with "already exists" unless the orphan admin
          # metadata was pruned first.
          Hive::Worktree.run_materialize_git!(repo_root, "update-ref", "refs/#{branch}", "HEAD")
          Hive::Worktree.run_materialize_git!(repo_root, "worktree", "add", "-B", branch, path, "refs/#{branch}")
          { path: path, branch: branch, head_sha: "head-197" }
        }) do
          result = Hive::Commands::AdhocReview.new(pr: "197").enqueue

          assert_equal slug, result.fetch(:slug)
          assert Dir.exist?(worktree_path),
                 "the worktree must be re-materialized on the FIRST try after a pre-materialize prune"
        end
      end
    end
  end

  def test_cleanup_failed_task_swallows_its_own_errors_so_the_original_failure_wins
    # cleanup runs inside create_task!'s rescue before the original error is
    # re-raised; its own spawn/IO errors must warn, not raise (and so mask it).
    cmd = Hive::Commands::AdhocReview.new(pr: "197")
    with_replaced_singleton_method(Open3, :capture3, ->(*_args) { raise Errno::ENOENT, "git" }) do
      err = nil
      _out, err = capture_io do
        cmd.send(:cleanup_failed_task!, "/tmp/repo", "adhoc-review-pr-197", 197, nil)
      end

      assert_match(/ad-hoc cleanup after a failed create did not complete/, err)
      assert_match(/Errno::ENOENT/, err)
    end
  end

  def test_cleanup_failed_task_warns_when_an_orphan_survives_cleanup
    with_registered_project do |repo, _hive_state, _worktree_root|
      cmd = Hive::Commands::AdhocReview.new(pr: "197")
      slug = "adhoc-review-pr-197"

      # Simulate a partial cleanup failure: the branch ref survives removal.
      with_replaced_singleton_method(Hive::Worktree, :local_branch_ref_exists?, ->(*_args) { true }) do
        _out, err = capture_io { cmd.send(:cleanup_failed_task!, repo, slug, 197, nil) }

        assert_match(/could not fully remove/, err)
        assert_match(%r{branch hive/review/pr-197}, err)
        assert_match(/worktree prune/, err)
      end
    end
  end
end
