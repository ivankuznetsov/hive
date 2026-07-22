require "test_helper"
require "hive/rebase"
require "hive/agent_profiles"
require "fileutils"
require "yaml"

# Unit tests for Hive::Rebase. The orchestration is exercised against
# a stubbed Hive::GitOps and a stubbed Hive::Stages::Base.spawn_agent
# to keep the tests fast and deterministic. The actual git+agent
# integration is covered by test/integration/run_*_test.rb under U4.
class HiveRebaseTest < Minitest::Test
  include HiveTestHelper

  FAKE_BIN = File.expand_path("../fixtures/fake-claude", __dir__)

  def setup
    @prev_claude_bin = ENV["HIVE_CLAUDE_BIN"]
    ENV["HIVE_CLAUDE_BIN"] = FAKE_BIN
    Hive::AgentProfile.reset_version_cache!
  end

  def teardown
    ENV["HIVE_CLAUDE_BIN"] = @prev_claude_bin
    Hive::AgentProfile.reset_version_cache!
  end

  # Minimal task-shape that responds to `worktree_path` and `folder`.
  FakeTask = Struct.new(:worktree_path, :folder, :log_dir, :state_file, :stage_name)

  def make_task(worktree:, folder:)
    FakeTask.new(worktree, folder, File.join(folder, "logs"), File.join(folder, "task.md"), "4-execute")
  end

  def base_cfg(overrides = {})
    {
      "rebase" => { "enabled" => true, "conflict_resolution_timeout_sec" => 60 },
      "execute" => { "agent" => "claude" },
      "budget_usd" => { "execute_implementation" => 100 },
      "default_branch" => "master",
      "agents" => {
        "claude" => { "bin" => "claude", "env_override" => "HIVE_CLAUDE_BIN", "min_version" => "2.1.118" }
      }
    }.merge(overrides)
  end

  # Fake GitOps that records calls and answers configured boolean/value
  # questions. The default shape is "clean worktree, 0 behind, no conflicts."
  class FakeGitOps
    attr_reader :rebase_abort_called, :reset_hard_called, :continued
    attr_accessor :rebase_in_progress_value, :dirty_value, :detached_value,
                  :fetch_result, :commits_behind_value,
                  :rebase_onto_outcome, :rebase_continue_outcomes,
                  :unmerged_files_sequence, :head_sha_value, :default_branch_value,
                  :current_branch_value, :ancestor_value, :project_root

    def initialize(project_root)
      @project_root = project_root
      @rebase_in_progress_value = false
      @dirty_value = false
      @detached_value = false
      @fetch_result = true
      @commits_behind_value = 0
      @rebase_onto_outcome = :ok      # :ok | :conflict | Hive::GitError
      @rebase_continue_outcomes = []  # mutable stack consumed by rebase_continue
      @unmerged_files_sequence = []   # stack consumed by staged_unmerged_files
      @head_sha_value = "newshasha"
      @default_branch_value = "master"
      @current_branch_value = nil
      @ancestor_value = true
      @rebase_abort_called = false
      @reset_hard_called = false
      @continued = 0
    end

    def rebase_in_progress?; @rebase_in_progress_value; end
    def dirty?; @dirty_value; end
    def detached_head?; @detached_value; end
    def fetch_default_branch(_ref); @fetch_result; end
    def commits_behind(_ref); @commits_behind_value; end
    def head_sha; @head_sha_value; end
    def default_branch; @default_branch_value; end
    def current_branch; @current_branch_value; end
    def ancestor?(_ancestor, _descendant); @ancestor_value; end

    def rebase_onto(_ref)
      case @rebase_onto_outcome
      when :ok then true
      when :conflict
        @rebase_in_progress_value = true
        raise Hive::RebaseConflict, "synthetic conflict"
      when Hive::GitError, Class
        raise (@rebase_onto_outcome.is_a?(Class) ? @rebase_onto_outcome : @rebase_onto_outcome.class),
              "synthetic git error"
      end
    end

    def rebase_continue
      @continued += 1
      outcome = @rebase_continue_outcomes.shift
      case outcome
      when :ok, nil
        @rebase_in_progress_value = false
        true
      when :conflict
        raise Hive::RebaseConflict, "synthetic continue conflict"
      else
        raise Hive::GitError, "synthetic continue failure"
      end
    end

    def rebase_abort
      @rebase_abort_called = true
      @rebase_in_progress_value = false
      true
    end

    def reset_hard_orig_head
      @reset_hard_called = true
      true
    end

    def staged_unmerged_files
      @unmerged_files_sequence.shift || []
    end

    # Stub for the linked-worktree-aware commit-message lookup
    # added in PR #69 review B1. Tests don't exercise the actual
    # commit-message read (they stub spawn_agent), so returning nil
    # produces the "(commit message unavailable)" fallback the
    # template handles.
    def rebase_merge_message_path
      nil
    end
  end

  # Minitest::Mock.stub isn't bundled — patch singleton methods directly
  # and restore via ensure. Pattern matches test/unit/reviewers/plan_context_test.rb.
  def stub_gitops!(git)
    original = Hive::GitOps.singleton_class.instance_method(:new)
    Hive::GitOps.define_singleton_method(:new) { |_path| git }
    begin
      yield
    ensure
      Hive::GitOps.singleton_class.define_method(:new, original)
    end
  end

  def stub_spawn_agent(result_status: :ok, error_message: nil)
    original = Hive::Stages::Base.singleton_class.instance_method(:spawn_agent)
    Hive::Stages::Base.define_singleton_method(:spawn_agent) do |_task, **_kwargs|
      { status: result_status, error_message: error_message }
    end
    begin
      yield
    ensure
      Hive::Stages::Base.singleton_class.define_method(:spawn_agent, original)
    end
  end

  def make_worktree_and_folder
    [ Dir.mktmpdir("hive-rebase-worktree"), Dir.mktmpdir("hive-rebase-folder") ]
  end

  def teardown_dirs(*dirs)
    dirs.each { |d| FileUtils.rm_rf(d) if d && Dir.exist?(d) }
  end

  def make_remote_rebase_scenario(push_feature:)
    root = Dir.mktmpdir("hive-rebase-publish")
    origin = File.join(root, "origin.git")
    worktree = File.join(root, "worktree")
    folder = File.join(root, "task")
    FileUtils.mkdir_p(folder)

    run!("git", "init", "--bare", "--quiet", origin)
    run!("git", "init", "-b", "main", "--quiet", worktree)
    run!("git", "-C", worktree, "config", "user.email", "test@example.com")
    run!("git", "-C", worktree, "config", "user.name", "Test")
    run!("git", "-C", worktree, "config", "commit.gpgsign", "false")
    run!("git", "-C", worktree, "remote", "add", "origin", origin)

    File.write(File.join(worktree, "README.md"), "base\n")
    run!("git", "-C", worktree, "add", "README.md")
    run!("git", "-C", worktree, "commit", "-m", "base", "--quiet")
    run!("git", "-C", worktree, "push", "-u", "origin", "main", "--quiet")

    run!("git", "-C", worktree, "checkout", "-b", "feature", "--quiet")
    File.write(File.join(worktree, "feature.txt"), "feature\n")
    run!("git", "-C", worktree, "add", "feature.txt")
    run!("git", "-C", worktree, "commit", "-m", "feature", "--quiet")
    run!("git", "-C", worktree, "push", "-u", "origin", "feature", "--quiet") if push_feature
    original_remote_head = run!("git", "-C", worktree, "rev-parse", "HEAD").strip

    run!("git", "-C", worktree, "checkout", "main", "--quiet")
    File.write(File.join(worktree, "main.txt"), "advanced base\n")
    run!("git", "-C", worktree, "add", "main.txt")
    run!("git", "-C", worktree, "commit", "-m", "advance main", "--quiet")
    run!("git", "-C", worktree, "push", "origin", "main", "--quiet")
    run!("git", "-C", worktree, "checkout", "feature", "--quiet")

    {
      root: root,
      origin: origin,
      worktree: worktree,
      folder: folder,
      original_remote_head: original_remote_head
    }
  end

  def remote_feature_head(origin)
    run!("git", "--git-dir", origin, "rev-parse", "refs/heads/feature").strip
  end

  # ---- Skip paths (no rebase attempted) ----

  def test_disabled_returns_disabled_result
    worktree, folder = make_worktree_and_folder
    task = make_task(worktree: worktree, folder: folder)
    cfg = base_cfg("rebase" => { "enabled" => false })
    result = Hive::Rebase.perform(task, cfg)
    assert_equal false, result.attempted
    assert_equal :disabled, result.reason
    assert_equal 0, result.agent_resolutions
  ensure
    teardown_dirs(worktree, folder)
  end

  def test_no_worktree_returns_skipped
    folder = Dir.mktmpdir("hive-rebase-folder")
    task = make_task(worktree: nil, folder: folder)
    result = Hive::Rebase.perform(task, base_cfg)
    assert_equal :no_worktree, result.reason
    refute result.attempted
  ensure
    teardown_dirs(folder)
  end

  def test_dirty_worktree_returns_skipped
    worktree, folder = make_worktree_and_folder
    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.dirty_value = true
    stub_gitops!(git) do
      result = Hive::Rebase.perform(task, base_cfg)
      assert_equal :dirty_worktree, result.reason
      refute git.rebase_abort_called, "skip path must not call rebase_abort"
    end
  ensure
    teardown_dirs(worktree, folder)
  end

  def test_pre_existing_rebase_returns_skipped
    worktree, folder = make_worktree_and_folder
    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.rebase_in_progress_value = true
    stub_gitops!(git) do
      result = Hive::Rebase.perform(task, base_cfg)
      assert_equal :pre_existing_rebase, result.reason
    end
  ensure
    teardown_dirs(worktree, folder)
  end

  def test_detached_head_returns_skipped
    worktree, folder = make_worktree_and_folder
    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.detached_value = true
    stub_gitops!(git) do
      result = Hive::Rebase.perform(task, base_cfg)
      assert_equal :detached_head, result.reason
    end
  ensure
    teardown_dirs(worktree, folder)
  end

  def test_fetch_failure_returns_skipped
    worktree, folder = make_worktree_and_folder
    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.fetch_result = false
    stub_gitops!(git) do
      result = Hive::Rebase.perform(task, base_cfg)
      assert_equal :fetch_failed, result.reason
    end
  ensure
    teardown_dirs(worktree, folder)
  end

  def test_no_drift_returns_no_op
    worktree, folder = make_worktree_and_folder
    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.commits_behind_value = 0
    stub_gitops!(git) do
      result = Hive::Rebase.perform(task, base_cfg)
      assert result.attempted
      assert result.succeeded
      assert_equal 0, result.commits_behind
      assert_nil result.reason
    end
  ensure
    teardown_dirs(worktree, folder)
  end

  # ---- Happy path (rebase succeeds) ----

  def test_clean_rebase_succeeds_without_agent_dispatch
    worktree, folder = make_worktree_and_folder
    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.commits_behind_value = 3
    git.rebase_onto_outcome = :ok

    stub_gitops!(git) do
      result = Hive::Rebase.perform(task, base_cfg)
      assert result.succeeded
      assert_equal 3, result.commits_behind
      assert_equal 0, result.agent_resolutions
      assert_empty result.resolved_files
    end
  ensure
    teardown_dirs(worktree, folder)
  end

  def test_successful_rebase_publishes_rewritten_branch_before_later_stage_commits
    scenario = make_remote_rebase_scenario(push_feature: true)
    worktree = scenario.fetch(:worktree)
    task = make_task(worktree: worktree, folder: scenario.fetch(:folder))

    result = Hive::Rebase.perform(task, base_cfg("default_branch" => "main"))

    assert result.succeeded
    rebased_head = run!("git", "-C", worktree, "rev-parse", "HEAD").strip
    refute_equal scenario.fetch(:original_remote_head), rebased_head
    assert_equal rebased_head, remote_feature_head(scenario.fetch(:origin)),
                 "auto-rebase must publish its rewritten branch before later stages add commits"

    File.write(File.join(worktree, "review-fix.txt"), "review fix\n")
    run!("git", "-C", worktree, "add", "review-fix.txt")
    run!("git", "-C", worktree, "commit", "-m", "review fix", "--quiet")
    run!("git", "-C", worktree, "push", "origin", "feature", "--quiet")
  ensure
    teardown_dirs(scenario&.fetch(:root))
  end

  def test_successful_rebase_keeps_pre_pr_branch_local
    scenario = make_remote_rebase_scenario(push_feature: false)
    task = make_task(worktree: scenario.fetch(:worktree), folder: scenario.fetch(:folder))

    result = Hive::Rebase.perform(task, base_cfg("default_branch" => "main"))

    assert result.succeeded
    assert_empty result.post_rebase_warnings
    refs = run!("git", "--git-dir", scenario.fetch(:origin), "for-each-ref",
                "--format=%(refname)", "refs/heads/feature")
    assert_empty refs, "auto-rebase must not publish a branch before open-pr"
  ensure
    teardown_dirs(scenario&.fetch(:root))
  end

  def test_concurrent_remote_movement_rejects_exact_lease_without_overwrite
    scenario = make_remote_rebase_scenario(push_feature: true)
    worktree = scenario.fetch(:worktree)
    origin = scenario.fetch(:origin)
    original_push = Hive::Gh.method(:push_branch)
    run_command = method(:run!)
    read_remote_head = method(:remote_feature_head)
    concurrent_head = nil

    with_replaced_singleton_method(Hive::Gh, :push_branch, lambda { |path, branch, **kwargs|
      attacker = File.join(scenario.fetch(:root), "attacker")
      run_command.call("git", "clone", "--quiet", "--branch", "feature", "--single-branch", origin, attacker)
      run_command.call("git", "-C", attacker, "config", "user.email", "attacker@example.com")
      run_command.call("git", "-C", attacker, "config", "user.name", "Attacker")
      File.write(File.join(attacker, "concurrent.txt"), "concurrent update\n")
      run_command.call("git", "-C", attacker, "add", "concurrent.txt")
      run_command.call("git", "-C", attacker, "commit", "-m", "concurrent update", "--quiet")
      run_command.call("git", "-C", attacker, "push", "origin", "feature", "--quiet")
      concurrent_head = read_remote_head.call(origin)
      original_push.call(path, branch, **kwargs)
    }) do
      task = make_task(worktree: worktree, folder: scenario.fetch(:folder))
      result = Hive::Rebase.perform(task, base_cfg("default_branch" => "main"))

      assert result.succeeded
      assert(result.post_rebase_warnings.any? { |warning| warning.include?("exact lease push failed") })
    end

    assert_equal concurrent_head, remote_feature_head(origin),
                 "exact lease failure must preserve the concurrent remote commit"
    refute_equal run!("git", "-C", worktree, "rev-parse", "HEAD").strip,
                 remote_feature_head(origin)
  ensure
    teardown_dirs(scenario&.fetch(:root))
  end

  def test_rebase_publication_uses_exact_pre_rebase_oid_lease_and_surfaces_failure
    worktree, folder = make_worktree_and_folder
    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.commits_behind_value = 2
    git.current_branch_value = "feature"
    remote_oid = "a" * 40
    pushed = nil
    failure = Hive::Gh::PushResult.new(success: false, stdout: "", stderr: "stale info")

    with_replaced_singleton_method(Hive::Gh, :remote_branch_oid,
                                   ->(*_args, **_kwargs) { remote_oid }) do
      with_replaced_singleton_method(Hive::Gh, :push_branch, lambda { |*args, **kwargs|
        pushed = [ args, kwargs ]
        failure
      }) do
        stub_gitops!(git) do
          result = Hive::Rebase.perform(task, base_cfg)
          assert result.succeeded
          assert(result.post_rebase_warnings.any? { |warning| warning.include?("exact lease push failed") })
        end
      end
    end

    assert_equal [ worktree, "feature" ], pushed.fetch(0)
    assert_equal remote_oid, pushed.fetch(1).fetch(:expected_remote_oid)
  ensure
    teardown_dirs(worktree, folder)
  end

  def test_publication_exception_keeps_successful_rebase_and_warns
    worktree, folder = make_worktree_and_folder
    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.commits_behind_value = 2
    git.current_branch_value = "feature"

    result = nil
    _out, err = capture_io do
      with_replaced_singleton_method(Hive::Gh, :remote_branch_oid,
                                     ->(*_args, **_kwargs) { "a" * 40 }) do
        with_replaced_singleton_method(Hive::Gh, :push_branch,
                                       ->(*_args, **_kwargs) { raise Hive::GhError, "offline" }) do
          stub_gitops!(git) { result = Hive::Rebase.perform(task, base_cfg) }
        end
      end
    end

    assert result.succeeded
    assert(result.post_rebase_warnings.any? { |warning| warning.include?("Hive::GhError: offline") })
    assert_match(/remote history was left unchanged/, err)
  ensure
    teardown_dirs(worktree, folder)
  end

  def test_rebase_does_not_publish_when_remote_head_was_not_contained_locally
    worktree, folder = make_worktree_and_folder
    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.commits_behind_value = 2
    git.current_branch_value = "feature"
    git.ancestor_value = false
    remote_oid = "b" * 40

    result = nil
    _out, err = capture_io do
      with_replaced_singleton_method(Hive::Gh, :remote_branch_oid,
                                     ->(*_args, **_kwargs) { remote_oid }) do
        with_replaced_singleton_method(Hive::Gh, :push_branch,
                                       ->(*_args, **_kwargs) { flunk "diverged remote must not be pushed" }) do
          stub_gitops!(git) { result = Hive::Rebase.perform(task, base_cfg) }
        end
      end
    end

    assert result.succeeded
    assert(result.post_rebase_warnings.any? { |warning| warning.include?("not contained") })
    assert_match(/refusing to replace remote history/, err)
  ensure
    teardown_dirs(worktree, folder)
  end

  def test_publication_preflight_error_keeps_successful_rebase_and_warns
    worktree, folder = make_worktree_and_folder
    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.commits_behind_value = 2
    git.current_branch_value = "feature"

    result = nil
    _out, err = capture_io do
      with_replaced_singleton_method(Hive::Gh, :remote_branch_oid,
                                     ->(*_args, **_kwargs) { raise Hive::GhError, "offline" }) do
        with_replaced_singleton_method(Hive::Gh, :push_branch,
                                       ->(*_args, **_kwargs) { flunk "failed preflight must not push" }) do
          stub_gitops!(git) { result = Hive::Rebase.perform(task, base_cfg) }
        end
      end
    end

    assert result.succeeded
    assert(result.post_rebase_warnings.any? { |warning| warning.include?("preflight failed") })
    assert_match(/continuing without a remote rewrite/, err)
  ensure
    teardown_dirs(worktree, folder)
  end

  def test_failed_rebase_never_uses_captured_publication_lease
    worktree, folder = make_worktree_and_folder
    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.commits_behind_value = 2
    git.current_branch_value = "feature"
    git.rebase_onto_outcome = Hive::GitError

    with_replaced_singleton_method(Hive::Gh, :remote_branch_oid,
                                   ->(*_args, **_kwargs) { "c" * 40 }) do
      with_replaced_singleton_method(Hive::Gh, :push_branch,
                                     ->(*_args, **_kwargs) { flunk "failed rebase must not push" }) do
        stub_gitops!(git) do
          result = Hive::Rebase.perform(task, base_cfg)
          refute result.succeeded
          assert_equal :rebase_failed, result.reason
        end
      end
    end
  ensure
    teardown_dirs(worktree, folder)
  end

  def test_conflict_resolved_by_agent_succeeds
    worktree, folder = make_worktree_and_folder
    FileUtils.mkdir_p(worktree)
    File.write(File.join(worktree, "a.txt"), "merged content (no markers)\n")

    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.commits_behind_value = 2
    git.rebase_onto_outcome = :conflict
    git.unmerged_files_sequence = [ [ "a.txt" ], [] ]  # first call sees conflict, second (after continue) sees none
    git.rebase_continue_outcomes = [ :ok ]

    stub_gitops!(git) do
      stub_spawn_agent(result_status: :ok) do
        result = Hive::Rebase.perform(task, base_cfg)
        assert result.succeeded
        assert_equal 1, result.agent_resolutions
        assert_includes result.resolved_files, "a.txt"
      end
    end
  ensure
    teardown_dirs(worktree, folder)
  end

  def test_dirty_worktree_after_successful_rebase_aborts_and_resets
    # The agent's status is :ok, the rebase_continue loop drains
    # cleanly, but the agent left scratch files (untracked) or modified
    # files outside the conflict set. Treat the contamination as
    # rebase failure: aborting and resetting to ORIG_HEAD undoes the
    # rebase rather than letting later stages absorb the cruft.
    worktree, folder = make_worktree_and_folder
    FileUtils.mkdir_p(worktree)
    File.write(File.join(worktree, "a.txt"), "merged content (no markers)\n")

    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.commits_behind_value = 2
    git.rebase_onto_outcome = :conflict
    git.unmerged_files_sequence = [ [ "a.txt" ], [] ]
    git.rebase_continue_outcomes = [ :ok ]

    # Pre-rebase dirty? is checked before rebase_onto fires (preflight),
    # the agent-continued branch's dirty? check is reached only if the
    # agent calls `rebase --continue` itself (we test the orchestrator
    # path), and the new post-loop dirty? guard is the third call.
    # Sequence cleanliness so the preflight passes but the post-loop
    # contamination guard trips.
    dirty_calls = 0
    git.define_singleton_method(:dirty?) do
      dirty_calls += 1
      dirty_calls >= 2 # clean for preflight, dirty for post-loop guard
    end

    stub_gitops!(git) do
      stub_spawn_agent(result_status: :ok) do
        result = Hive::Rebase.perform(task, base_cfg)
        refute result.succeeded
        assert_equal :dirty_after_success, result.reason
        assert git.reset_hard_called,
               "dirty-after-success guard must reset to ORIG_HEAD to drop both the rebase and the cruft"
      end
    end
  ensure
    teardown_dirs(worktree, folder)
  end

  def test_conflict_agent_uses_development_agent_with_exit_code_status
    # Rebase conflict resolution is development work in the task worktree.
    # It must use cfg.execute.agent, but success is NOT an output artifact:
    # the rebase runner validates git conflict state and marker bytes after
    # the agent exits. Pin :exit_code_only so Codex's profile default
    # (:output_file_exists) cannot turn a successful conflict resolution into
    # `agent_failed` just because no expected_output path was supplied.
    worktree, folder = make_worktree_and_folder
    FileUtils.mkdir_p(worktree)
    File.write(File.join(worktree, "a.txt"), "resolved\n")

    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.commits_behind_value = 2
    git.rebase_onto_outcome = :conflict
    git.unmerged_files_sequence = [ [ "a.txt" ], [] ]
    git.rebase_continue_outcomes = [ :ok ]

    dispatched_with = nil
    original = Hive::Stages::Base.singleton_class.instance_method(:spawn_agent)
    Hive::Stages::Base.define_singleton_method(:spawn_agent) do |_task, **kwargs|
      dispatched_with = kwargs
      { status: :ok }
    end

    begin
      stub_gitops!(git) do
        result = Hive::Rebase.perform(task, base_cfg("execute" => { "agent" => "codex" }))
        assert result.succeeded
      end
    ensure
      Hive::Stages::Base.singleton_class.define_method(:spawn_agent, original)
    end

    refute_nil dispatched_with, "conflict-resolution agent must be dispatched"
    assert_equal :codex, dispatched_with[:profile].name,
                 "rebase helper must use the configured development agent"
    assert_equal :exit_code_only, dispatched_with[:status_mode],
                 "rebase helper must judge development-agent success by exit code"
  ensure
    teardown_dirs(worktree, folder)
  end

  # ---- Failure paths (abort + reset --hard) ----

  def test_agent_failure_aborts_and_returns_failed
    worktree, folder = make_worktree_and_folder
    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.commits_behind_value = 1
    git.rebase_onto_outcome = :conflict
    git.unmerged_files_sequence = [ [ "a.txt" ] ]

    result = nil
    _out, err = capture_io do
      stub_gitops!(git) do
        stub_spawn_agent(result_status: :error, error_message: "synthetic agent fail") do
          result = Hive::Rebase.perform(task, base_cfg)
        end
      end
    end

    refute result.succeeded
    assert_equal :agent_failed, result.reason
    assert git.rebase_abort_called
    assert git.reset_hard_called
    assert_match(/rebase conflict-resolution agent failed/, err,
                 "operator-visible diagnostic must name the agent failure before fail-soft abort")
    assert_match(/synthetic agent fail/, err,
                 "diagnostic must forward the agent's error_message detail")
  ensure
    teardown_dirs(worktree, folder)
  end

  def test_agent_failure_warn_falls_back_to_status_symbol_when_error_message_missing
    # When the agent dispatch produces a non-:ok result with no
    # error_message (e.g. status: :timeout from spawn_agent's preflight),
    # the operator-visible warn must still fire and surface the status
    # symbol — the `detail = error_message || status` fallback is the
    # only signal of WHY the rebase aborted.
    worktree, folder = make_worktree_and_folder
    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.commits_behind_value = 1
    git.rebase_onto_outcome = :conflict
    git.unmerged_files_sequence = [ [ "a.txt" ] ]

    result = nil
    _out, err = capture_io do
      stub_gitops!(git) do
        stub_spawn_agent(result_status: :timeout, error_message: nil) do
          result = Hive::Rebase.perform(task, base_cfg)
        end
      end
    end

    refute result.succeeded
    assert_equal :agent_failed, result.reason
    assert_match(/rebase conflict-resolution agent failed/, err)
    assert_match(/timeout/, err,
                 "warn must surface the status symbol when error_message is absent")
  ensure
    teardown_dirs(worktree, folder)
  end

  def test_plan_md_in_conflict_no_longer_aborts_after_b8
    # PR #69 review B8: the PROTECTED_BASENAMES basename-match check
    # was removed because (a) the orchestrator-owned files
    # (plan.md/worktree.yml/task.md) live in task.folder, NOT in
    # the worktree's git tree — they can't appear in
    # `staged_unmerged_files` by construction; and (b) the check
    # produced false-positives on legitimate project files named
    # `plan.md` at the worktree root. The real isolation boundary
    # is `add_dirs: []` on the conflict-resolution spawn. This test
    # pins the new contract: a `plan.md` in the conflict set
    # dispatches the agent normally and does NOT short-circuit.
    worktree, folder = make_worktree_and_folder
    FileUtils.mkdir_p(worktree)
    File.write(File.join(worktree, "plan.md"), "resolved\n")
    File.write(File.join(worktree, "a.txt"), "resolved\n")

    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.commits_behind_value = 1
    git.rebase_onto_outcome = :conflict
    git.unmerged_files_sequence = [ [ "plan.md", "a.txt" ], [] ]
    git.rebase_continue_outcomes = [ :ok ]

    dispatched_with = nil
    original = Hive::Stages::Base.singleton_class.instance_method(:spawn_agent)
    Hive::Stages::Base.define_singleton_method(:spawn_agent) do |_task, **kwargs|
      dispatched_with = kwargs
      { status: :ok }
    end
    begin
      stub_gitops!(git) do
        result = Hive::Rebase.perform(task, base_cfg)
        assert result.succeeded, "plan.md in conflict set should not abort the rebase"
      end
    ensure
      Hive::Stages::Base.singleton_class.define_method(:spawn_agent, original)
    end

    refute_nil dispatched_with, "agent must be dispatched (B8 removed the basename-match abort)"
    assert_equal [], dispatched_with[:add_dirs],
                 "agent isolation MUST still be add_dirs: [] — the security boundary moved here"
  ensure
    teardown_dirs(worktree, folder)
  end

  def test_markers_remaining_after_agent_aborts
    worktree, folder = make_worktree_and_folder
    FileUtils.mkdir_p(worktree)
    File.write(File.join(worktree, "a.txt"),
               "before\n<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> branch\nafter\n")

    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.commits_behind_value = 1
    git.rebase_onto_outcome = :conflict
    git.unmerged_files_sequence = [ [ "a.txt" ], [ "a.txt" ] ]

    stub_gitops!(git) do
      stub_spawn_agent(result_status: :ok) do
        result = Hive::Rebase.perform(task, base_cfg)
        assert_equal :markers_remaining, result.reason
        assert git.rebase_abort_called
      end
    end
  ensure
    teardown_dirs(worktree, folder)
  end

  def test_max_attempts_exceeded_aborts
    worktree, folder = make_worktree_and_folder
    FileUtils.mkdir_p(worktree)
    File.write(File.join(worktree, "a.txt"), "clean\n")  # no markers — passes the marker check

    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.commits_behind_value = 1
    git.rebase_onto_outcome = :conflict
    # After each rebase_continue, the next iteration finds the conflict
    # state STILL true — simulating an endlessly-conflicting branch.
    # Because each iteration calls staged_unmerged_files twice (once at
    # the top of the loop, once after the agent succeeds), and then
    # rebase_continue raises RebaseConflict to keep the loop alive.
    # Test triggers MAX_CONFLICT_RESOLUTIONS + 1 iterations.
    git.unmerged_files_sequence = Array.new(20) { [ "a.txt" ] }
    git.rebase_continue_outcomes = Array.new(20) { :conflict }

    stub_gitops!(git) do
      stub_spawn_agent(result_status: :ok) do
        result = Hive::Rebase.perform(task, base_cfg)
        assert_equal :max_attempts_exceeded, result.reason
        assert git.rebase_abort_called
      end
    end
  ensure
    teardown_dirs(worktree, folder)
  end

  # ---- Result envelope shape ----

  def test_result_to_h_for_envelope_serializes_reason_as_string
    result = Hive::Rebase::Result.failed(reason: :agent_failed,
                                         commits_behind: 2,
                                         agent_resolutions: 1,
                                         resolved_files: [ "a.txt" ])
    h = result.to_h_for_envelope
    assert_equal "agent_failed", h[:reason], "Symbol reasons serialize to strings for JSON"
    assert_equal true, h[:attempted]
    assert_equal false, h[:succeeded]
  end

  def test_result_to_h_for_envelope_succeeded_carries_null_reason
    result = Hive::Rebase::Result.succeeded(commits_behind: 0,
                                             agent_resolutions: 0,
                                             resolved_files: [])
    h = result.to_h_for_envelope
    assert_nil h[:reason]
  end

  # ---- U8: execute_base_head rewrite after successful rebase ----

  def test_update_execute_base_head_rewrites_yaml_on_success
    worktree, folder = make_worktree_and_folder
    File.write(File.join(folder, "worktree.yml"),
               YAML.dump({ "execute_base_head" => "oldsha", "branch" => "feature/x" }))

    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.commits_behind_value = 1
    git.rebase_onto_outcome = :ok
    git.head_sha_value = "newshasha"

    stub_gitops!(git) do
      result = Hive::Rebase.perform(task, base_cfg)
      assert result.succeeded
    end

    data = YAML.safe_load(File.read(File.join(folder, "worktree.yml")))
    assert_equal "newshasha", data["execute_base_head"], "execute_base_head rewritten to post-rebase HEAD"
    assert_equal "feature/x", data["branch"], "other fields preserved"
  ensure
    teardown_dirs(worktree, folder)
  end

  def test_update_execute_base_head_no_op_when_file_absent
    worktree, folder = make_worktree_and_folder
    # No worktree.yml written.
    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.commits_behind_value = 1
    git.rebase_onto_outcome = :ok

    stub_gitops!(git) do
      result = Hive::Rebase.perform(task, base_cfg)
      assert result.succeeded, "missing worktree.yml is a silent no-op, not a failure"
    end
  ensure
    teardown_dirs(worktree, folder)
  end

  def test_update_execute_base_head_not_called_on_skip
    worktree, folder = make_worktree_and_folder
    File.write(File.join(folder, "worktree.yml"),
               YAML.dump({ "execute_base_head" => "oldsha" }))
    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.dirty_value = true

    stub_gitops!(git) do
      result = Hive::Rebase.perform(task, base_cfg)
      assert_equal :dirty_worktree, result.reason
    end

    data = YAML.safe_load(File.read(File.join(folder, "worktree.yml")))
    assert_equal "oldsha", data["execute_base_head"], "skip path must NOT touch worktree.yml"
  ensure
    teardown_dirs(worktree, folder)
  end

  # ---- PR #69 review fixes ----

  def test_has_conflict_markers_fails_closed_on_unreadable_file
    # B5: when File.foreach raises (permission, EISDIR, encoding),
    # the safety-check returns true so the loop aborts rather than
    # trusts the agent's resolution.
    nonexistent = "/tmp/hive-rebase-test-nonexistent-#{$$}.txt"
    refute File.exist?(nonexistent)
    assert Hive::Rebase.send(:has_conflict_markers?, nonexistent),
           "unreadable / non-existent path must fail CLOSED (return true)"
  end

  def test_has_conflict_markers_fails_closed_on_directory_path
    # B5: a path that's a directory raises EISDIR from File.foreach.
    # The fail-closed default is true.
    with_tmp_dir do |dir|
      assert Hive::Rebase.send(:has_conflict_markers?, dir),
             "directory path must fail CLOSED (return true)"
    end
  end

  def test_unexpected_programmer_error_escapes_rebase_perform
    # B3: narrow rescue list — NoMethodError must propagate so logic
    # bugs surface in operator logs instead of being misattributed
    # to a generic 'unexpected_error' rebase failure.
    worktree, folder = make_worktree_and_folder
    task = make_task(worktree: worktree, folder: folder)

    # Override Hive::GitOps.new to raise NoMethodError mid-perform.
    original = Hive::GitOps.singleton_class.instance_method(:new)
    Hive::GitOps.define_singleton_method(:new) do |_path|
      raise NoMethodError, "synthetic programmer error"
    end
    begin
      assert_raises(NoMethodError) { Hive::Rebase.perform(task, base_cfg) }
    ensure
      Hive::GitOps.singleton_class.define_method(:new, original)
    end
  ensure
    teardown_dirs(worktree, folder)
  end

  def test_agent_called_continue_accepts_when_rebase_completed_cleanly
    # B9: if the agent ignores the "don't run --continue" directive
    # AND the rebase actually completed cleanly (no markers left,
    # worktree clean), accept the work rather than throwing it away
    # with reset --hard ORIG_HEAD. Simulate the agent's behavior by
    # flipping `rebase_in_progress_value` to false from inside the
    # stubbed spawn_agent — this models the agent running
    # `git rebase --continue` itself and the rebase completing.
    worktree, folder = make_worktree_and_folder
    FileUtils.mkdir_p(worktree)
    File.write(File.join(worktree, "a.txt"), "resolved\n")

    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.commits_behind_value = 2
    git.rebase_onto_outcome = :conflict
    # Top-of-loop sees one unmerged file. After agent flips rip=false,
    # the post-spawn `staged_unmerged_files` (called from the
    # accept-clean branch) returns [].
    git.unmerged_files_sequence = [ [ "a.txt" ], [] ]
    git.dirty_value = false

    original = Hive::Stages::Base.singleton_class.instance_method(:spawn_agent)
    Hive::Stages::Base.define_singleton_method(:spawn_agent) do |*_args, **_kwargs|
      git.rebase_in_progress_value = false  # simulate agent ran --continue
      { status: :ok }
    end

    begin
      stub_gitops!(git) do
        result = Hive::Rebase.perform(task, base_cfg)
        assert result.succeeded, "rebase completed cleanly should be accepted"
        refute git.rebase_abort_called, "successful agent-completion path must NOT abort"
      end
    ensure
      Hive::Stages::Base.singleton_class.define_method(:spawn_agent, original)
    end
  ensure
    teardown_dirs(worktree, folder)
  end

  # ---- P1: marker-bypass via `git add` (review of PR #69 deferred-items push) ----

  def test_markers_remaining_when_agent_git_adds_file_still_containing_markers
    # P1: the agent could `git add` a file with <<<<<<< markers left
    # in it. `staged_unmerged_files` then returns [] (file is now
    # "resolved" to git), but the bytes on disk still contain
    # markers. The fix scans the ORIGINALLY-unmerged paths, not
    # just what's currently unmerged. Without the fix, the next
    # rebase_continue would commit the markers into history.
    worktree, folder = make_worktree_and_folder
    FileUtils.mkdir_p(worktree)
    # File has markers in it — agent's "resolution" was to git add
    # without actually merging.
    File.write(File.join(worktree, "a.txt"),
               "<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> branch\n")

    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.commits_behind_value = 1
    git.rebase_onto_outcome = :conflict
    # Sequence: [top-of-loop sees a.txt unmerged], [post-spawn sees []
    # because the agent did git add]. The fix scans `unmerged` (captured
    # before dispatch), so the marker check still fires.
    git.unmerged_files_sequence = [ [ "a.txt" ], [] ]

    stub_gitops!(git) do
      stub_spawn_agent(result_status: :ok) do
        result = Hive::Rebase.perform(task, base_cfg)
        assert_equal :markers_remaining, result.reason,
                     "git-added markers must NOT bypass the marker scan"
        assert git.rebase_abort_called, "marker-bypass path must abort the rebase"
      end
    end
  ensure
    teardown_dirs(worktree, folder)
  end

  def test_markers_remaining_when_agent_continued_with_markers_committed
    # P1, second arm: if the agent runs `git rebase --continue` itself
    # with markers already committed, `staged_unmerged_files` is empty
    # AND `dirty?` is false (clean working tree, markers are in HEAD).
    # The fix scans the originally-unmerged paths against the worktree;
    # since the rebased commit contains the markers, the scan sees them
    # and the result is `markers_remaining` (NOT `agent_called_continue_itself`,
    # because the latter implies "didn't finish" — here the agent
    # finished but with bad output).
    worktree, folder = make_worktree_and_folder
    FileUtils.mkdir_p(worktree)
    File.write(File.join(worktree, "a.txt"),
               "<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> branch\n")

    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.commits_behind_value = 1
    git.rebase_onto_outcome = :conflict
    # Top-of-loop sees one unmerged file. The agent then commits with
    # markers AND runs --continue itself: rip=false, dirty?=false.
    git.unmerged_files_sequence = [ [ "a.txt" ], [] ]
    git.dirty_value = false

    original = Hive::Stages::Base.singleton_class.instance_method(:spawn_agent)
    Hive::Stages::Base.define_singleton_method(:spawn_agent) do |*_args, **_kwargs|
      git.rebase_in_progress_value = false  # agent ran --continue
      { status: :ok }
    end

    begin
      stub_gitops!(git) do
        result = Hive::Rebase.perform(task, base_cfg)
        assert_equal :markers_remaining, result.reason,
                     "markers committed by agent-continued path must surface as markers_remaining"
        assert git.rebase_abort_called
      end
    ensure
      Hive::Stages::Base.singleton_class.define_method(:spawn_agent, original)
    end
  ensure
    teardown_dirs(worktree, folder)
  end

  def test_markers_check_tolerates_files_resolved_by_deletion
    # If the agent's chosen resolution for a conflict is to DELETE the
    # file (a valid outcome), `unmerged` still lists the path but
    # the file no longer exists. The scan must not crash and must
    # not produce a false `markers_remaining`.
    worktree, folder = make_worktree_and_folder
    FileUtils.mkdir_p(worktree)
    # No file on disk for "deleted.txt" — the agent deleted it as the resolution.
    # File "kept.txt" survives without markers.
    File.write(File.join(worktree, "kept.txt"), "all good\n")

    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.commits_behind_value = 1
    git.rebase_onto_outcome = :conflict
    git.unmerged_files_sequence = [ [ "deleted.txt", "kept.txt" ], [] ]
    git.rebase_continue_outcomes = [ :ok ]

    stub_gitops!(git) do
      stub_spawn_agent(result_status: :ok) do
        result = Hive::Rebase.perform(task, base_cfg)
        assert result.succeeded,
               "deletion-as-resolution must not be miscategorised as markers_remaining (got #{result.reason})"
      end
    end
  ensure
    teardown_dirs(worktree, folder)
  end

  def test_protected_basenames_is_empty_after_b8
    # B8 documentation: the constant exists as a frozen empty list
    # so downstream importers don't break, but the check itself was
    # removed from resolve_conflicts. The real isolation is
    # `add_dirs: []` on the spawn.
    assert_equal [], Hive::Rebase::PROTECTED_BASENAMES
    assert Hive::Rebase::PROTECTED_BASENAMES.frozen?
  end

  def test_post_rebase_warnings_surfaces_worktree_yml_failure
    # B6: when update_execute_base_head! fails (e.g., malformed YAML
    # or I/O error), the warning lands in Result.post_rebase_warnings
    # AND on stderr — the JSON envelope consumer can see what went
    # wrong without parsing stderr.
    worktree, folder = make_worktree_and_folder
    File.write(File.join(folder, "worktree.yml"), ":::not-yaml:::malformed: [")

    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.commits_behind_value = 1
    git.rebase_onto_outcome = :ok
    git.head_sha_value = "newsha"

    stub_gitops!(git) do
      result = Hive::Rebase.perform(task, base_cfg)
      assert result.succeeded, "rebase success despite worktree.yml write failure"
      refute_empty result.post_rebase_warnings,
                   "malformed worktree.yml must surface as a post-rebase warning"
      assert(result.post_rebase_warnings.any? { |w| w.include?("execute_base_head") },
             "warning text must name the field that failed to update")
    end
  ensure
    teardown_dirs(worktree, folder)
  end

  def test_update_execute_base_head_not_called_on_failure
    worktree, folder = make_worktree_and_folder
    File.write(File.join(folder, "worktree.yml"),
               YAML.dump({ "execute_base_head" => "oldsha" }))
    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.commits_behind_value = 1
    git.rebase_onto_outcome = :conflict
    git.unmerged_files_sequence = [ [ "a.txt" ] ]

    stub_gitops!(git) do
      stub_spawn_agent(result_status: :error) do
        result = Hive::Rebase.perform(task, base_cfg)
        refute result.succeeded
      end
    end

    data = YAML.safe_load(File.read(File.join(folder, "worktree.yml")))
    assert_equal "oldsha", data["execute_base_head"],
                 "failure path must NOT touch worktree.yml"
  ensure
    teardown_dirs(worktree, folder)
  end
  def test_no_default_branch_returns_skipped
    worktree, folder = make_worktree_and_folder
    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.default_branch_value = "  "
    git.define_singleton_method(:fetch_default_branch) do |_ref|
      raise "fetch must not run without a default branch"
    end

    stub_gitops!(git) do
      result = Hive::Rebase.perform(task, base_cfg("default_branch" => nil))
      assert_equal :no_default_branch, result.reason
      refute result.attempted
    end
  ensure
    teardown_dirs(worktree, folder)
  end

  def test_unexpected_io_error_returns_failed_result
    worktree, folder = make_worktree_and_folder
    task = make_task(worktree: worktree, folder: folder)
    original = Hive::GitOps.singleton_class.instance_method(:new)
    result = nil

    _out, err = capture_io do
      Hive::GitOps.define_singleton_method(:new) do |_path|
        raise IOError, "disk unavailable"
      end
      result = Hive::Rebase.perform(task, base_cfg)
    ensure
      Hive::GitOps.singleton_class.define_method(:new, original)
    end

    refute result.succeeded
    assert_equal :unexpected_io_error, result.reason
    assert_nil result.commits_behind
    assert_match(/rebase unexpected I\/O error: IOError: disk unavailable/, err)
  ensure
    teardown_dirs(worktree, folder)
  end

  def test_rebase_git_error_returns_failed_without_conflict_agent
    worktree, folder = make_worktree_and_folder
    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.commits_behind_value = 2
    git.rebase_onto_outcome = Hive::GitError

    result = nil
    _out, err = capture_io do
      stub_gitops!(git) do
        result = Hive::Rebase.perform(task, base_cfg)
      end
    end

    refute result.succeeded
    assert_equal :rebase_failed, result.reason
    assert_equal 2, result.commits_behind
    refute git.rebase_abort_called
    assert_match(/rebase failed \(Hive::GitError\): synthetic git error/, err)
  ensure
    teardown_dirs(worktree, folder)
  end

  def test_no_conflict_agent_profile_aborts
    worktree, folder = make_worktree_and_folder
    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.commits_behind_value = 1
    git.rebase_onto_outcome = :conflict

    stub_gitops!(git) do
      stub_stage_profile(nil) do
        result = Hive::Rebase.perform(task, base_cfg)
        assert_equal :no_conflict_agent_configured, result.reason
        assert git.rebase_abort_called
        assert git.reset_hard_called
      end
    end
  ensure
    teardown_dirs(worktree, folder)
  end

  def test_empty_unmerged_conflict_state_continues_and_succeeds
    worktree, folder = make_worktree_and_folder
    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.commits_behind_value = 1
    git.rebase_onto_outcome = :conflict
    git.unmerged_files_sequence = [ [] ]
    git.rebase_continue_outcomes = [ :ok ]

    stub_gitops!(git) do
      result = Hive::Rebase.perform(task, base_cfg)
      assert result.succeeded
      assert_equal 1, git.continued
      assert_empty result.resolved_files
    end
  ensure
    teardown_dirs(worktree, folder)
  end

  def test_empty_unmerged_continue_conflict_retries_next_conflict
    worktree, folder = make_worktree_and_folder
    File.write(File.join(worktree, "a.txt"), "resolved\n")
    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.commits_behind_value = 1
    git.rebase_onto_outcome = :conflict
    git.unmerged_files_sequence = [ [], [ "a.txt" ], [] ]
    git.rebase_continue_outcomes = [ :conflict, :ok ]

    stub_gitops!(git) do
      stub_spawn_agent(result_status: :ok) do
        result = Hive::Rebase.perform(task, base_cfg)
        assert result.succeeded
        assert_equal 2, git.continued
        assert_equal [ "a.txt" ], result.resolved_files
      end
    end
  ensure
    teardown_dirs(worktree, folder)
  end

  def test_empty_unmerged_continue_failure_aborts
    worktree, folder = make_worktree_and_folder
    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.commits_behind_value = 1
    git.rebase_onto_outcome = :conflict
    git.unmerged_files_sequence = [ [] ]
    git.rebase_continue_outcomes = [ :error ]

    stub_gitops!(git) do
      result = Hive::Rebase.perform(task, base_cfg)
      assert_equal :rebase_continue_failed, result.reason
      assert git.rebase_abort_called
      assert git.reset_hard_called
    end
  ensure
    teardown_dirs(worktree, folder)
  end

  def test_rebase_continue_failure_after_agent_resolution_aborts
    worktree, folder = make_worktree_and_folder
    File.write(File.join(worktree, "a.txt"), "resolved\n")
    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.commits_behind_value = 1
    git.rebase_onto_outcome = :conflict
    git.unmerged_files_sequence = [ [ "a.txt" ] ]
    git.rebase_continue_outcomes = [ :error ]

    stub_gitops!(git) do
      stub_spawn_agent(result_status: :ok) do
        result = Hive::Rebase.perform(task, base_cfg)
        assert_equal :rebase_continue_failed, result.reason
        assert_equal [ "a.txt" ], result.resolved_files
        assert git.rebase_abort_called
      end
    end
  ensure
    teardown_dirs(worktree, folder)
  end

  def test_render_conflict_prompt_falls_back_when_message_path_is_unreadable
    worktree, folder = make_worktree_and_folder
    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.define_singleton_method(:rebase_merge_message_path) do
      raise IOError, "message missing"
    end

    prompt = Hive::Rebase.send(:render_conflict_prompt, task, base_cfg, git, [ "a.txt" ])

    assert_match(/commit message unavailable/, prompt)
  ensure
    teardown_dirs(worktree, folder)
  end

  def test_has_conflict_markers_fails_closed_when_file_foreach_raises
    worktree, folder = make_worktree_and_folder
    path = File.join(worktree, "conflict.txt")
    File.write(path, "looks clean\n")
    original = File.singleton_class.instance_method(:foreach)

    File.define_singleton_method(:foreach) do |target, *_args, &_block|
      raise IOError, "read failed" if target == path

      original.bind_call(File, target)
    end

    assert Hive::Rebase.send(:has_conflict_markers?, path)
  ensure
    File.singleton_class.define_method(:foreach, original) if original
    teardown_dirs(worktree, folder)
  end

  def test_update_execute_base_head_cleans_temp_file_when_rename_fails
    worktree, folder = make_worktree_and_folder
    worktree_yml = File.join(folder, "worktree.yml")
    File.write(worktree_yml, YAML.dump({ "execute_base_head" => "oldsha" }))
    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.head_sha_value = "newsha"
    warnings = []
    original = File.singleton_class.instance_method(:rename)
    temp_path = nil

    File.define_singleton_method(:rename) do |from, to|
      if to == worktree_yml
        temp_path = from
        raise Errno::EACCES, "rename denied"
      end

      original.bind_call(File, from, to)
    end

    _out, err = capture_io do
      Hive::Rebase.send(:update_execute_base_head!, task, git, warnings)
    end

    refute_empty warnings
    assert_match(/execute_base_head not updated/, err)
    refute File.exist?(temp_path), "failed rewrite should clean the temporary YAML file"
  ensure
    File.singleton_class.define_method(:rename, original) if original
    teardown_dirs(worktree, folder)
  end

  def stub_stage_profile(profile)
    original = Hive::Stages::Base.singleton_class.instance_method(:stage_profile)
    Hive::Stages::Base.define_singleton_method(:stage_profile) do |_cfg, _stage_name|
      profile
    end
    yield
  ensure
    Hive::Stages::Base.singleton_class.define_method(:stage_profile, original)
  end
end
