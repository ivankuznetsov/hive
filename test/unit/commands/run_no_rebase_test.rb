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

  FakeTask = Struct.new(:slug, :folder, :worktree_path, :stage_name, :project_root)

  def fake_task
    FakeTask.new("demo-260514-bbbb", "/tmp/folder", "/tmp/wt", "4-execute", "/tmp/proj")
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
