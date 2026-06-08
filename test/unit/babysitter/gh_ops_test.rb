require "test_helper"
require "hive/babysitter/gh_ops"

class BabysitterGhOpsTest < Minitest::Test
  include HiveTestHelper

  def test_force_push_uses_bare_force_with_lease_without_expected_oid
    status = Hive::Gh::CommandStatus.new(exitstatus: 0)
    captured = nil
    with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **kwargs|
      captured = [ cmd, kwargs ]
      [ "ok", "", status ]
    }) do
      result = Hive::Babysitter::GhOps.force_push_with_lease("/tmp/wt", "feature", cfg: {}, dry_run: false)
      assert result.success?
    end

    assert_equal %w[git push --force-with-lease origin HEAD:feature], captured.first
    assert_equal "/tmp/wt", captured.last.fetch(:chdir)
  end

  def test_force_push_uses_explicit_lease_when_expected_oid_present
    status = Hive::Gh::CommandStatus.new(exitstatus: 0)
    captured = nil
    with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **kwargs|
      captured = [ cmd, kwargs ]
      [ "ok", "", status ]
    }) do
      result = Hive::Babysitter::GhOps.force_push_with_lease("/tmp/wt", "feature", cfg: {}, dry_run: false, expected_oid: "abc123")
      assert result.success?
    end

    assert_equal %w[git push --force-with-lease=feature:abc123 origin HEAD:feature], captured.first
    assert_equal "/tmp/wt", captured.last.fetch(:chdir)
  end

  def test_force_push_treats_empty_expected_oid_as_bare_lease
    status = Hive::Gh::CommandStatus.new(exitstatus: 0)
    captured = nil
    with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **_kwargs|
      captured = cmd
      [ "ok", "", status ]
    }) do
      result = Hive::Babysitter::GhOps.force_push_with_lease("/tmp/wt", "feature", cfg: {}, dry_run: false, expected_oid: "")
      assert result.success?
    end

    assert_equal %w[git push --force-with-lease origin HEAD:feature], captured
  end

  def test_force_push_dry_run_skips_git
    called = false
    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_cmd, **_kwargs) { called = true }) do
      result = Hive::Babysitter::GhOps.force_push_with_lease("/tmp/wt", "feature", cfg: {}, dry_run: true, expected_oid: "abc123")
      assert result.success?
    end
    refute called
  end

  def test_add_label_noops_when_label_already_present
    status = Hive::Gh::CommandStatus.new(exitstatus: 0)
    calls = []
    with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **_kwargs|
      calls << cmd
      [ '{"labels":[{"name":"babysitter/needs-human"}]}', "", status ]
    }) do
      result = Hive::Babysitter::GhOps.add_label("/tmp/wt", 42, "babysitter/needs-human", cfg: {}, dry_run: false)
      assert result.success?
      assert_equal "already labelled", result.stdout
    end
    assert_equal 1, calls.size
  end

  def test_post_pr_comment_dry_run_skips_gh
    called = false
    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_cmd, **_kwargs) { called = true }) do
      result = Hive::Babysitter::GhOps.post_pr_comment("/tmp/wt", 42, "body", cfg: {}, dry_run: true)
      assert result.success?
    end
    refute called
  end

  def test_rebase_onto_base_fetches_then_rebases_on_success
    ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
    commands = []
    with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **_kwargs|
      commands << cmd
      [ "ok", "", ok ]
    }) do
      result = Hive::Babysitter::GhOps.rebase_onto_base("/tmp/wt", "main", cfg: {}, dry_run: false)
      assert result.success?
      refute result.conflict?
    end

    assert_equal %w[git fetch origin main], commands[0]
    assert_equal %w[git rebase origin/main], commands[1]
    assert_equal 2, commands.size, "no abort on a clean rebase"
  end

  def test_rebase_onto_base_aborts_and_reports_conflict_on_failure
    ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
    bad = Hive::Gh::CommandStatus.new(exitstatus: 1)
    commands = []
    with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **_kwargs|
      commands << cmd
      status = cmd[0, 2] == %w[git rebase] && cmd[2] != "--abort" ? bad : ok
      [ "out", "err", status ]
    }) do
      result = Hive::Babysitter::GhOps.rebase_onto_base("/tmp/wt", "main", cfg: {}, dry_run: false)
      assert result.conflict?
      refute result.success?
    end

    assert_equal %w[git rebase --abort], commands.last
  end

  def test_rebase_onto_base_reports_failure_when_fetch_fails
    bad = Hive::Gh::CommandStatus.new(exitstatus: 1)
    commands = []
    with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*cmd, **_kwargs|
      commands << cmd
      [ "out", "fetch boom", bad ]
    }) do
      result = Hive::Babysitter::GhOps.rebase_onto_base("/tmp/wt", "main", cfg: {}, dry_run: false)
      refute result.success?
      refute result.conflict?
      assert_equal :failure, result.status
    end

    assert_equal 1, commands.size, "stops after a failed fetch"
  end

  def test_rebase_onto_base_dry_run_skips_git
    called = false
    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*_cmd, **_kwargs) { called = true }) do
      result = Hive::Babysitter::GhOps.rebase_onto_base("/tmp/wt", "main", cfg: {}, dry_run: true)
      assert result.success?
    end
    refute called
  end
end
