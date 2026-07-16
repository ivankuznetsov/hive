require "test_helper"
require "json"
require "hive/cli"
require "hive/attempts/context"
require "hive/commands/adhoc_review"
require "hive/gh"
require "hive/markers"
require "hive/stages/review"
require "hive/worktree"

class AdhocReviewIntegrationTest < Minitest::Test
  include HiveTestHelper

  def metadata(number:, head:)
    Hive::Gh::PrMetadata.new(
      number: number,
      url: "https://github.com/o/r/pull/#{number}",
      base_ref_name: "main",
      head_ref_oid: head,
      is_cross_repository: false,
      state: "OPEN"
    )
  end

  def with_registered_project
    with_tmp_global_config do
      with_tmp_git_repo do |repo|
        hive_state = File.join(repo, ".hive-state")
        worktree_root = File.join(repo, "adhoc-worktrees")
        FileUtils.mkdir_p(File.join(hive_state, "stages", "6-review"))
        File.write(
          File.join(hive_state, "config.yml"),
          {
            "worktree_root" => worktree_root,
            "rebase" => { "enabled" => false }
          }.to_yaml
        )
        Hive::Config.register_project(name: "demo", path: repo)

        Dir.chdir(repo) { yield(repo, hive_state, worktree_root) }
      end
    end
  end

  def with_adhoc_review_stubs(head: "head-197", runs: [])
    materialized = []
    with_replaced_singleton_method(Hive::Gh, :pr_metadata, lambda { |number, **_kwargs|
      Hive::Gh::PrMetadata.new(
        number: number,
        url: "https://github.com/o/r/pull/#{number}",
        base_ref_name: "main",
        head_ref_oid: head,
        is_cross_repository: false,
        state: "OPEN"
      )
    }) do
      with_replaced_singleton_method(Hive::Worktree, :materialize_pr, lambda { |**kwargs|
        materialized << kwargs
        FileUtils.mkdir_p(kwargs.fetch(:path))
        { path: kwargs.fetch(:path), branch: kwargs.fetch(:branch), head_sha: head }
      }) do
        with_replaced_singleton_method(Hive::Stages::Review, :run!, lambda { |task, _cfg|
          runs << task.folder
          Hive::Markers.set(task.state_file, :review_waiting,
                            reason: "adhoc_fix_disabled",
                            accepted: 1,
                            pass: 1)
          { commit: nil, status: :review_waiting }
        }) do
          Hive::Attempts::Context.with(
            attempt_id: "adhoc-review-test-attempt",
            task_generation: "adhoc-review-test-generation"
          ) { yield materialized }
        end
      end
    end
  end

  def test_review_pr_creates_task_and_runs_review_stage
    with_registered_project do |_repo, hive_state, worktree_root|
      runs = []
      with_adhoc_review_stubs(runs: runs) do |materialized|
        out, _err, status = with_captured_exit { Hive::CLI.start([ "review", "--pr", "197" ]) }

        assert_equal Hive::ExitCodes::SUCCESS, status
        assert_includes out, "hive: marker=review_waiting"
        assert_includes out, "next:"

        slug = "adhoc-review-pr-197"
        folder = File.join(hive_state, "stages", "6-review", slug)
        assert_equal [ folder ], runs
        assert File.directory?(folder)
        assert File.directory?(File.join(folder, "reviews"))
        assert_equal File.join(worktree_root, slug), materialized.first.fetch(:path)
        assert_equal "hive/review/pr-197", materialized.first.fetch(:branch)

        pr = Hive::Gh.pr_frontmatter(File.join(folder, "pr.md"))
        assert_equal 197, pr.fetch("pr_number")
        assert_equal "ad-hoc", pr.fetch("source")
        assert_equal "main", pr.fetch("base_ref_name")

        worktree = YAML.safe_load(File.read(File.join(folder, "worktree.yml")))
        assert_equal File.join(worktree_root, slug), worktree.fetch("path")
        assert_equal "head-197", worktree.fetch("execute_base_head")
      end
    end
  end

  def test_review_pr_reuses_existing_task_on_next_pass
    with_registered_project do |_repo, hive_state, _worktree_root|
      runs = []
      with_adhoc_review_stubs(runs: runs) do |materialized|
        capture_io { Hive::CLI.start([ "review", "--pr", "#197" ]) }
        capture_io { Hive::CLI.start([ "review", "--pr", "https://github.com/o/r/pull/197" ]) }

        slug = "adhoc-review-pr-197"
        folder = File.join(hive_state, "stages", "6-review", slug)
        assert_equal [ folder, folder ], runs
        assert_equal 1, materialized.size, "second run must reuse the task/worktree instead of creating another"
        assert_equal [ slug ], Dir.children(File.join(hive_state, "stages", "6-review"))
      end
    end
  end

  def test_review_pr_reuse_stays_pinned_to_the_first_head_when_the_pr_is_repushed
    # Documents the known limitation: re-running `hive review --pr N` reuses
    # the worktree and never re-fetches, so a PR re-pushed between runs is
    # still reviewed against the first-run head (maintainer must `hive drop`).
    with_registered_project do |_repo, hive_state, _worktree_root|
      slug = "adhoc-review-pr-197"
      folder = File.join(hive_state, "stages", "6-review", slug)

      with_adhoc_review_stubs(head: "first-head", runs: []) do |_materialized|
        capture_io { Hive::CLI.start([ "review", "--pr", "197" ]) }
      end
      first = YAML.safe_load(File.read(File.join(folder, "worktree.yml")))
      assert_equal "first-head", first.fetch("execute_base_head")

      # The PR author pushes new commits; re-running reuses and never re-fetches.
      with_adhoc_review_stubs(head: "second-head", runs: []) do |materialized|
        capture_io { Hive::CLI.start([ "review", "--pr", "197" ]) }
        assert_empty materialized, "reuse must not re-materialize (it pins to the first head)"
      end

      pinned = YAML.safe_load(File.read(File.join(folder, "worktree.yml")))
      assert_equal "first-head", pinned.fetch("execute_base_head"),
                   "reuse stays pinned to the first-run head; new PR commits are not picked up"
    end
  end

  def test_review_pr_runs_a_fork_pr_end_to_end_through_the_review_path
    with_registered_project do |_repo, hive_state, _worktree_root|
      runs = []
      with_adhoc_review_stubs(runs: runs) do |_materialized|
        # Override pr_metadata to report a cross-repository (fork) PR.
        with_replaced_singleton_method(Hive::Gh, :pr_metadata, lambda { |number, **_kwargs|
          Hive::Gh::PrMetadata.new(
            number: number,
            url: "https://github.com/fork/r/pull/#{number}",
            base_ref_name: "main",
            head_ref_oid: "head-197",
            is_cross_repository: true,
            state: "OPEN"
          )
        }) do
          _out, _err, status = with_captured_exit { Hive::CLI.start([ "review", "--pr", "197" ]) }
          assert_equal Hive::ExitCodes::SUCCESS, status
        end
      end

      slug = "adhoc-review-pr-197"
      folder = File.join(hive_state, "stages", "6-review", slug)
      assert_equal [ folder ], runs, "the review stage must run end-to-end for a fork PR"
      pr = Hive::Gh.pr_frontmatter(File.join(folder, "pr.md"))
      assert_equal true, pr.fetch("is_cross_repository"),
                   "the fork flag must persist through enqueue into the review sidecar"
      assert_equal "https://github.com/fork/r/pull/197", pr.fetch("pr_url")
    end
  end

  def test_review_pr_json_emits_destination_collision_envelope
    with_registered_project do |_repo, hive_state, _worktree_root|
      FileUtils.mkdir_p(File.join(hive_state, "stages", "5-open-pr", "owned-task"))
      File.write(
        File.join(hive_state, "stages", "5-open-pr", "owned-task", "pr.md"),
        "#{{ 'pr_number' => 197, 'pr_url' => 'https://github.com/o/r/pull/197' }.to_yaml}---\n\nbody\n"
      )

      out, _err, status = with_captured_exit { Hive::CLI.start([ "review", "--pr", "197", "--json" ]) }

      refute_equal Hive::ExitCodes::SUCCESS, status
      payload = JSON.parse(out)
      assert_equal "hive-stage-action", payload.fetch("schema")
      assert_equal "review", payload.fetch("verb")
      assert_equal false, payload.fetch("ok")
      assert_equal "destination_collision", payload.fetch("error_kind")
    end
  end

  def test_review_pr_json_wraps_unexpected_error_as_internal_error_envelope
    with_registered_project do |_repo, _hive_state, _worktree_root|
      with_replaced_singleton_method(Hive::Gh, :pr_metadata, ->(*_args, **_kwargs) { raise "boom unexpected" }) do
        out, _err, status = with_captured_exit { Hive::CLI.start([ "review", "--pr", "197", "--json" ]) }

        refute_equal Hive::ExitCodes::SUCCESS, status
        payload = JSON.parse(out)
        assert_equal "hive-stage-action", payload.fetch("schema")
        assert_equal "review", payload.fetch("verb")
        assert_equal false, payload.fetch("ok")
        assert_equal "error", payload.fetch("error_kind")
        assert_match(/internal error: RuntimeError: boom unexpected/, payload.fetch("message"))
      end
    end
  end

  def test_review_pr_json_uses_standard_stage_action_envelope
    with_registered_project do |_repo, _hive_state, _worktree_root|
      with_adhoc_review_stubs do |_materialized|
        out, _err, status = with_captured_exit { Hive::CLI.start([ "review", "--pr", "197", "--json" ]) }

        assert_equal Hive::ExitCodes::SUCCESS, status
        payload = JSON.parse(out)
        assert_equal "hive-stage-action", payload.fetch("schema")
        assert_equal "review", payload.fetch("verb")
        assert_equal "ran", payload.fetch("phase")
        assert_equal "adhoc-review-pr-197", payload.fetch("slug")
        assert_equal "review_waiting", payload.fetch("marker_after")
      end
    end
  end

  def test_review_pr_outside_invited_repo_fails_before_creating_state
    with_tmp_global_config do
      with_tmp_git_repo do |repo|
        Dir.chdir(repo) do
          _out, err, status = with_captured_exit { Hive::CLI.start([ "review", "--pr", "197" ]) }

          assert_equal Hive::ExitCodes::CONFIG, status
          assert_match(/hive init/, err)
          refute Dir.exist?(File.join(repo, ".hive-state"))
        end
      end
    end
  end

  def test_review_pr_outside_invited_repo_json_emits_stage_action_error_envelope
    with_tmp_global_config do
      with_tmp_git_repo do |repo|
        Dir.chdir(repo) do
          out, _err, status = with_captured_exit { Hive::CLI.start([ "review", "--pr", "197", "--json" ]) }

          assert_equal Hive::ExitCodes::CONFIG, status
          payload = JSON.parse(out)
          assert_equal "hive-stage-action", payload.fetch("schema")
          assert_equal "review", payload.fetch("verb")
          assert_equal false, payload.fetch("ok")
          assert_equal "error", payload.fetch("error_kind")
          assert_equal Hive::ExitCodes::CONFIG, payload.fetch("exit_code")
        end
      end
    end
  end

  def test_review_pr_invalid_identifier_json_emits_usage_error_envelope
    with_registered_project do |_repo, _hive_state, _worktree_root|
      out, _err, status = with_captured_exit { Hive::CLI.start([ "review", "--pr", "not-a-pr", "--json" ]) }

      assert_equal Hive::ExitCodes::USAGE, status
      payload = JSON.parse(out)
      assert_equal "hive-stage-action", payload.fetch("schema")
      assert_equal "review", payload.fetch("verb")
      assert_equal false, payload.fetch("ok")
      assert_equal "invalid_task_path", payload.fetch("error_kind")
      assert_match(/invalid PR identifier/, payload.fetch("message"))
    end
  end

  def test_review_missing_target_json_emits_usage_error_envelope
    with_registered_project do |_repo, _hive_state, _worktree_root|
      out, _err, status = with_captured_exit { Hive::CLI.start([ "review", "--json" ]) }

      assert_equal Hive::ExitCodes::USAGE, status
      payload = JSON.parse(out)
      assert_equal "hive-stage-action", payload.fetch("schema")
      assert_equal "review", payload.fetch("verb")
      assert_equal false, payload.fetch("ok")
      assert_equal "invalid_task_path", payload.fetch("error_kind")
      assert_match(/missing TARGET/, payload.fetch("message"))
    end
  end
end
