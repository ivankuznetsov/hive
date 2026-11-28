require "test_helper"
require "json"
require "open3"
require "hive/cli"
require "hive/attempts/context"
require "hive/attempts/dispatcher"
require "hive/commands/adhoc_review"
require "hive/commands/stage_action"
require "hive/daemon/dispatcher"
require "hive/gh"
require "hive/internal_pr_checkout"
require "hive/markers"
require "hive/review_budget"
require "hive/runtime_control_plane"
require "hive/stages/review"
require "hive/worktree"

class AdhocReviewIntegrationTest < Minitest::Test
  include HiveTestHelper

  def metadata(number:, head:, url: nil, fork: false, head_ref_name: "feat/demo",
               head_repository: nil, state: "OPEN")
    Hive::Gh::PrMetadata.new(
      number: number,
      url: url || "https://github.com/o/r/pull/#{number}",
      base_ref_name: "main",
      head_ref_name: head_ref_name,
      head_ref_oid: head,
      head_repository: head_repository || (fork ? "fork/r" : "o/r"),
      is_cross_repository: fork,
      state: state,
      is_draft: false,
      host: "github.com",
      repository: "o/r"
    )
  end

  def git(dir, *args)
    out, err, status = Open3.capture3("git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{err}\n#{out}" unless status.success?

    out
  end

  # Real bare remote + registered repo + commits A, B (force-pushed), and C.
  def with_registered_pr_project(pr_number: 197)
    with_tmp_global_config do |home|
      Hive::RuntimeControlPlane.disconnect
      Hive::Lock.task_lease_repository = nil
      with_tmp_dir do |root|
        remote = File.join(root, "remote.git")
        repo = File.join(root, "repo")
        worktree_root = File.join(root, "adhoc-worktrees")
        FileUtils.mkdir_p(worktree_root)

        git(root, "init", "--bare", remote)
        git(root, "clone", remote, repo)
        git(repo, "config", "user.name", "Test")
        git(repo, "config", "user.email", "test@example.com")
        git(repo, "config", "commit.gpgsign", "false")

        File.write(File.join(repo, ".gitignore"), "build/\nobstructed.txt\n")
        File.write(File.join(repo, "app.rb"), "puts 'base'\n")
        git(repo, "add", ".")
        git(repo, "commit", "-m", "initial main")
        git(repo, "branch", "-M", "main")
        git(repo, "push", "-u", "origin", "main")

        # Commit A (PR head v1)
        git(repo, "checkout", "-b", "pr-head-a")
        File.write(File.join(repo, "app.rb"), "puts 'head-A'\n")
        File.write(File.join(repo, "only_a.txt"), "from-a\n")
        git(repo, "add", ".")
        git(repo, "commit", "-m", "PR commit A")
        oid_a = git(repo, "rev-parse", "HEAD").strip
        git(repo, "push", "origin", "#{oid_a}:refs/pull/#{pr_number}/head")

        # Commit B (force-pushed unrelated PR head v2, tracks obstructed.txt)
        git(repo, "checkout", "--orphan", "pr-head-b")
        git(repo, "rm", "-rf", ".")
        File.write(File.join(repo, ".gitignore"), "build/\nobstructed.txt\n")
        File.write(File.join(repo, "app.rb"), "puts 'head-B'\n")
        File.write(File.join(repo, "only_b.txt"), "from-b\n")
        File.write(File.join(repo, "obstructed.txt"), "tracked-in-b\n")
        git(repo, "add", "-f", ".gitignore", "app.rb", "only_b.txt", "obstructed.txt")
        git(repo, "commit", "-m", "PR commit B")
        oid_b = git(repo, "rev-parse", "HEAD").strip

        # Commit C (force-pushed PR head v3)
        git(repo, "checkout", "--orphan", "pr-head-c")
        git(repo, "rm", "-rf", ".")
        File.write(File.join(repo, ".gitignore"), "build/\nobstructed.txt\n")
        File.write(File.join(repo, "app.rb"), "puts 'head-C'\n")
        File.write(File.join(repo, "only_c.txt"), "from-c\n")
        git(repo, "add", "-f", ".gitignore", "app.rb", "only_c.txt")
        git(repo, "commit", "-m", "PR commit C")
        oid_c = git(repo, "rev-parse", "HEAD").strip

        git(repo, "checkout", "main")
        git(repo, "branch", "-D", "pr-head-a", "pr-head-b", "pr-head-c")

        hive_state = File.join(repo, ".hive-state")
        FileUtils.mkdir_p(File.join(hive_state, "stages", "6-review"))
        File.write(
          File.join(hive_state, "config.yml"),
          {
            "worktree_root" => worktree_root,
            "rebase" => { "enabled" => false }
          }.to_yaml
        )
        Hive::Config.register_project(name: "demo", path: repo)
        database = prepare_runtime_project(
          state_home: home, name: "demo", path: repo, state_root_path: hive_state
        )

        orig_load = Hive::Config.method(:load)
        with_replaced_singleton_method(Hive::Config, :load, lambda { |*args, **kwargs|
          orig_load.call(*args, **kwargs).merge("agent_git_gate" => { "allow_local_transport" => true })
        }) do
          Dir.chdir(repo) do
            yield({
              home: home,
              remote: remote,
              repo: repo,
              hive_state: hive_state,
              worktree_root: worktree_root,
              oid_a: oid_a,
              oid_b: oid_b,
              oid_c: oid_c,
              database: database
            })
          end
        end
      ensure
        database&.disconnect
        Hive::RuntimeControlPlane.disconnect
        Hive::Lock.task_lease_repository = nil
      end
    end
  end

  def push_pr_head(env, oid, pr_number: 197)
    git(env[:repo], "push", "-f", "origin", "#{oid}:refs/pull/#{pr_number}/head")
  end

  def with_pr_stubs(head:, runs: [], fork: false, url: nil, state: "OPEN",
                    on_review: nil, on_metadata: nil)
    test_case = self
    orig_stage_new = Hive::Commands::StageAction.method(:new)
    with_replaced_singleton_method(Hive::Commands::StageAction, :new, lambda { |*args, **kwargs|
      orig_stage_new.call(*args, **kwargs.merge(durable: false))
    }) do
      with_replaced_singleton_method(Hive::Gh, :validated_pr_metadata, lambda { |number, **_kwargs|
        if on_metadata
          on_metadata.call(number)
        else
          test_case.metadata(number: number, head: head, fork: fork, url: url, state: state)
        end
      }) do
        with_replaced_singleton_method(Hive::Stages::Review, :run!, lambda { |task, cfg|
          runs << { folder: task.folder, head: test_case.git(task.worktree_path, "rev-parse", "HEAD").strip }
          if on_review
            on_review.call(task, cfg)
          else
            Hive::Markers.set(task.state_file, :review_waiting,
                              reason: "adhoc_fix_disabled",
                              accepted: 1,
                              pass: 1)
            { commit: nil, status: :review_waiting }
          end
        }) do
          yield
        end
      end
    end
  end

  # Full tree snapshot of every path, entry type, and raw file bytes under root.
  def snapshot_tree(root)
    result = {}
    walk = lambda do |dir|
      Dir.children(dir).sort.each do |name|
        full = File.join(dir, name)
        rel = full.delete_prefix("#{root}/")
        stat = File.lstat(full)
        if stat.symlink?
          result[rel] = [ :symlink, File.readlink(full) ]
        elsif stat.directory?
          result[rel] = [ :dir, nil ]
          walk.call(full)
        else
          result[rel] = [ :file, File.binread(full) ]
        end
      end
    end
    walk.call(root)
    result
  end

  def snapshot_git(repo, worktree)
    {
      head: git(worktree, "rev-parse", "HEAD").strip,
      branch: git(worktree, "branch", "--show-current").strip,
      index: git(worktree, "ls-files", "-s"),
      refs: git(repo, "show-ref")
    }
  end

  def run_initial_create(env, pr_number: 197, runs: [], fork: false, url: nil)
    with_pr_stubs(head: env[:oid_a], runs: runs, fork: fork, url: url) do
      with_captured_exit { Hive::CLI.start([ "review", "--pr", pr_number.to_s ]) }
    end
  end

  # ── Core CLI & Creation Contract ───────────────────────────────────────

  def test_review_pr_creates_task_and_runs_review_stage
    with_registered_pr_project do |env|
      runs = []
      out, err, status = run_initial_create(env, runs: runs)

      assert_equal Hive::ExitCodes::SUCCESS, status, "stderr: #{err}\nstdout: #{out}"
      assert_includes out, "hive: marker=review_waiting"
      assert_includes out, "next:"

      slug = "adhoc-review-pr-197"
      folder = File.join(env[:hive_state], "stages", "6-review", slug)
      wt = File.join(env[:worktree_root], slug)
      assert_equal [ { folder: folder, head: env[:oid_a] } ], runs
      assert File.directory?(folder)
      assert File.directory?(File.join(folder, "reviews"))
      assert_equal env[:oid_a], git(wt, "rev-parse", "HEAD").strip
      assert_equal "hive/review/pr-197", git(wt, "branch", "--show-current").strip

      pr = Hive::Gh.pr_frontmatter(File.join(folder, "pr.md"))
      assert_equal 197, pr.fetch("pr_number")
      assert_equal "ad-hoc", pr.fetch("source")
      assert_equal "main", pr.fetch("base_ref_name")
      assert_equal env[:oid_a], pr.fetch("head_oid")

      worktree = YAML.safe_load(File.read(File.join(folder, "worktree.yml")))
      assert_equal wt, worktree.fetch("path")
      assert_equal "hive/review/pr-197", worktree.fetch("branch")
      assert_equal env[:oid_a], worktree.fetch("execute_base_head")
    end
  end

  def test_review_pr_reuses_existing_task_on_next_pass
    with_registered_pr_project do |env|
      runs = []
      with_pr_stubs(head: env[:oid_a], runs: runs) do
        _o1, _e1, s1 = with_captured_exit { Hive::CLI.start([ "review", "--pr", "#197" ]) }
        _o2, _e2, s2 = with_captured_exit { Hive::CLI.start([ "review", "--pr", "https://github.com/o/r/pull/197" ]) }
        assert_equal Hive::ExitCodes::SUCCESS, s1
        assert_equal Hive::ExitCodes::SUCCESS, s2
      end

      slug = "adhoc-review-pr-197"
      folder = File.join(env[:hive_state], "stages", "6-review", slug)
      assert_equal [ folder, folder ], runs.map { |r| r[:folder] }
      assert_equal [ slug ], Dir.children(File.join(env[:hive_state], "stages", "6-review"))
    end
  end

  def test_review_pr_runs_a_fork_pr_end_to_end_through_the_review_path
    with_registered_pr_project do |env|
      runs = []
      _out, err, status = run_initial_create(
        env, runs: runs, fork: true, url: "https://github.com/o/r/pull/197"
      )
      assert_equal Hive::ExitCodes::SUCCESS, status, "stderr: #{err}"

      slug = "adhoc-review-pr-197"
      folder = File.join(env[:hive_state], "stages", "6-review", slug)
      assert_equal [ folder ], runs.map { |r| r[:folder] }
      pr = Hive::Gh.pr_frontmatter(File.join(folder, "pr.md"))
      assert_equal true, pr.fetch("is_cross_repository")
      assert_equal "fork/r", pr.fetch("head_repository")
      assert_equal "https://github.com/o/r/pull/197", pr.fetch("pr_url")
    end
  end

  def test_review_pr_json_emits_destination_collision_envelope
    with_registered_pr_project do |env|
      FileUtils.mkdir_p(File.join(env[:hive_state], "stages", "5-open-pr", "owned-task"))
      File.write(
        File.join(env[:hive_state], "stages", "5-open-pr", "owned-task", "pr.md"),
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
    with_registered_pr_project do |env|
      with_replaced_singleton_method(Hive::Gh, :validated_pr_metadata, ->(*_args, **_kwargs) { raise "boom unexpected" }) do
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
    with_registered_pr_project do |env|
      with_pr_stubs(head: env[:oid_a]) do
        out, err, status = with_captured_exit { Hive::CLI.start([ "review", "--pr", "197", "--json" ]) }

        assert_equal Hive::ExitCodes::SUCCESS, status, "stderr: #{err}\nstdout: #{out}"
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
    with_registered_pr_project do |_env|
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
    with_registered_pr_project do |_env|
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

  # ── AE1–AE9 End-to-End Real-Git Reconciliation Acceptance Suite ────────

  def test_ae1_unchanged_rerun_preserves_entire_task_folder_git_state_and_releases_sqlite_lease
    with_registered_pr_project do |env|
      run_initial_create(env)
      slug = "adhoc-review-pr-197"
      folder = File.join(env[:hive_state], "stages", "6-review", slug)
      wt = File.join(env[:worktree_root], slug)
      task = Hive::Task.new(folder)

      # At the U2 reconciliation boundary (before attempt admission), unchanged head
      # must be a byte-for-byte no-op on both the entire task folder and Git state.
      before_tree = snapshot_tree(folder)
      before_git = snapshot_git(env[:repo], wt)
      gh = Object.new
      meta_a = metadata(number: 197, head: env[:oid_a])
      gh.define_singleton_method(:validated_pr_metadata) { |*, **| meta_a }

      reconciler = Hive::InternalPrCheckout::Reconciler.new(gh: gh, allow_local_transport: true)
      result = Hive::Lock.with_task_lock(folder) do
        reconciler.reconcile(task: task, mode: :explicit_reopen)
      end

      assert_equal "current", result.status
      assert_equal "head_unchanged", result.reason
      assert_equal 1, result.generation
      assert_equal env[:oid_a], result.head_oid
      assert_equal before_tree, snapshot_tree(folder),
                   "AE1: unchanged rerun must not modify any path, type, or byte in task folder"
      assert_equal before_git, snapshot_git(env[:repo], wt),
                   "AE1: unchanged rerun must not modify HEAD, branch, index, or refs"
      assert Hive::Lock.task_lease_repository.lease_snapshot(folder).fetch(:idle),
             "AE1: SQLite task lease must be released after reconciliation"

      # Separately exercise the full CLI on unchanged head; controller appends are allowed
      # while generation and Git checkout stay untouched.
      with_pr_stubs(head: env[:oid_a]) do
        out, err, status = with_captured_exit { Hive::CLI.start([ "review", "--pr", "197", "--json" ]) }
        assert_equal Hive::ExitCodes::SUCCESS, status, "stderr: #{err}"
        payload = JSON.parse(out)
        assert_equal "current", payload.dig("reconciliation", "status")
        assert_equal "head_unchanged", payload.dig("reconciliation", "reason")
        assert_equal env[:oid_a], payload.dig("reconciliation", "head_oid")
      end
      assert_equal before_git, snapshot_git(env[:repo], wt)
    end
  end

  def test_ae2_ae6_ae7_idle_repush_checks_out_exact_oid_retires_old_state_and_honors_manual_steering
    with_registered_pr_project do |env|
      run_initial_create(env)
      slug = "adhoc-review-pr-197"
      folder = File.join(env[:hive_state], "stages", "6-review", slug)
      wt = File.join(env[:worktree_root], slug)
      state_file = File.join(folder, "task.md")

      # Seed AE6 + AE7 state: embedded/shadowed REVIEW_COMPLETE + trailing REVIEW_WAITING +
      # operator prose + findings, suppressions, fix/browser/ci/publication receipts.
      File.write(state_file, <<~MD)
        ---
        source: ad-hoc
        ---

        Operator note: keep checking edge cases.

        <!-- REVIEW_COMPLETE pass=1 -->

        <!-- REVIEW_WAITING pass=2 escalations=1 -->
      MD
      File.write(File.join(folder, "reviews", "claude-01.md"), "## High\n- [ ] old finding\n")
      File.write(File.join(folder, "reviews", "escalations-02.md"), "### Q1. Old waiting?\n")
      File.write(File.join(folder, "reviews", "suppressed.md"), "- old suppression\n")
      File.write(File.join(folder, "reviews", "fix-success-01.md"), "head: #{env[:oid_a]}\n")
      File.write(File.join(folder, "reviews", "browser-result-01-01.json"), '{"status":"failed"}')
      File.write(File.join(folder, "reviews", "ci-blocked.md"), "old red ci\n")
      File.write(File.join(folder, "github-publication.json"), '{"pr_url":"https://github.com/o/r/pull/197"}')

      # Push new head B to real bare remote and reopen via full CLI.
      push_pr_head(env, env[:oid_b])
      runs = []
      seen_active_reviews_on_run = nil
      seen_marker_on_run = nil
      with_pr_stubs(
        head: env[:oid_b],
        runs: runs,
        on_review: lambda { |task, _cfg|
          seen_active_reviews_on_run = Dir.children(task.reviews_dir).reject { |n| n == "archive" }
          seen_marker_on_run = Hive::Markers.current(task.state_file).name
          Hive::Markers.set(task.state_file, :review_complete, pass: 1)
          { commit: nil, status: :review_complete }
        }
      ) do
        out, err, status = with_captured_exit { Hive::CLI.start([ "review", "--pr", "197", "--json" ]) }
        assert_equal Hive::ExitCodes::SUCCESS, status, "stderr: #{err}\nstdout: #{out}"
        payload = JSON.parse(out)
        assert_equal "reopened", payload.dig("reconciliation", "status")
        assert_equal "head_changed", payload.dig("reconciliation", "reason")
        assert_equal 2, payload.dig("reconciliation", "generation")
        assert_equal env[:oid_b], payload.dig("reconciliation", "head_oid")
        assert_equal env[:oid_a], payload.dig("reconciliation", "previous_head_oid")
      end

      assert_equal [ { folder: folder, head: env[:oid_b] } ], runs
      assert_empty seen_active_reviews_on_run, "AE7: fresh review must start with empty active reviews/"
      assert_equal :none, seen_marker_on_run, "AE6: old embedded REVIEW_COMPLETE and REVIEW_WAITING must be stripped"
      assert_equal env[:oid_b], git(wt, "rev-parse", "HEAD").strip
      assert_equal "hive/review/pr-197", git(wt, "branch", "--show-current").strip
      assert_equal env[:oid_b], Hive::Gh.pr_frontmatter(File.join(folder, "pr.md")).fetch("head_oid")
      assert_equal env[:oid_b], YAML.safe_load(File.read(File.join(folder, "worktree.yml"))).fetch("execute_base_head")
      assert_includes File.read(state_file), "Operator note: keep checking edge cases."
      refute File.exist?(File.join(folder, "github-publication.json"))

      archives = Dir.children(File.join(folder, "reviews", "archive"))
      assert_equal 1, archives.size
      archived_dir = File.join(folder, "reviews", "archive", archives.first)
      assert File.file?(File.join(archived_dir, "claude-01.md"))
      assert File.file?(File.join(archived_dir, "escalations-02.md"))
      assert File.file?(File.join(archived_dir, "suppressed.md"))
      assert File.file?(File.join(archived_dir, "head-state", "github-publication.json"))

      # AE6 steering hold: active MANUAL_STEERING preserves checkout/marker and prevents admission.
      Hive::Markers.set(state_file, :manual_steering)
      push_pr_head(env, env[:oid_c])
      steering_runs = []
      with_pr_stubs(head: env[:oid_c], runs: steering_runs) do
        out, _err, status = with_captured_exit { Hive::CLI.start([ "review", "--pr", "197", "--json" ]) }
        refute_equal Hive::ExitCodes::SUCCESS, status
        payload = JSON.parse(out)
        assert_equal "busy", payload.dig("reconciliation", "status")
        assert_equal "manual_steering", payload.dig("reconciliation", "reason")
      end
      assert_empty steering_runs
      assert_equal env[:oid_b], git(wt, "rev-parse", "HEAD").strip
      assert_equal :manual_steering, Hive::Markers.current(state_file).name
    end
  end

  def test_ae3_ae4_lease_contention_returns_busy_and_unowned_pointer_blocks_with_zero_effects
    with_registered_pr_project do |env|
      run_initial_create(env)
      slug = "adhoc-review-pr-197"
      folder = File.join(env[:hive_state], "stages", "6-review", slug)
      wt = File.join(env[:worktree_root], slug)
      task = Hive::Task.new(folder)
      push_pr_head(env, env[:oid_b])

      # AE3: Real SQLite lease contention returns retryable busy immediately with zero writes/fetches.
      before_tree = snapshot_tree(folder)
      before_git = snapshot_git(env[:repo], wt)
      fetch_called = false
      fail_gate = Object.new
      fail_gate.define_singleton_method(:fetch_pull_request_commit) { |*| fetch_called = true; flunk "must not fetch" }

      busy_result = nil
      Hive::Lock.with_task_lock(folder) do
        # A competing thread hits real SQLite task-lease contention immediately.
        busy_result = Thread.new do
          Hive::InternalPrCheckout.reconcile(
            task: task, mode: :explicit_reopen, gate: fail_gate
          )
        end.value
      end
      assert_equal "busy", busy_result.status
      assert_equal "task_locked", busy_result.reason
      assert_equal true, busy_result.retryable
      refute fetch_called
      assert_equal before_tree, snapshot_tree(folder)
      assert_equal before_git, snapshot_git(env[:repo], wt)

      # AE4: Unowned pointer (wrong branch) returns blocked and never calls Git fetch/reset or writes.
      File.write(
        File.join(folder, "worktree.yml"),
        { "path" => wt, "branch" => "wrong-branch", "execute_base_head" => env[:oid_a] }.to_yaml
      )
      corrupt_tree = snapshot_tree(folder)
      fail_gh = Object.new
      fail_gh.define_singleton_method(:validated_pr_metadata) { |*, **| flunk "must not call provider on unowned pointer" }
      blocked = Hive::Lock.with_task_lock(folder) do
        Hive::InternalPrCheckout::Reconciler.new(gh: fail_gh, gate: fail_gate, allow_local_transport: true)
                                            .reconcile(task: task, mode: :explicit_reopen)
      end
      assert_equal "blocked", blocked.status
      assert_equal "pointer_unowned", blocked.reason
      assert_equal false, blocked.retryable
      refute fetch_called
      assert_equal corrupt_tree, snapshot_tree(folder)
      assert_equal before_git, snapshot_git(env[:repo], wt)
    end
  end

  def test_ae5_real_mid_checkout_interruption_recovers_with_ignored_cache_preserves_obstruction_and_refuses_third_state
    with_registered_pr_project do |env|
      run_initial_create(env)
      slug = "adhoc-review-pr-197"
      folder = File.join(env[:hive_state], "stages", "6-review", slug)
      wt = File.join(env[:worktree_root], slug)
      task = Hive::Task.new(folder)
      push_pr_head(env, env[:oid_b])

      # Seed unrelated ignored build output that MUST survive every transition/recovery.
      FileUtils.mkdir_p(File.join(wt, "build"))
      File.write(File.join(wt, "build", "cache.bin"), "keep-me-bytes-1234\n")

      gh = Object.new
      meta_b = metadata(number: 197, head: env[:oid_b])
      gh.define_singleton_method(:validated_pr_metadata) { |*, **| meta_b }

      # 1. Ignored obstruction: obstructed.txt is ignored in A and tracked in target B ->
      #    must block cleanly AND preserve the exact bytes of obstructed.txt.
      obstructed_path = File.join(wt, "obstructed.txt")
      File.write(obstructed_path, "precious-local-ignored-bytes\n")
      obstructed_res = Hive::Lock.with_task_lock(folder) do
        Hive::InternalPrCheckout::Reconciler.new(gh: gh, allow_local_transport: true)
                                            .reconcile(task: task, mode: :explicit_reopen)
      end
      assert_equal "blocked", obstructed_res.status
      assert_equal "precious-local-ignored-bytes\n", File.read(obstructed_path),
                   "AE5: bytes under ignored obstruction must be preserved"
      assert_equal "keep-me-bytes-1234\n", File.read(File.join(wt, "build", "cache.bin"))
      assert_equal env[:oid_a], git(wt, "rev-parse", "HEAD").strip
      FileUtils.rm_f(obstructed_path)

      # 2. Interrupt immediately AFTER ref-writing fetch -> recovers cleanly to B, preserving build/cache.bin.
      crash_err = Class.new(StandardError)
      assert_raises(crash_err) do
        Hive::Lock.with_task_lock(folder) do
          Hive::InternalPrCheckout::Reconciler.new(
            gh: gh, allow_local_transport: true,
            failpoint: ->(phase, _ctx) { raise crash_err, "boom at #{phase}" if phase == :after_fetch_before_fetched_journal }
          ).reconcile(task: task, mode: :explicit_reopen)
        end
      end
      assert Hive::InternalPrCheckout::Store.new(folder).pending_present?

      # Inject a third-state non-ignored untracked file while pending -> recovery MUST block without mutation.
      stray_path = File.join(wt, "untracked-user-work.txt")
      File.write(stray_path, "do-not-delete\n")
      refused_third = Hive::Lock.with_task_lock(folder) do
        Hive::InternalPrCheckout::Reconciler.new(gh: gh, allow_local_transport: true)
                                            .reconcile(task: task, mode: :explicit_reopen)
      end
      assert_equal "blocked", refused_third.status
      assert_equal "do-not-delete\n", File.read(stray_path)
      FileUtils.rm_f(stray_path)

      # Clean restart recovers the interrupted fetch cleanly -> rolls back to A (unconfirmed) or completes to B.
      recovered = Hive::Lock.with_task_lock(folder) do
        Hive::InternalPrCheckout::Reconciler.new(gh: gh, allow_local_transport: true)
                                            .reconcile(task: task, mode: :explicit_reopen)
      end
      assert_includes %w[reopened current], recovered.status
      assert_equal "keep-me-bytes-1234\n", File.read(File.join(wt, "build", "cache.bin"))
      # Ensure we reach B cleanly (if unconfirmed rollback returned current, one more reopen moves to B).
      if recovered.status == "current"
        recovered = Hive::Lock.with_task_lock(folder) do
          Hive::InternalPrCheckout::Reconciler.new(gh: gh, allow_local_transport: true)
                                              .reconcile(task: task, mode: :explicit_reopen)
        end
      end
      assert_equal "reopened", recovered.status
      assert_equal env[:oid_b], git(wt, "rev-parse", "HEAD").strip
      assert_equal "keep-me-bytes-1234\n", File.read(File.join(wt, "build", "cache.bin"))

      # 3. Real mid-checkout interruption AFTER confirmation (B -> C): rolls forward to C once, preserving build/cache.bin.
      push_pr_head(env, env[:oid_c])
      meta_c = metadata(number: 197, head: env[:oid_c])
      gh.define_singleton_method(:validated_pr_metadata) { |*, **| meta_c }
      assert_raises(crash_err) do
        Hive::Lock.with_task_lock(folder) do
          Hive::InternalPrCheckout::Reconciler.new(
            gh: gh, allow_local_transport: true,
            failpoint: ->(phase, _ctx) { raise crash_err, "boom at #{phase}" if phase == :after_confirmed }
          ).reconcile(task: task, mode: :explicit_reopen)
        end
      end
      assert Hive::InternalPrCheckout::Store.new(folder).pending_present?
      rolled_forward = Hive::Lock.with_task_lock(folder) do
        Hive::InternalPrCheckout::Reconciler.new(gh: gh, allow_local_transport: true)
                                            .reconcile(task: task, mode: :local_verify)
      end
      assert_equal "reopened", rolled_forward.status
      assert_equal "pending_recovered_reopened", rolled_forward.reason
      assert_equal 3, rolled_forward.generation
      assert_equal env[:oid_c], git(wt, "rev-parse", "HEAD").strip
      assert_equal "keep-me-bytes-1234\n", File.read(File.join(wt, "build", "cache.bin"))
    end
  end

  def test_ae8_late_remote_race_restores_prior_generation_and_post_linearization_push_handles_on_next_reopen
    with_registered_pr_project do |env|
      run_initial_create(env)
      slug = "adhoc-review-pr-197"
      folder = File.join(env[:hive_state], "stages", "6-review", slug)
      wt = File.join(env[:worktree_root], slug)
      task = Hive::Task.new(folder)
      push_pr_head(env, env[:oid_b])

      before_git = snapshot_git(env[:repo], wt)
      test_case = self
      obs_count = 0
      race_gh = Object.new
      race_gh.define_singleton_method(:validated_pr_metadata) do |number, **_kwargs|
        obs_count += 1
        head = obs_count == 1 ? env[:oid_b] : env[:oid_c]
        test_case.metadata(number: number, head: head)
      end

      raced = Hive::Lock.with_task_lock(folder) do
        Hive::InternalPrCheckout::Reconciler.new(gh: race_gh, allow_local_transport: true)
                                            .reconcile(task: task, mode: :explicit_reopen)
      end
      assert_equal "blocked", raced.status
      assert_equal "remote_changed_before_linearization", raced.reason
      assert_equal true, raced.retryable
      refute Hive::InternalPrCheckout::Store.new(folder).pending_present?
      assert_equal before_git, snapshot_git(env[:repo], wt),
                   "AE8: late race must restore HEAD, branch, index, and remove temporary quarantine refs"
      assert_equal 1, Hive::Stages::Review::PassArchive.generation(folder)

      # Post-linearization push: once final observation succeeded for B, a repush to C
      # afterwards leaves gen 2 at B intact and is reconciled cleanly on the next reopen.
      pushed_after_confirm = false
      post_gh = Object.new
      post_gh.define_singleton_method(:validated_pr_metadata) { |n, **| test_case.metadata(number: n, head: env[:oid_b]) }
      committed_b = Hive::Lock.with_task_lock(folder) do
        Hive::InternalPrCheckout::Reconciler.new(
          gh: post_gh, allow_local_transport: true,
          failpoint: lambda { |phase, _ctx|
            if phase == :after_confirmed && !pushed_after_confirm
              pushed_after_confirm = true
              push_pr_head(env, env[:oid_c])
            end
          }
        ).reconcile(task: task, mode: :explicit_reopen)
      end
      assert_equal "reopened", committed_b.status
      assert_equal 2, committed_b.generation
      assert_equal env[:oid_b], git(wt, "rev-parse", "HEAD").strip

      # Next explicit reopen picks up C as gen 3.
      next_gh = Object.new
      next_gh.define_singleton_method(:validated_pr_metadata) { |n, **| test_case.metadata(number: n, head: env[:oid_c]) }
      committed_c = Hive::Lock.with_task_lock(folder) do
        Hive::InternalPrCheckout::Reconciler.new(gh: next_gh, allow_local_transport: true)
                                            .reconcile(task: task, mode: :explicit_reopen)
      end
      assert_equal "reopened", committed_c.status
      assert_equal 3, committed_c.generation
      assert_equal env[:oid_c], git(wt, "rev-parse", "HEAD").strip
    end
  end

  def test_ae9_head_return_a_to_b_to_a_allocates_ordinals_1_2_3_preserves_clean_candidates_and_blocks_dirty_work
    with_registered_pr_project do |env|
      run_initial_create(env)
      slug = "adhoc-review-pr-197"
      folder = File.join(env[:hive_state], "stages", "6-review", slug)
      wt = File.join(env[:worktree_root], slug)
      task = Hive::Task.new(folder)

      # Author a clean controller-proven Hive candidate commit on top of A.
      File.write(File.join(wt, "hive-fix.txt"), "approved fix on A\n")
      git(wt, "add", "hive-fix.txt")
      git(wt, "commit", "-m", "hive review fix on A")
      cand_oid = git(wt, "rev-parse", "HEAD").strip
      Hive::InternalPrCheckout.record_candidate!(
        task: task, head_oid: cand_oid, pass: 1, kind: "fixed"
      )

      # Repush A -> B: candidate commit MUST be archived under an immutable generation ref before moving to B.
      push_pr_head(env, env[:oid_b])
      test_case = self
      gh = Object.new
      gh.define_singleton_method(:validated_pr_metadata) { |n, **| test_case.metadata(number: n, head: env[:oid_b]) }
      gen2 = Hive::Lock.with_task_lock(folder) do
        Hive::InternalPrCheckout::Reconciler.new(gh: gh, allow_local_transport: true)
                                            .reconcile(task: task, mode: :explicit_reopen)
      end
      assert_equal "reopened", gen2.status
      assert_equal 2, gen2.generation
      assert_equal env[:oid_b], git(wt, "rev-parse", "HEAD").strip
      assert_equal 2, Hive::Stages::Review::PassArchive.generation(folder)

      cand_refs = git(env[:repo], "for-each-ref", "--format=%(refname) %(objectname)",
                      "refs/hive/internal-pr-checkout/candidates/pr-197").lines.map(&:strip)
      assert cand_refs.any? { |line| line.end_with?(" #{cand_oid}") },
             "clean Hive-authored candidate commit must stay reachable under immutable ref; refs=#{cand_refs.inspect}"
      assert_equal "commit", git(env[:repo], "cat-file", "-t", cand_oid).strip

      # Repush B -> A (returns to earlier OID): allocates ordinal 3 with a fresh head_transition_digest.
      push_pr_head(env, env[:oid_a])
      gh.define_singleton_method(:validated_pr_metadata) { |n, **| test_case.metadata(number: n, head: env[:oid_a]) }
      gen3 = Hive::Lock.with_task_lock(folder) do
        Hive::InternalPrCheckout::Reconciler.new(gh: gh, allow_local_transport: true)
                                            .reconcile(task: task, mode: :explicit_reopen)
      end
      assert_equal "reopened", gen3.status
      assert_equal 3, gen3.generation
      assert_equal 3, Hive::Stages::Review::PassArchive.generation(folder)
      assert_equal env[:oid_a], git(wt, "rev-parse", "HEAD").strip
      refute_equal gen2.checkout_digest, gen3.checkout_digest

      # Unexplained diverged commit blocks WITHOUT resetting the branch.
      File.write(File.join(wt, "manual-unproven.txt"), "operator work\n")
      git(wt, "add", "manual-unproven.txt")
      git(wt, "commit", "-m", "unexplained local commit")
      unproven_oid = git(wt, "rev-parse", "HEAD").strip
      push_pr_head(env, env[:oid_c])
      gh.define_singleton_method(:validated_pr_metadata) { |n, **| test_case.metadata(number: n, head: env[:oid_c]) }
      diverged = Hive::Lock.with_task_lock(folder) do
        Hive::InternalPrCheckout::Reconciler.new(gh: gh, allow_local_transport: true)
                                            .reconcile(task: task, mode: :explicit_reopen)
      end
      assert_equal "blocked", diverged.status
      assert_equal "candidate_unproven", diverged.reason
      assert_equal unproven_oid, git(wt, "rev-parse", "HEAD").strip,
                   "unexplained local commit must NEVER be reset"
    end
  end

  def test_human_and_daemon_queued_reopen_converge_without_duplicate_attempts
    with_registered_pr_project do |env|
      run_initial_create(env)
      slug = "adhoc-review-pr-197"
      folder = File.join(env[:hive_state], "stages", "6-review", slug)
      task = Hive::Task.new(folder)

      # Capture gen-1 task generation before repush (simulating a daemon queued request from gen 1).
      gen1_token = Hive::Attempts::Generation.resolve(task: task, project: "demo", intended_stage: "6-review")

      # Human reopens on repushed head B -> commits gen 2.
      push_pr_head(env, env[:oid_b])
      test_case = self
      gh = Object.new
      gh.define_singleton_method(:validated_pr_metadata) { |n, **| test_case.metadata(number: n, head: env[:oid_b]) }
      reopened = Hive::Lock.with_task_lock(folder) do
        Hive::InternalPrCheckout::Reconciler.new(gh: gh, allow_local_transport: true)
                                            .reconcile(task: task, mode: :explicit_reopen)
      end
      assert_equal "reopened", reopened.status
      assert_equal 2, reopened.generation

      gen2_token = Hive::Attempts::Generation.resolve(task: task, project: "demo", intended_stage: "6-review")
      refute_equal gen1_token.task_generation, gen2_token.task_generation

      # Submit the stale gen-1 queued token through Attempts::Dispatcher:
      # must supersede cleanly with ZERO attempt rows created for the stale token.
      attempt_store = Hive::Attempts::Repository.new(
        root: File.join(env[:home], "runtime-payloads"),
        database: env[:database]
      )
      launched = []
      launcher = Object.new
      launcher.define_singleton_method(:preflight!) { true }
      launcher.define_singleton_method(:launch) do |record, claim_capability:|
        launched << [ record, claim_capability ]
        { "claimed" => true }
      end
      reconciler_instance = Hive::InternalPrCheckout::Reconciler.new(gh: gh, allow_local_transport: true)
      dispatcher = Hive::Attempts::Dispatcher.new(
        store: attempt_store,
        task_lease_repository: Hive::Lock.task_lease_repository,
        launcher: launcher,
        internal_pr_reconciler: ->(**kwargs) { reconciler_instance.reconcile(**kwargs) }
      )

      stale_res = dispatcher.dispatch(
        task: task,
        project: "demo",
        intended_stage: "6-review",
        request_id: "daemon-req-stale-gen1",
        provider: "claude",
        expected_task_generation: gen1_token.task_generation,
        reconcile_mode: :explicit_reopen,
        argv: [ "hive", "review", slug ]
      )
      assert_equal :superseded, stale_res.status
      assert_empty launched
      assert_equal 0, env[:database].transaction { |db| db[:attempts].where(request_id: "daemon-req-stale-gen1").count }

      # Now admit on gen 2 once; a second concurrent reopen converges on the existing live owner
      # with ZERO duplicate attempts.
      first_res = dispatcher.dispatch(
        task: task,
        project: "demo",
        intended_stage: "6-review",
        request_id: "human-req-gen2",
        provider: "claude",
        reconcile_mode: :explicit_reopen,
        argv: [ "hive", "review", slug ]
      )
      assert_equal :accepted, first_res.status
      assert_equal 1, launched.size

      second_res = dispatcher.dispatch(
        task: task,
        project: "demo",
        intended_stage: "6-review",
        request_id: "daemon-req-gen2",
        provider: "claude",
        reconcile_mode: :explicit_reopen,
        argv: [ "hive", "review", slug ]
      )
      assert_equal :existing_live, second_res.status
      assert_equal first_res.attempt.attempt_id, second_res.attempt.attempt_id
      assert_equal 1, launched.size, "human and daemon reopen must converge without duplicate attempts"
    end
  end
end
