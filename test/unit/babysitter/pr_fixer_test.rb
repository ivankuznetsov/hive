require "test_helper"
require "json"
require "set"
require "hive/babysitter/pr_fixer"

class BabysitterPrFixerTest < Minitest::Test
  include HiveTestHelper

  WorktreeResult = Struct.new(:path, :branch, keyword_init: true)

  def project_entry(dir)
    { "name" => "demo", "path" => dir, "hive_state_path" => File.join(dir, ".hive-state") }
  end

  def cfg
    {
      "execute" => { "agent" => "claude" },
      "agents" => {},
      "babysitter" => {
        "budget_minutes" => 30,
        "budget_usd" => 50
      }
    }
  end

  def pr
    {
      "number" => 42,
      "url" => "https://example.com/pr/42",
      "headRefName" => "feature",
      "baseRefName" => "main"
    }
  end

  def test_already_green_pr_noops_without_agent_spawn
    with_tmp_dir do |dir|
      project = project_entry(dir)
      status = {
        "mergeable" => "MERGEABLE",
        "statusCheckRollup" => [ { "name" => "ci", "conclusion" => "SUCCESS" } ]
      }
      spawned = false

      with_replaced_singleton_method(Hive::Gh, :pr_status_rollup, ->(_path, _number, **_kwargs) { status }) do
        with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, ->(*_args, **_kwargs) { spawned = true }) do
          outcome = Hive::Babysitter::PrFixer.run(pr, project, cfg, dry_run: false, logger: nil, inflight: Set.new)
          assert_equal :already_green, outcome
        end
      end

      refute spawned
      event = JSON.parse(File.read(File.join(project.fetch("hive_state_path"), "babysitter", "events.jsonl")))
      assert_equal "noop", event.fetch("action")
      assert_equal "already-green", event.fetch("outcome")
    end
  end

  def test_agent_success_emits_success_and_clears_inflight
    with_tmp_dir do |dir|
      project = project_entry(dir)
      worktree_path = File.join(dir, "wt")
      FileUtils.mkdir_p(worktree_path)
      inflight = Set.new

      stub_non_green_context(project, worktree_path) do
        with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, ->(*_args, **_kwargs) { { status: :ok } }) do
          outcome = Hive::Babysitter::PrFixer.run(pr, project, cfg, dry_run: false, logger: nil, inflight: inflight)
          assert_equal :success, outcome
        end
      end

      assert_empty inflight
      events = File.readlines(File.join(project.fetch("hive_state_path"), "babysitter", "events.jsonl")).map { |line| JSON.parse(line) }
      assert events.any? { |event| event["action"] == "agent-fix" && event["outcome"] == "success" }
    end
  end

  def test_agent_failure_labels_comments_and_gives_up
    with_tmp_dir do |dir|
      project = project_entry(dir)
      worktree_path = File.join(dir, "wt")
      FileUtils.mkdir_p(worktree_path)
      label_calls = []
      comment_calls = []

      stub_non_green_context(project, worktree_path) do
        with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, ->(*_args, **_kwargs) { { status: :error, final_message: "tests failed" } }) do
          with_replaced_singleton_method(Hive::Babysitter::GhOps, :add_label, lambda { |*args, **_kwargs|
            label_calls << args
            Hive::Gh::PushResult.new(success: true, stdout: "", stderr: "")
          }) do
            with_replaced_singleton_method(Hive::Babysitter::GhOps, :post_pr_comment, lambda { |*args, **_kwargs|
              comment_calls << args
              Hive::Gh::PushResult.new(success: true, stdout: "", stderr: "")
            }) do
              outcome = Hive::Babysitter::PrFixer.run(pr, project, cfg, dry_run: false, logger: nil, inflight: Set.new)
              assert_equal :failure, outcome
            end
          end
        end
      end

      assert_equal 1, label_calls.size
      assert_equal 1, comment_calls.size
      assert_includes comment_calls.first[2], "tests failed"
      events = File.readlines(File.join(project.fetch("hive_state_path"), "babysitter", "events.jsonl")).map { |line| JSON.parse(line) }
      assert events.any? { |event| event["action"] == "give-up" && event["outcome"] == "failure" }
    end
  end

  def test_dry_run_wraps_agent_path_and_reports_dry_run
    with_tmp_dir do |dir|
      project = project_entry(dir)
      worktree_path = File.join(dir, "wt")
      FileUtils.mkdir_p(worktree_path)
      seen_path = nil

      stub_non_green_context(project, worktree_path) do
        with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, lambda { |_task, **_kwargs|
          seen_path = ENV["PATH"]
          File.write(File.join(worktree_path, ".babysitter-dry-run-plan.md"), "would fix\n")
          { status: :ok }
        }) do
          outcome = Hive::Babysitter::PrFixer.run(pr, project, cfg, dry_run: true, logger: nil, inflight: Set.new)
          assert_equal :dry_run, outcome
        end
      end

      assert_includes seen_path, ".hive-babysitter-dry-run-bin"
      assert File.exist?(File.join(worktree_path, ".babysitter-dry-run-plan.md"))
    end
  end

  def stub_non_green_context(project, worktree_path)
    status = { "mergeable" => "CONFLICTING", "statusCheckRollup" => [ { "conclusion" => "FAILURE" } ] }
    context = Hive::Babysitter::ContextBuilder::Context.new(
      status_rollup: status,
      failing_jobs: [],
      diff_stat: "README.md | 1 +",
      mergeable_state: "CONFLICTING",
      base_ref: "main",
      head_ref: "feature"
    )

    with_replaced_singleton_method(Hive::Gh, :pr_status_rollup, ->(_path, _number, **_kwargs) { status }) do
      with_replaced_singleton_method(Hive::Babysitter::Worktree, :materialize, ->(_project, _pr) { WorktreeResult.new(path: worktree_path, branch: "feature") }) do
        with_replaced_singleton_method(Hive::Babysitter::ContextBuilder, :build, ->(**_kwargs) { context }) do
          yield
        end
      end
    end
  end
end
