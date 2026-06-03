require "test_helper"
require "hive/babysitter/gh_ops"

class BabysitterGhOpsTest < Minitest::Test
  include HiveTestHelper

  def test_force_push_uses_force_with_lease_to_head_ref
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
end
