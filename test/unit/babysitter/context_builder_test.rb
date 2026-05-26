require "test_helper"
require "hive/babysitter/context_builder"

class BabysitterContextBuilderTest < Minitest::Test
  include HiveTestHelper

  def test_build_returns_prompt_ready_context
    pr = { "number" => 42, "baseRefName" => "main", "headRefName" => "feat" }
    status = { "mergeable" => "CONFLICTING", "statusCheckRollup" => [] }

    with_replaced_singleton_method(Hive::Gh, :pr_status_rollup, ->(_path, _number, **_kwargs) { status }) do
      with_replaced_singleton_method(Hive::Gh, :failing_jobs_with_logs, ->(_path, _rollup, **_kwargs) { [ { "name" => "unit", "log" => "fail" } ] }) do
        with_replaced_singleton_method(Hive::Gh, :pr_diff_stat, ->(_path, _base, _head, **_kwargs) { " lib/a.rb | 2 +-\n" }) do
          divergence = { "base_sha" => "abc123", "merge_base" => "def456", "ahead" => 3, "behind" => 1 }
          with_replaced_singleton_method(Hive::Gh, :pr_base_divergence, ->(_path, _base, **_kwargs) { divergence }) do
            ctx = Hive::Babysitter::ContextBuilder.build(worktree_path: "/tmp/wt", pr: pr, cfg: {})
            assert_equal "CONFLICTING", ctx.mergeable_state
            assert_equal "main", ctx.base_ref
            assert_equal "feat", ctx.head_ref
            assert_equal [ { "name" => "unit", "log" => "fail" } ], ctx.failing_jobs
            assert_match(/lib\/a\.rb/, ctx.diff_stat)
            assert_equal "abc123", ctx.base_sha
            assert_equal "def456", ctx.merge_base
            assert_equal 3, ctx.ahead
            assert_equal 1, ctx.behind
          end
        end
      end
    end
  end
end
