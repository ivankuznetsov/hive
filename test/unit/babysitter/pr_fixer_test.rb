require "test_helper"
require "json"
require "open3"
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

  # Rendering context for prompt-only assertions; no worktree is needed.
  def rendered_prompt_for_head_ref(head_ref)
    context = Hive::Babysitter::ContextBuilder::Context.new(
      status_rollup: {},
      failing_jobs: [],
      diff_stat: "",
      mergeable_state: "CLEAN",
      base_ref: "main",
      head_ref: head_ref
    )
    prompt = nil
    with_replaced_singleton_method(Hive::Babysitter::ContextBuilder, :build, ->(**_kwargs) { context }) do
      fixer = Hive::Babysitter::PrFixer.new(
        pr.merge("headRefName" => head_ref),
        { "name" => "demo", "path" => "/tmp", "hive_state_path" => "/tmp/.hive-state" },
        cfg,
        dry_run: false,
        logger: nil,
        inflight: Set.new
      )
      prompt = fixer.send(:render_prompt, "/tmp/nonexistent-wt", context)
    end
    prompt
  end

  def test_render_prompt_shell_escapes_head_ref_in_executable_positions
    # This exact ref is accepted by `git check-ref-format refs/heads/<ref>`
    # and, once pasted into a shell, runs command substitution before Git.
    hostile_ref = "review$(printf-owned)"
    prompt = rendered_prompt_for_head_ref(hostile_ref)

    escaped = Shellwords.escape(hostile_ref)
    # Every executable position (fetch, rev-parse, push, prose backticks) must
    # use the shell-escaped, fully qualified form so the ref reaches Git as a
    # literal argument that Git also cannot re-parse.
    assert_includes prompt, "git fetch origin #{Shellwords.escape("refs/heads/#{hostile_ref}:refs/remotes/origin/#{hostile_ref}")}"
    assert_includes prompt, "git rev-parse #{Shellwords.escape("refs/remotes/origin/#{hostile_ref}")}"
    assert_includes prompt, "git push --force-with-lease=#{Shellwords.escape("refs/heads/#{hostile_ref}")}:\"$expected_sha\" origin HEAD:#{Shellwords.escape("refs/heads/#{hostile_ref}")}"
    # The raw ref must never appear in an executable shell position; here the
    # unescaped form would run `$(printf owned)` as command substitution.
    refute_includes prompt, "git fetch origin #{escaped}"
    refute_includes prompt, "git fetch origin #{hostile_ref}"
    refute_includes prompt, "git rev-parse origin/#{escaped}"
    refute_includes prompt, "git rev-parse origin/#{hostile_ref}"
    refute_includes prompt, "HEAD:#{escaped}"
    refute_includes prompt, "HEAD:#{hostile_ref}"
    # Display-only lines keep the human-readable name.
    assert_includes prompt, "Head branch: #{hostile_ref}"
  end

  def test_render_prompt_fully_qualifies_git_parsable_head_refs
    # Both names are legal branches (`git check-ref-format` accepts them) but
    # a bare branch argument is re-parsed by Git itself: a leading dash turns
    # `git fetch` into `git fetch origin --upload-pack=<cmd>` (option + local
    # command execution) and a leading `+` turns the argument into a refspec
    # that fetches a different branch. Only fully qualified refs are immune.
    [ "--upload-pack=false", "+topic" ].each do |hostile_ref|
      prompt = rendered_prompt_for_head_ref(hostile_ref)
      # Shellwords escapes `=` as well, so build the expected strings through
      # the same escaping the renderer uses.
      fq_branch = Shellwords.escape("refs/heads/#{hostile_ref}")
      fq_remote = Shellwords.escape("refs/remotes/origin/#{hostile_ref}")
      assert_includes prompt, "git fetch origin #{Shellwords.escape("refs/heads/#{hostile_ref}:refs/remotes/origin/#{hostile_ref}")}",
        "#{hostile_ref} must be fetched fully qualified"
      assert_includes prompt, "git rev-parse #{fq_remote}"
      assert_includes prompt, "git push --force-with-lease=#{fq_branch}:\"$expected_sha\" origin HEAD:#{fq_branch}"
      # The bare form must not survive in any executable position.
      refute_includes prompt, "git fetch origin #{Shellwords.escape(hostile_ref)}"
      refute_includes prompt, "git rev-parse origin/#{Shellwords.escape(hostile_ref)}"
      refute_includes prompt, "HEAD:#{Shellwords.escape(hostile_ref)}"
    end
  end

  def test_push_recipe_executes_safely_against_hostile_head_refs
    skip "git not available" unless system("git", "--version", out: File::NULL)
    hostile_refs = [ "--upload-pack=false", "+topic", "review$(printf-owned)" ]

    with_tmp_dir do |dir|
      origin = File.join(dir, "origin.git")
      run_git!(dir, "init", "--bare", "-q", origin)
      seed = File.join(dir, "seed")
      run_git!(dir, "init", "-q", seed)
      run_git!(seed, "config", "user.email", "test@example.com")
      run_git!(seed, "config", "user.name", "Test")
      run_git!(seed, "commit", "-q", "--allow-empty", "-m", "seed")
      hostile_refs.each { |ref| run_git!(seed, "update-ref", "refs/heads/#{ref}", "HEAD") }
      run_git!(seed, "push", "-q", origin, "refs/heads/*:refs/heads/*")

      hostile_refs.each do |hostile_ref|
        work = File.join(dir, "work-#{rand(1_000_000)}")
        run_git!(dir, "clone", "-q", origin, work)
        prompt = rendered_prompt_for_head_ref(hostile_ref)

        # Execute the trusted recipe from the rendered prompt, verbatim, in a
        # real clone. A leak of the raw ref name shows up as a failed recipe
        # (option/refspec mis-parse) or as command substitution before Git.
        assert system("sh", "-c", recipe_block(prompt), chdir: work),
          "recipe for #{hostile_ref.inspect} must execute without error"

        # The literal, fully qualified branch must exist on the remote at the
        # pushed HEAD — for `+topic` proving the refspec was not rewritten to
        # `topic`, for `--upload-pack=false` proving Git never parsed an
        # `--upload-pack` option out of the branch name.
        pushed = Dir.chdir(work) { `git rev-parse HEAD` }.strip
        # Resolve the remote branch by argv (no shell): this assertion itself
        # must not fall for the same command-substitution trap.
        remote_sha, = Open3.capture2("git", "--git-dir=#{origin}", "rev-parse", "refs/heads/#{hostile_ref}")
        remote_sha = remote_sha.strip
        refute_empty remote_sha
        assert_equal pushed, remote_sha
      end

      hostile_ref = hostile_refs.first
      initial_sha = Dir.chdir(seed) { `git rev-parse HEAD` }.strip
      work = File.join(dir, "race-work")
      run_git!(dir, "clone", "-q", origin, work)
      recipe = recipe_block(rendered_prompt_for_head_ref(hostile_ref))
      first_fetch, after_work = recipe.split("# … work on the PR …\n", 2)
      assert first_fetch
      assert after_work
      assert system("sh", "-c", first_fetch, chdir: work)
      assert_equal initial_sha,
        Dir.chdir(work) { `git rev-parse refs/remotes/origin/#{hostile_ref}` }.strip,
        "the first fetch must populate the tracking ref used by the SHA guard"

      run_git!(seed, "commit", "-q", "--allow-empty", "-m", "remote advance")
      advanced_sha = Dir.chdir(seed) { `git rev-parse HEAD` }.strip
      run_git!(seed, "push", "-q", origin, "HEAD:refs/heads/advance")
      run_git!(origin, "update-ref", "refs/heads/#{hostile_ref}", advanced_sha)

      refute system("sh", "-c", "expected_sha=#{Shellwords.escape(initial_sha)}\n#{after_work}", chdir: work),
        "the second fetch must refresh the tracking ref and abort on a remote move"

      # The rejected recipe fetched the new remote tip. A bare lease would now
      # permit overwriting it; the captured-SHA lease must still reject that.
      push = recipe.lines.find { |line| line.start_with?("git push ") }
      assert push
      refute system("sh", "-c", "expected_sha=#{Shellwords.escape(initial_sha)}\n#{push}", chdir: work),
        "a background fetch must not weaken the captured-SHA lease"
      remote_sha, = Open3.capture2("git", "--git-dir=#{origin}", "rev-parse", "refs/heads/#{hostile_ref}")
      assert_equal advanced_sha, remote_sha.strip
    end
  end

  def run_git!(chdir, *args)
    out, err, status = Open3.capture3("git", *args, chdir: chdir)
    flunk "git #{args.join(' ')} failed in #{chdir}:\n#{out}#{err}" unless status.success?
  end

  def recipe_block(prompt)
    lines = prompt.lines
    opening = lines.index { |line| line.strip == "```sh" }
    assert opening, "prompt must contain an sh recipe block"
    closing = lines[(opening + 1)..].index { |line| line.strip == "```" }
    assert closing, "sh recipe must be terminated"
    lines[(opening + 1)...(opening + 1 + closing)].join
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

  def test_observe_keeps_pending_checks_runnable_when_auto_rebase_can_fix_behind_head
    with_tmp_dir do |dir|
      status = green_behind_status.merge(
        "statusCheckRollup" => [ { "name" => "ci", "status" => "IN_PROGRESS" } ]
      )
      outcome = with_replaced_singleton_method(
        Hive::Gh, :pr_status_rollup, ->(*) { status }
      ) do
        Hive::Babysitter::PrFixer.observe(pr, project_entry(dir), cfg).first
      end

      assert_equal :eligible, outcome
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
