require "test_helper"
require "hive/stages/finalize"
require "hive/stages/base"

class StagesFinalizePromptTest < Minitest::Test
  include HiveTestHelper

  def test_review_summary_counts_pass_100_and_uses_latest_numeric_triage_bias
    with_tmp_dir do |dir|
      task = Struct.new(:reviews_dir).new(dir)
      File.write(File.join(dir, "codex-100.md"), "clean\n")
      File.write(File.join(dir, "triage-99.md"), "bias: safetyist\n")
      File.write(File.join(dir, "triage-0100.md"), "bias: courageous\n")
      File.write(File.join(dir, "triage-other-050.md"), "bias: wrong\n")

      summary = Hive::Stages::Finalize.review_summary(task)

      assert_includes summary, "Review passes: 100"
      assert_includes summary, "Triage bias: courageous"
    end
  end

  def test_review_summaries_and_escalations_order_extended_passes_numerically
    with_tmp_dir do |dir|
      task = Struct.new(:reviews_dir).new(dir)
      File.write(File.join(dir, "escalations-99.md"), "- [ ] older question\n")
      File.write(File.join(dir, "escalations-100.md"), "- [ ] newer question\n")
      File.write(File.join(dir, "escalations-other-050.md"), "- [ ] unrelated question\n")

      escalations = Hive::Stages::Finalize.open_escalations(task)
      summary = Hive::Stages::Finalize.build_reviews_summary(task)

      assert_operator escalations.index("older question"), :<, escalations.index("newer question")
      refute_includes escalations, "unrelated question"
      assert_operator summary.index("### escalations-99.md"), :<, summary.index("### escalations-100.md")
    end
  end

  def test_finalize_prompt_includes_demo_links_instruction
    prompt = Hive::Stages::Base.render(
      "finalize_prompt.md.erb",
      Hive::Stages::Base::TemplateBindings.new(
        project_name: "demo",
        task_folder: "/tmp/task",
        worktree_path: "/tmp/worktree",
        slug: "demo-260618-abcd",
        branch: "demo-260618-abcd",
        pr_url: "https://github.com/o/r/pull/1",
        plan_text: "plan",
        reviews_summary: "reviews",
        user_supplied_tag: "user-data"
      )
    )

    assert_includes prompt, "media/manifest.json"
    assert_includes prompt, "screenote_url"
    assert_includes prompt, "## Demo"
    assert_includes prompt, "Preserve or re-add"
  end
end
