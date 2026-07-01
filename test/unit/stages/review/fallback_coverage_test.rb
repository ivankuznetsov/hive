require "test_helper"
require "hive/stages/review"

class ReviewFallbackCoverageTest < Minitest::Test
  include HiveTestHelper

  Context = Hive::Stages::Review::Context
  Review = Hive::Stages::Review

  def test_fix_completion_artifact_probe_fails_closed_on_filesystem_error
    with_tmp_dir do |dir|
      ctx = Context.new(worktree_path: dir, task_folder: dir, default_branch: "main", pass: 1)

      with_replaced_singleton_method(File, :exist?, ->(_path) { raise Errno::EACCES }) do
        assert_equal false, Review.fix_completion_fallback_artifacts_present?(ctx)
      end
    end
  end

  def test_no_change_scan_skips_orchestrator_files_and_fails_closed_on_read_error
    with_tmp_dir do |dir|
      reviews_dir = File.join(dir, "reviews")
      FileUtils.mkdir_p(reviews_dir)
      ctx = Context.new(worktree_path: dir, task_folder: dir, default_branch: "main", pass: 1)

      File.write(File.join(reviews_dir, "errors-01.md"), "- [x] RESOLVED/NO-FIX: infra failure\n")
      assert_equal false, Review.no_change_evidence_present?(ctx)

      File.write(File.join(reviews_dir, "stub-reviewer-01.md"), "- [x] RESOLVED/NO-FIX: already correct\n")
      with_replaced_singleton_method(File, :readlines, ->(_path) { raise Errno::EACCES }) do
        assert_equal false, Review.no_change_evidence_present?(ctx)
      end
    end
  end

  def test_completion_fallback_audit_emit_failure_blocks_suppression
    with_tmp_dir do |dir|
      task = Struct.new(:folder, :slug, :stage_index, :stage_name).new(dir, "slug-260630-abcd", 6, "review")
      ctx = Context.new(worktree_path: dir, task_folder: dir, default_branch: "main", pass: 1)

      with_replaced_singleton_method(Hive::Events, :emit, ->(**_kwargs) { raise JSON::GeneratorError, "bad json" }) do
        assert_equal false, Review.emit_fix_completion_fallback(
          task,
          ctx,
          { session_alive: true },
          { artifacts_present: true, commit_or_no_change: true, no_unresolved_escalation: true },
          { missing: [] },
          before_fix_head: "a" * 40,
          after_fix_head: "b" * 40,
          worktree_status: :clean,
          no_change: false
        )
      end
    end
  end

  def test_commit_evidence_reports_none_when_no_basis_holds
    with_tmp_dir do |dir|
      ctx = Context.new(worktree_path: dir, task_folder: dir, default_branch: "main", pass: 1)

      assert_equal "none", Review.fix_completion_commit_evidence(
        ctx,
        before_fix_head: "a" * 40,
        after_fix_head: "a" * 40,
        worktree_status: :clean,
        no_change: false
      )
    end
  end
end
