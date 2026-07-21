require "test_helper"
require "hive/commands/run"
require "hive/rebase"

# Unit-level coverage for the `--no-rebase` flag plumbed in PR #69
# AGENT-O2. The full Commands::Run.call flow needs a project + lock
# + stage runner, which the integration suite already exercises.
# Here we pin only the narrow contract that matters: when @no_rebase
# is true, perform_rebase returns Result.skipped(:cli_override) and
# never invokes Hive::Rebase.perform.
class HiveCommandsRunNoRebaseTest < Minitest::Test
  include HiveTestHelper

  FakeWorkflow = Struct.new(:draft_pr_handoff?)
  FakeTask = Struct.new(:slug, :folder, :worktree_path, :stage_name, :project_root, :workflow)

  def fake_task(draft_pr_handoff: false)
    FakeTask.new(
      "demo-260514-bbbb", "/tmp/folder", "/tmp/wt", "4-execute", "/tmp/proj",
      FakeWorkflow.new(draft_pr_handoff)
    )
  end

  def test_no_rebase_short_circuits_with_cli_override_reason
    cmd = Hive::Commands::Run.new("demo-260514-bbbb", no_rebase: true)
    # Sanity: if perform_rebase ever called Hive::Rebase.perform it
    # would try to spin up a real GitOps against /tmp/wt and blow up;
    # stubbing it to raise pins the "never called" assertion.
    original = Hive::Rebase.singleton_class.instance_method(:perform)
    Hive::Rebase.define_singleton_method(:perform) do |_t, _c|
      raise "Hive::Rebase.perform must not run when --no-rebase is set"
    end
    begin
      _out, err = capture_io { @result = cmd.send(:perform_rebase, fake_task, { "rebase" => { "enabled" => true } }) }
      assert_equal :cli_override, @result.reason
      refute @result.attempted, "cli_override is a skip-state — attempted=false"
      # log_rebase_outcome is a no-op for skipped results (attempted=false);
      # this pins that the flag stays quiet rather than spamming stderr.
      assert_equal "", err
      _out  # silence warning
    ensure
      Hive::Rebase.singleton_class.define_method(:perform, original)
    end
  end

  def test_pre_existing_rebase_warning_fires_despite_attempted_false
    # P2: pre_existing_rebase is a skip-state (attempted=false) but
    # one operators MUST see: a stale rebase-merge directory means a
    # prior run aborted mid-flight and the worktree needs `git rebase
    # --abort`. The original log_rebase_outcome returned early on
    # `return unless result.attempted`, making the recovery warning
    # unreachable.
    cmd = Hive::Commands::Run.new("demo-260514-bbbb")
    result = Hive::Rebase::Result.skipped(:pre_existing_rebase)
    _, err = capture_io { cmd.send(:log_rebase_outcome, fake_task, result) }
    assert_match(/pre_existing_rebase/, err)
    assert_match(/rebase --abort/, err)
  end

  def test_managed_draft_pr_handoff_never_runs_auto_rebase
    cmd = Hive::Commands::Run.new("demo-260514-bbbb")
    original = Hive::Rebase.singleton_class.instance_method(:perform)
    Hive::Rebase.define_singleton_method(:perform) do |*_args|
      raise "Hive::Rebase.perform must not rewrite a managed handoff worktree"
    end
    begin
      result = cmd.send(:perform_rebase, fake_task(draft_pr_handoff: true), {})
      assert_equal :managed_draft_pr_handoff, result.reason
      refute result.attempted
    ensure
      Hive::Rebase.singleton_class.define_method(:perform, original)
    end
  end

  def test_other_skipped_states_stay_quiet
    # Disabled / no_worktree / cli_override are intentionally silent
    # — they are expected operating modes, not failures. P2 fix
    # mustn't make every skip state spammy.
    cmd = Hive::Commands::Run.new("demo-260514-bbbb")
    [ :disabled, :no_worktree, :cli_override, :managed_draft_pr_handoff,
      :dirty_worktree, :detached_head ].each do |reason|
      result = Hive::Rebase::Result.skipped(reason)
      _, err = capture_io { cmd.send(:log_rebase_outcome, fake_task, result) }
      assert_equal "", err, "reason=#{reason} must stay silent (still skip-state, attempted=false)"
    end
  end

  def test_no_rebase_default_runs_rebase_perform
    cmd = Hive::Commands::Run.new("demo-260514-bbbb")  # no_rebase: false default
    captured_call = false
    original = Hive::Rebase.singleton_class.instance_method(:perform)
    Hive::Rebase.define_singleton_method(:perform) do |_t, _c|
      captured_call = true
      Hive::Rebase::Result.disabled  # short-circuit with a valid Result
    end
    begin
      capture_io { cmd.send(:perform_rebase, fake_task, { "rebase" => { "enabled" => true } }) }
      assert captured_call, "default path must invoke Hive::Rebase.perform"
    ensure
      Hive::Rebase.singleton_class.define_method(:perform, original)
    end
  end
end
