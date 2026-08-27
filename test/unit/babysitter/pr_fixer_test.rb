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
      "headRefName" => "feature-branch",
      "headRefOid" => "prfallbackoid",
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

  def test_closed_admission_skips_pr_status_query
    with_tmp_dir do |dir|
      project = project_entry(dir)
      queried = false
      inflight = Set.new

      with_replaced_singleton_method(Hive::Gh, :pr_status_rollup, lambda { |*_args, **_kwargs|
        queried = true
        {}
      }) do
        outcome = Hive::Babysitter::PrFixer.run(
          pr, project, cfg, dry_run: false, logger: nil, inflight: inflight,
          admission_open: -> { false }
        )
        assert_equal :shutdown, outcome
      end

      refute queried, "a stopped dispatcher must not start a PR status query"
      assert_empty inflight
    end
  end

  def test_raising_admission_predicate_fails_closed
    with_tmp_dir do |dir|
      project = project_entry(dir)
      queried = false

      with_replaced_singleton_method(Hive::Gh, :pr_status_rollup, lambda { |*_args, **_kwargs|
        queried = true
        {}
      }) do
        outcome = Hive::Babysitter::PrFixer.run(
          pr, project, cfg, dry_run: false, logger: nil, inflight: Set.new,
          admission_open: -> { raise IOError, "shutdown state unavailable" }
        )
        assert_equal :shutdown, outcome
      end

      refute queried, "an unavailable shutdown state must not admit PR work"
    end
  end

  def test_already_green_fork_pr_noops_without_needs_human_label
    with_tmp_dir do |dir|
      project = project_entry(dir)
      status = {
        "mergeable" => "MERGEABLE", "mergeStateStatus" => "CLEAN",
        "statusCheckRollup" => [ { "name" => "ci", "conclusion" => "SUCCESS" } ]
      }
      labels = []

      with_replaced_singleton_method(Hive::Gh, :pr_status_rollup, ->(*_args, **_kwargs) { status }) do
        with_replaced_singleton_method(Hive::Babysitter::GhOps, :add_label, ->(*args, **_kwargs) { labels << args }) do
          outcome = Hive::Babysitter::PrFixer.run(
            pr.merge("isCrossRepository" => true), project, cfg,
            dry_run: false, logger: nil, inflight: Set.new
          )
          assert_equal :already_green, outcome
        end
      end

      assert_empty labels
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

  def test_shutdown_during_context_build_prevents_agent_spawn
    with_tmp_dir do |dir|
      project = project_entry(dir)
      worktree_path = File.join(dir, "wt")
      FileUtils.mkdir_p(worktree_path)
      admission_open = true
      spawned = false
      inflight = Set.new

      stub_non_green_context(project, worktree_path, before_return: -> { admission_open = false }) do
        with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, lambda { |*_args, **_kwargs|
          spawned = true
          { status: :ok }
        }) do
          outcome = Hive::Babysitter::PrFixer.run(
            pr, project, cfg, dry_run: false, logger: nil, inflight: inflight,
            admission_open: -> { admission_open }
          )
          assert_equal :shutdown, outcome
        end
      end

      refute spawned, "shutdown must be rechecked immediately before the agent launch"
      assert_empty inflight
    end
  end

  def test_shutdown_while_preparing_agent_prevents_provider_launch
    with_tmp_dir do |dir|
      project = project_entry(dir)
      worktree_path = File.join(dir, "wt")
      FileUtils.mkdir_p(worktree_path)
      admission_open = true
      spawned = false
      original_lookup = Hive::AgentProfiles.method(:lookup)

      stub_non_green_context(project, worktree_path) do
        with_replaced_singleton_method(Hive::AgentProfiles, :lookup, lambda { |*args, **kwargs|
          profile = original_lookup.call(*args, **kwargs)
          admission_open = false
          profile
        }) do
          with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, lambda { |*_args, **_kwargs|
            spawned = true
            { status: :ok }
          }) do
            outcome = Hive::Babysitter::PrFixer.run(
              pr, project, cfg, dry_run: false, logger: nil, inflight: Set.new,
              admission_open: -> { admission_open }
            )
            assert_equal :shutdown, outcome
          end
        end
      end

      refute spawned, "shutdown during launch preparation must suppress the provider process"
    end
  end

  def test_agent_spawn_receives_babysitter_route
    with_tmp_dir do |dir|
      project = project_entry(dir)
      worktree_path = File.join(dir, "wt")
      FileUtils.mkdir_p(worktree_path)
      routed_cfg = cfg.merge(
        "execute" => { "agent" => "codex" },
        "models" => {
          "babysitter" => { "model" => "gpt-5.6-sol", "effort" => "xhigh" }
        }
      )
      captured = nil

      stub_non_green_context(project, worktree_path) do
        with_replaced_singleton_method(
          Hive::Stages::Base,
          :spawn_agent,
          lambda { |_task, **kwargs| captured = kwargs; { status: :ok } }
        ) do
          outcome = Hive::Babysitter::PrFixer.run(
            pr, project, routed_cfg, dry_run: false, logger: nil, inflight: Set.new
          )
          assert_equal :success, outcome
        end
      end

      assert_equal :codex, captured.fetch(:profile).name
      assert_equal [
        "--model", "gpt-5.6-sol", "-c", "model_reasoning_effort=xhigh"
      ], captured.fetch(:routing_arguments).global_arguments
      assert_equal false, captured.fetch(:terminate_on_parent_signal)
    end
  end

  def test_agent_spawn_honors_babysitter_provider_override
    with_tmp_dir do |dir|
      project = project_entry(dir)
      worktree_path = File.join(dir, "wt")
      FileUtils.mkdir_p(worktree_path)
      routed_cfg = cfg.merge(
        "execute" => { "agent" => "codex" },
        "babysitter" => cfg.fetch("babysitter").merge("agent" => "claude"),
        "models" => {
          "babysitter" => { "model" => "claude-opus-5", "effort" => "max" }
        }
      )
      captured = nil

      stub_non_green_context(project, worktree_path) do
        with_replaced_singleton_method(
          Hive::Stages::Base,
          :spawn_agent,
          lambda { |_task, **kwargs| captured = kwargs; { status: :ok } }
        ) do
          outcome = Hive::Babysitter::PrFixer.run(
            pr, project, routed_cfg, dry_run: false, logger: nil, inflight: Set.new
          )
          assert_equal :success, outcome
        end
      end

      assert_equal :claude, captured.fetch(:profile).name
      assert_equal [ "--model", "claude-opus-5", "--effort", "max" ],
                   captured.fetch(:routing_arguments).subcommand_arguments
    end
  end

  def test_agent_failure_comments_and_gives_up_when_label_fails
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
            Hive::Gh::PushResult.new(success: false, stdout: "", stderr: "label unavailable")
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
      assert events.any? do |event|
        event["action"] == "label-apply" && event["outcome"] == "failure" &&
          event["message"] == "label unavailable"
      end
      assert events.any? { |event| event["action"] == "pr-comment" && event["outcome"] == "success" }
      assert events.any? { |event| event["action"] == "give-up" && event["outcome"] == "failure" }
    end
  end

  def test_dry_run_wraps_agent_path_and_reports_dry_run
    with_tmp_dir do |dir|
      project = project_entry(dir)
      worktree_path = File.join(dir, "wt")
      FileUtils.mkdir_p(worktree_path)
      seen_path = nil
      seen_prompt = nil

      stub_non_green_context(project, worktree_path) do
        with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, lambda { |_task, **kwargs|
          seen_path = ENV["PATH"]
          seen_prompt = kwargs.fetch(:prompt)
          File.write(File.join(worktree_path, ".babysitter-dry-run-plan.md"), "would fix\n")
          { status: :ok }
        }) do
          outcome = Hive::Babysitter::PrFixer.run(pr, project, cfg, dry_run: true, logger: nil, inflight: Set.new)
          assert_equal :dry_run, outcome
        end
      end

      assert_includes seen_path, ".hive-babysitter-dry-run-bin"
      assert_includes seen_prompt, "gh pr checks/diff/list/status/view"
      assert_includes seen_prompt, File.join(worktree_path, ".babysitter-dry-run-skipped.log")
      assert_includes seen_prompt, "[dry-run] ... skipped"
      assert_includes seen_prompt, "[dry-run] failed to write skip log ..."
      assert_includes seen_prompt, "continues without a persistent record"
      assert_includes seen_prompt, "synthetic success (exit status 0)"
      assert File.exist?(File.join(worktree_path, ".babysitter-dry-run-plan.md"))
    end
  end

  def green_behind_status
    {
      "mergeable" => "MERGEABLE",
      "mergeStateStatus" => "BEHIND",
      "headRefOid" => "rollupoid",
      "statusCheckRollup" => [ { "name" => "ci", "conclusion" => "SUCCESS" } ]
    }
  end

  def test_green_but_behind_rebases_force_pushes_to_head_ref_and_reports_rebased
    with_tmp_dir do |dir|
      project = project_entry(dir)
      worktree_path = File.join(dir, "wt")
      FileUtils.mkdir_p(worktree_path)
      pushed = []
      pushed_kwargs = []
      spawned = false

      status = green_behind_status
      with_replaced_singleton_method(Hive::Gh, :pr_status_rollup, ->(_p, _n, **_k) { status }) do
        with_replaced_singleton_method(Hive::Babysitter::Worktree, :materialize, ->(_pr, _proj) { WorktreeResult.new(path: worktree_path, branch: "hive-babysitter/pr-42") }) do
          with_replaced_singleton_method(Hive::Babysitter::GhOps, :rebase_onto_base, ->(*_a, **_k) { Hive::Babysitter::GhOps::RebaseResult.new(status: :success, stdout: "", stderr: "") }) do
            with_replaced_singleton_method(Hive::Babysitter::GhOps, :force_push_with_lease, lambda { |*args, **kwargs|
              pushed << args
              pushed_kwargs << kwargs
              Hive::Gh::PushResult.new(success: true, stdout: "", stderr: "")
            }) do
              with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, ->(*_a, **_k) { spawned = true }) do
                outcome = Hive::Babysitter::PrFixer.run(pr, project, cfg, dry_run: false, logger: nil, inflight: Set.new)
                assert_equal :rebased, outcome
              end
            end
          end
        end
      end

      refute spawned, "rebase path must not spawn the fix agent"
      assert_equal 1, pushed.size
      assert_equal [ worktree_path, "feature-branch" ], pushed.first,
        "must push to the PR head branch, not the internal hive-babysitter/pr-<n> branch"
      assert_equal "rollupoid", pushed_kwargs.first.fetch(:expected_oid),
        "expected_oid must come from the rollup's headRefOid"
      events = read_events(project)
      assert events.any? { |e| e["action"] == "rebase" && e["outcome"] == "success" }
    end
  end

  def test_green_but_behind_falls_back_to_pr_head_oid_when_rollup_lacks_it
    with_tmp_dir do |dir|
      project = project_entry(dir)
      worktree_path = File.join(dir, "wt")
      FileUtils.mkdir_p(worktree_path)
      pushed_kwargs = []

      # Rollup omits headRefOid -> expected_oid falls back to @pr["headRefOid"].
      status = { "mergeable" => "MERGEABLE", "mergeStateStatus" => "BEHIND", "statusCheckRollup" => [ { "conclusion" => "SUCCESS" } ] }
      with_replaced_singleton_method(Hive::Gh, :pr_status_rollup, ->(_p, _n, **_k) { status }) do
        with_replaced_singleton_method(Hive::Babysitter::Worktree, :materialize, ->(_pr, _proj) { WorktreeResult.new(path: worktree_path, branch: "hive-babysitter/pr-42") }) do
          with_replaced_singleton_method(Hive::Babysitter::GhOps, :rebase_onto_base, ->(*_a, **_k) { Hive::Babysitter::GhOps::RebaseResult.new(status: :success, stdout: "", stderr: "") }) do
            with_replaced_singleton_method(Hive::Babysitter::GhOps, :force_push_with_lease, lambda { |*_args, **kwargs|
              pushed_kwargs << kwargs
              Hive::Gh::PushResult.new(success: true, stdout: "", stderr: "")
            }) do
              outcome = Hive::Babysitter::PrFixer.run(pr, project, cfg, dry_run: false, logger: nil, inflight: Set.new)
              assert_equal :rebased, outcome
            end
          end
        end
      end

      assert_equal "prfallbackoid", pushed_kwargs.first.fetch(:expected_oid),
        "expected_oid must fall back to @pr['headRefOid'] when the rollup omits it"
    end
  end

  def test_green_but_behind_passes_nil_expected_oid_when_neither_source_has_it
    with_tmp_dir do |dir|
      project = project_entry(dir)
      worktree_path = File.join(dir, "wt")
      FileUtils.mkdir_p(worktree_path)
      pushed_kwargs = []

      # Neither rollup nor @pr carries headRefOid -> nil (bare-lease fallback).
      status = { "mergeable" => "MERGEABLE", "mergeStateStatus" => "BEHIND", "statusCheckRollup" => [ { "conclusion" => "SUCCESS" } ] }
      pr_without_oid = pr.reject { |k, _| k == "headRefOid" }
      with_replaced_singleton_method(Hive::Gh, :pr_status_rollup, ->(_p, _n, **_k) { status }) do
        with_replaced_singleton_method(Hive::Babysitter::Worktree, :materialize, ->(_pr, _proj) { WorktreeResult.new(path: worktree_path, branch: "hive-babysitter/pr-42") }) do
          with_replaced_singleton_method(Hive::Babysitter::GhOps, :rebase_onto_base, ->(*_a, **_k) { Hive::Babysitter::GhOps::RebaseResult.new(status: :success, stdout: "", stderr: "") }) do
            with_replaced_singleton_method(Hive::Babysitter::GhOps, :force_push_with_lease, lambda { |*_args, **kwargs|
              pushed_kwargs << kwargs
              Hive::Gh::PushResult.new(success: true, stdout: "", stderr: "")
            }) do
              outcome = Hive::Babysitter::PrFixer.run(pr_without_oid, project, cfg, dry_run: false, logger: nil, inflight: Set.new)
              assert_equal :rebased, outcome
            end
          end
        end
      end

      assert_nil pushed_kwargs.first.fetch(:expected_oid),
        "expected_oid must be nil when no headRefOid is available"
    end
  end

  def test_green_but_behind_rebase_conflict_reports_conflict_without_push
    with_tmp_dir do |dir|
      project = project_entry(dir)
      worktree_path = File.join(dir, "wt")
      FileUtils.mkdir_p(worktree_path)
      pushed = false
      spawned = false

      # Rollup omits mergeStateStatus; behind? falls back to the PR object
      # (the listing carries it). Exercises the @pr fallback branch.
      status = { "mergeable" => "MERGEABLE", "statusCheckRollup" => [ { "conclusion" => "SUCCESS" } ] }
      behind_pr = pr.merge("mergeStateStatus" => "BEHIND")
      with_replaced_singleton_method(Hive::Gh, :pr_status_rollup, ->(_p, _n, **_k) { status }) do
        with_replaced_singleton_method(Hive::Babysitter::Worktree, :materialize, ->(_pr, _proj) { WorktreeResult.new(path: worktree_path, branch: "feature") }) do
          with_replaced_singleton_method(Hive::Babysitter::GhOps, :rebase_onto_base, ->(*_a, **_k) { Hive::Babysitter::GhOps::RebaseResult.new(status: :conflict, stdout: "", stderr: "") }) do
            with_replaced_singleton_method(Hive::Babysitter::GhOps, :force_push_with_lease, ->(*_a, **_k) { pushed = true }) do
              with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, ->(*_a, **_k) { spawned = true }) do
                outcome = Hive::Babysitter::PrFixer.run(behind_pr, project, cfg, dry_run: false, logger: nil, inflight: Set.new)
                assert_equal :rebase_conflict, outcome
              end
            end
          end
        end
      end

      refute pushed, "a conflicting rebase must not force-push"
      refute spawned, "a conflicting rebase must not spawn the fix agent"
      events = read_events(project)
      assert events.any? { |e| e["action"] == "rebase" && e["outcome"] == "conflict" }
    end
  end

  def test_shutdown_during_auto_rebase_materialization_prevents_rebase
    with_tmp_dir do |dir|
      project = project_entry(dir)
      admission_open = true
      rebased = false
      pushed = false
      status = green_behind_status
      rebase = Hive::Babysitter::GhOps::RebaseResult.new(status: :success, stdout: "", stderr: "")
      push = Hive::Gh::PushResult.new(success: true, stdout: "", stderr: "")

      with_replaced_singleton_method(Hive::Gh, :pr_status_rollup, ->(*_args, **_kwargs) { status }) do
        with_replaced_singleton_method(Hive::Babysitter::Worktree, :materialize, lambda { |*_args|
          admission_open = false
          WorktreeResult.new(path: File.join(dir, "wt"), branch: "feature")
        }) do
          with_replaced_singleton_method(Hive::Babysitter::GhOps, :rebase_onto_base, lambda { |*_args, **_kwargs|
            rebased = true
            rebase
          }) do
            with_replaced_singleton_method(Hive::Babysitter::GhOps, :force_push_with_lease, lambda { |*_args, **_kwargs|
              pushed = true
              push
            }) do
              outcome = Hive::Babysitter::PrFixer.run(
                pr, project, cfg, dry_run: false, logger: nil, inflight: Set.new,
                admission_open: -> { admission_open }
              )
              assert_equal :shutdown, outcome
            end
          end
        end
      end

      refute rebased
      refute pushed
    end
  end

  def test_shutdown_during_auto_rebase_prevents_force_push
    with_tmp_dir do |dir|
      project = project_entry(dir)
      worktree = WorktreeResult.new(path: File.join(dir, "wt"), branch: "feature")
      admission_open = true
      pushed = false
      status = green_behind_status
      rebase = Hive::Babysitter::GhOps::RebaseResult.new(status: :success, stdout: "", stderr: "")
      push = Hive::Gh::PushResult.new(success: true, stdout: "", stderr: "")

      with_replaced_singleton_method(Hive::Gh, :pr_status_rollup, ->(*_args, **_kwargs) { status }) do
        with_replaced_singleton_method(Hive::Babysitter::Worktree, :materialize, ->(*_args) { worktree }) do
          with_replaced_singleton_method(Hive::Babysitter::GhOps, :rebase_onto_base, lambda { |*_args, **_kwargs|
            admission_open = false
            rebase
          }) do
            with_replaced_singleton_method(Hive::Babysitter::GhOps, :force_push_with_lease, lambda { |*_args, **_kwargs|
              pushed = true
              push
            }) do
              outcome = Hive::Babysitter::PrFixer.run(
                pr, project, cfg, dry_run: false, logger: nil, inflight: Set.new,
                admission_open: -> { admission_open }
              )
              assert_equal :shutdown, outcome
            end
          end
        end
      end

      refute pushed
      events = read_events(project)
      assert events.any? { |event| event["action"] == "rebase" && event["outcome"] == "shutdown" }
    end
  end

  def test_green_but_behind_reports_failure_when_force_push_fails
    with_tmp_dir do |dir|
      project = project_entry(dir)
      worktree_path = File.join(dir, "wt")
      FileUtils.mkdir_p(worktree_path)

      status = green_behind_status
      with_replaced_singleton_method(Hive::Gh, :pr_status_rollup, ->(_p, _n, **_k) { status }) do
        with_replaced_singleton_method(Hive::Babysitter::Worktree, :materialize, ->(_pr, _proj) { WorktreeResult.new(path: worktree_path, branch: "feature") }) do
          with_replaced_singleton_method(Hive::Babysitter::GhOps, :rebase_onto_base, ->(*_a, **_k) { Hive::Babysitter::GhOps::RebaseResult.new(status: :success, stdout: "", stderr: "") }) do
            with_replaced_singleton_method(Hive::Babysitter::GhOps, :force_push_with_lease, ->(*_a, **_k) { Hive::Gh::PushResult.new(success: false, stdout: "", stderr: "rejected") }) do
              outcome = Hive::Babysitter::PrFixer.run(pr, project, cfg, dry_run: false, logger: nil, inflight: Set.new)
              assert_equal :failure, outcome
            end
          end
        end
      end

      events = read_events(project)
      assert events.any? { |e| e["action"] == "rebase" && e["outcome"] == "failure" }
    end
  end

  def test_green_but_behind_reports_failure_when_rebase_errors
    with_tmp_dir do |dir|
      project = project_entry(dir)
      worktree_path = File.join(dir, "wt")
      FileUtils.mkdir_p(worktree_path)
      pushed = false

      status = green_behind_status
      with_replaced_singleton_method(Hive::Gh, :pr_status_rollup, ->(_p, _n, **_k) { status }) do
        with_replaced_singleton_method(Hive::Babysitter::Worktree, :materialize, ->(_pr, _proj) { WorktreeResult.new(path: worktree_path, branch: "feature") }) do
          with_replaced_singleton_method(Hive::Babysitter::GhOps, :rebase_onto_base, ->(*_a, **_k) { Hive::Babysitter::GhOps::RebaseResult.new(status: :failure, stdout: "", stderr: "fetch boom") }) do
            with_replaced_singleton_method(Hive::Babysitter::GhOps, :force_push_with_lease, ->(*_a, **_k) { pushed = true }) do
              outcome = Hive::Babysitter::PrFixer.run(pr, project, cfg, dry_run: false, logger: nil, inflight: Set.new)
              assert_equal :failure, outcome
            end
          end
        end
      end

      refute pushed, "a failed rebase must not force-push"
      events = read_events(project)
      assert events.any? { |e| e["action"] == "rebase" && e["outcome"] == "failure" }
    end
  end

  def test_green_but_behind_with_auto_rebase_disabled_noops
    with_tmp_dir do |dir|
      project = project_entry(dir)
      materialized = false
      disabled_cfg = cfg.merge("babysitter" => cfg.fetch("babysitter").merge("auto_rebase" => false))

      status = green_behind_status
      with_replaced_singleton_method(Hive::Gh, :pr_status_rollup, ->(_p, _n, **_k) { status }) do
        with_replaced_singleton_method(Hive::Babysitter::Worktree, :materialize, ->(*_a) { materialized = true }) do
          outcome = Hive::Babysitter::PrFixer.run(pr, project, disabled_cfg, dry_run: false, logger: nil, inflight: Set.new)
          assert_equal :already_green, outcome
        end
      end

      refute materialized, "auto_rebase: false must not materialize a worktree"
      event = JSON.parse(File.read(File.join(project.fetch("hive_state_path"), "babysitter", "events.jsonl")))
      assert_equal "noop", event.fetch("action")
      assert_equal "already-green", event.fetch("outcome")
    end
  end

  def test_green_and_not_behind_noops_without_rebase
    with_tmp_dir do |dir|
      project = project_entry(dir)
      materialized = false
      status = {
        "mergeable" => "MERGEABLE",
        "mergeStateStatus" => "CLEAN",
        "statusCheckRollup" => [ { "name" => "ci", "conclusion" => "SUCCESS" } ]
      }

      with_replaced_singleton_method(Hive::Gh, :pr_status_rollup, ->(_p, _n, **_k) { status }) do
        with_replaced_singleton_method(Hive::Babysitter::Worktree, :materialize, ->(*_a) { materialized = true }) do
          outcome = Hive::Babysitter::PrFixer.run(pr, project, cfg, dry_run: false, logger: nil, inflight: Set.new)
          assert_equal :already_green, outcome
        end
      end

      refute materialized
    end
  end

  def test_dry_run_green_but_behind_emits_rebase_dry_run_without_git
    with_tmp_dir do |dir|
      project = project_entry(dir)
      materialized = false

      status = green_behind_status
      with_replaced_singleton_method(Hive::Gh, :pr_status_rollup, ->(_p, _n, **_k) { status }) do
        with_replaced_singleton_method(Hive::Babysitter::Worktree, :materialize, ->(*_a) { materialized = true }) do
          outcome = Hive::Babysitter::PrFixer.run(pr, project, cfg, dry_run: true, logger: nil, inflight: Set.new)
          assert_equal :dry_run, outcome
        end
      end

      refute materialized, "dry-run must not touch git"
      event = JSON.parse(File.read(File.join(project.fetch("hive_state_path"), "babysitter", "events.jsonl")))
      assert_equal "rebase", event.fetch("action")
      assert_equal "dry_run", event.fetch("outcome")
    end
  end

  def read_events(project)
    File.readlines(File.join(project.fetch("hive_state_path"), "babysitter", "events.jsonl")).map { |line| JSON.parse(line) }
  end

  def stub_non_green_context(project, worktree_path, before_return: nil)
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
        with_replaced_singleton_method(Hive::Babysitter::ContextBuilder, :build, lambda { |**_kwargs|
          before_return&.call
          context
        }) do
          yield
        end
      end
    end
  end
end
