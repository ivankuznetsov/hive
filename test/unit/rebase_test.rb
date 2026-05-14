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
                  :project_root

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

  # ---- Failure paths (abort + reset --hard) ----

  def test_agent_failure_aborts_and_returns_failed
    worktree, folder = make_worktree_and_folder
    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.commits_behind_value = 1
    git.rebase_onto_outcome = :conflict
    git.unmerged_files_sequence = [ [ "a.txt" ] ]

    stub_gitops!(git) do
      stub_spawn_agent(result_status: :error, error_message: "synthetic agent fail") do
        result = Hive::Rebase.perform(task, base_cfg)
        refute result.succeeded
        assert_equal :agent_failed, result.reason
        assert git.rebase_abort_called
        assert git.reset_hard_called
      end
    end
  ensure
    teardown_dirs(worktree, folder)
  end

  def test_protected_files_in_conflict_aborts_without_dispatching
    worktree, folder = make_worktree_and_folder
    task = make_task(worktree: worktree, folder: folder)
    git = FakeGitOps.new(worktree)
    git.commits_behind_value = 1
    git.rebase_onto_outcome = :conflict
    git.unmerged_files_sequence = [ [ "plan.md", "a.txt" ] ]

    dispatched = false
    original = Hive::Stages::Base.singleton_class.instance_method(:spawn_agent)
    Hive::Stages::Base.define_singleton_method(:spawn_agent) do |*_args, **_kwargs|
      dispatched = true
      { status: :ok }
    end
    begin
      stub_gitops!(git) do
        result = Hive::Rebase.perform(task, base_cfg)
        assert_equal :protected_files_in_conflict, result.reason
        refute result.succeeded
        refute dispatched, "agent must NOT be dispatched when protected files are in conflict"
        assert git.rebase_abort_called
        assert git.reset_hard_called
      end
    ensure
      Hive::Stages::Base.singleton_class.define_method(:spawn_agent, original)
    end
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
end
