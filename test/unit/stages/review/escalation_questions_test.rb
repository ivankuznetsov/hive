require "test_helper"
require "hive/reviewers"
require "hive/stages/review"

class ReviewEscalationQuestionsTest < Minitest::Test
  include HiveTestHelper

  def make_ctx(worktree, task_folder, pass: 1)
    Hive::Reviewers::Context.new(
      worktree_path: worktree,
      task_folder: task_folder,
      default_branch: "main",
      pass: pass
    )
  end

  def test_count_escalations_counts_unanswered_q_and_a_items
    with_tmp_dir do |dir|
      task_folder = File.join(dir, ".hive-state", "stages", "5-review", "demo")
      reviews_dir = File.join(task_folder, "reviews")
      FileUtils.mkdir_p(reviews_dir)
      File.write(File.join(reviews_dir, "escalations-01.md"), <<~MD)
        # Escalations for pass 01

        ## Round 1

        ### Q1. Which scheduler should be used?
        Source: codex-ce-code-review-01.md
        ### A1.
        Use systemd-user on Linux and launchd on macOS.

        ### Q2. Should the public API be renamed?
        Source: claude-ce-code-review-01.md
        ### A2.
      MD

      ctx = make_ctx(dir, task_folder)
      assert_equal 1, Hive::Stages::Review.count_escalations(ctx)
    end
  end

  def test_collect_accepted_findings_includes_auto_fix_and_answered_escalations_only
    with_tmp_dir do |dir|
      task_folder = File.join(dir, ".hive-state", "stages", "5-review", "demo")
      reviews_dir = File.join(task_folder, "reviews")
      FileUtils.mkdir_p(reviews_dir)
      File.write(File.join(reviews_dir, "codex-ce-code-review-01.md"), <<~MD)
        ## Findings
        - [x] AUTO-FIX: rename the confusing helper <!-- triage: obvious clarity -->
        - [x] RESOLVED/NO-FIX: missing browser test <!-- triage: plan defers browser coverage -->
        - [x] legacy accepted finding without a label
      MD
      File.write(File.join(reviews_dir, "escalations-01.md"), <<~MD)
        # Escalations for pass 01

        ## Round 1

        ### Q1. Which config key should the fix use?
        Source: claude-ce-code-review-01.md
        ### A1.
        Use execute.agent; develop is only the CLI verb.

        ### Q2. Should we add a new abstraction?
        Source: codex-ce-code-review-01.md
        ### A2.
      MD

      ctx = make_ctx(dir, task_folder)
      accepted = Hive::Stages::Review.collect_accepted_findings(ctx)

      assert_includes accepted, "AUTO-FIX: rename the confusing helper"
      assert_includes accepted, "legacy accepted finding without a label"
      assert_includes accepted, "USER-ANSWERED ESCALATION Q1"
      assert_includes accepted, "Use execute.agent"
      refute_includes accepted, "RESOLVED/NO-FIX"
      refute_includes accepted, "Should we add a new abstraction?"
    end
  end

  def test_collect_accepted_findings_preserves_legacy_checked_escalations
    with_tmp_dir do |dir|
      task_folder = File.join(dir, ".hive-state", "stages", "5-review", "demo")
      reviews_dir = File.join(task_folder, "reviews")
      FileUtils.mkdir_p(reviews_dir)
      File.write(File.join(reviews_dir, "codex-ce-code-review-01.md"), <<~MD)
        ## Findings
        - [ ] reviewer finding mirrored into legacy escalations
      MD
      File.write(File.join(reviews_dir, "escalations-01.md"), <<~MD)
        # Escalations for pass 01

        ## codex-ce-code-review-01.md

        - [x] apply the requested legacy escalation fix
        - [ ] still needs a user decision
      MD

      ctx = make_ctx(dir, task_folder)
      accepted = Hive::Stages::Review.collect_accepted_findings(ctx)

      assert_includes accepted, "Accepted legacy escalations from escalations-01.md"
      assert_includes accepted, "apply the requested legacy escalation fix"
      assert_equal 1, Hive::Stages::Review.count_escalations(ctx)
    end
  end
end
