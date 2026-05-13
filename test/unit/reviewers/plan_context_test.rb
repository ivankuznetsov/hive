require "test_helper"
require "hive/reviewers/plan_context"

# Hive::Reviewers::PlanContext.render(task_folder) builds the
# scope-aware prompt section embedded into every reviewer spawn.
# These tests pin the four shapes:
#   * present plan.md → instructional block + plan content wrapped
#     in BEGIN/END markers
#   * absent plan.md → fixed absent-note string
#   * empty plan.md → absent-note (empty file is informationally
#     equivalent to no plan)
#   * unreadable plan.md (EACCES / EIO) → absent-note (best-effort
#     read; reviewer spawn must not abort on plan I/O failure)
class HiveReviewersPlanContextTest < Minitest::Test
  include HiveTestHelper

  def test_render_present_plan_includes_instructional_block_and_content
    with_tmp_dir do |dir|
      plan_path = File.join(dir, "plan.md")
      File.write(plan_path, "# Plan\n\n## Goals\n- G1. Build the thing.\n\n## Scope Boundaries\n- N1. Not the other thing.\n")

      out = Hive::Reviewers::PlanContext.render(dir)

      assert_match(/Plan context \(authoritative on scope\)/, out,
                   "rendered section must lead with the authoritative-on-scope header")
      assert_match(/BEGIN plan\.md/, out)
      assert_match(/END plan\.md/, out)
      assert_includes out, "G1. Build the thing.",
                      "plan content must appear inline between the BEGIN/END markers"
      assert_includes out, "N1. Not the other thing."
      assert_match(/drop the finding/, out,
                   "the anti-finding rule must appear in the instructional block")
    end
  end

  def test_render_absent_plan_returns_absent_note
    with_tmp_dir do |dir|
      out = Hive::Reviewers::PlanContext.render(dir)

      assert_equal Hive::Reviewers::PlanContext::ABSENT_NOTE, out
      assert_match(/no plan\.md found/, out)
      refute_match(/BEGIN plan\.md/, out,
                   "no BEGIN/END marker should appear when plan.md is absent")
    end
  end

  def test_render_empty_plan_treated_as_absent
    # A 0-byte plan.md carries no scope information; rather than
    # embedding an empty BEGIN/END block (visually misleading), the
    # renderer falls back to the absent-note. Whitespace-only files
    # take the same path because `content.strip.empty?` catches them.
    with_tmp_dir do |dir|
      File.write(File.join(dir, "plan.md"), "")
      out_empty = Hive::Reviewers::PlanContext.render(dir)
      assert_equal Hive::Reviewers::PlanContext::ABSENT_NOTE, out_empty

      File.write(File.join(dir, "plan.md"), "   \n\n  ")
      out_whitespace = Hive::Reviewers::PlanContext.render(dir)
      assert_equal Hive::Reviewers::PlanContext::ABSENT_NOTE, out_whitespace,
                   "whitespace-only plan.md must also fall back to absent-note"
    end
  end

  def test_render_unreadable_plan_falls_back_to_absent_note
    # Simulate a permission error reading plan.md by chmod'ing it
    # 0000 mid-test. The renderer must not abort the reviewer spawn
    # — it falls back to the absent-note. Skip on platforms where
    # 0000 is bypassed (root, some CI containers) so the test
    # remains meaningful instead of silently passing.
    skip "running as root; 0000 chmod is bypassed" if Process.uid.zero?
    with_tmp_dir do |dir|
      plan_path = File.join(dir, "plan.md")
      File.write(plan_path, "# Plan\n")
      File.chmod(0o000, plan_path)
      begin
        out = Hive::Reviewers::PlanContext.render(dir)
        assert_equal Hive::Reviewers::PlanContext::ABSENT_NOTE, out,
                     "unreadable plan.md must fall back to absent-note, not raise"
      ensure
        File.chmod(0o644, plan_path)
      end
    end
  end

  def test_render_strips_trailing_whitespace_from_plan_content
    # Plan content's trailing newlines/whitespace could double up
    # against the closing `--- END plan.md ---` marker, creating an
    # ugly blank line. The renderer rstrips the content so the
    # closing marker lands cleanly.
    with_tmp_dir do |dir|
      File.write(File.join(dir, "plan.md"), "# Plan\n\nbody\n\n\n\n")
      out = Hive::Reviewers::PlanContext.render(dir)

      refute_match(/body\n\n\n--- END plan\.md ---/, out,
                   "trailing whitespace must be stripped before the END marker")
      assert_match(/body\n--- END plan\.md ---/, out)
    end
  end
end
