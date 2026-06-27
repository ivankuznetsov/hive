require "test_helper"
require "json"
require "hive/cli"
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
          yield materialized
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
