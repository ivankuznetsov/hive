# frozen_string_literal: true

require "test_helper"

# Branch-only reviewer prompts must diff against the merge-base of the
# default branch and HEAD (`git diff <base>...HEAD`), never the two-dot
# tip-to-tip range (`git diff <base>..HEAD`). With two-dot, commits that
# landed on the default branch after the feature branch was cut appear in
# the diff as their inverse, so reviewers see unrelated "changes" that the
# branch never introduced. The three-dot merge-base range shows only what
# the branch itself added.
#
# Regression for patrol finding
# architecture-templates-part-8-20260917T000739Z-a272c010-1: the Grok,
# pr-review-toolkit, Claude, Codex CE, and legacy execute-review templates
# used two-dot notation while the Codex native reviewer already used
# three-dot.
class ReviewerDiffRangeTest < Minitest::Test
  TEMPLATES = %w[
    reviewer_claude_ce_code_review.md.erb
    reviewer_codex_ce_code_review.md.erb
    reviewer_codex_native_review.md.erb
    reviewer_grok_ce_code_review.md.erb
    reviewer_pr_review_toolkit.md.erb
    review_prompt.md.erb
  ].freeze

  TEST_DIR = File.expand_path(__dir__)

  def test_reviewer_templates_diff_against_merge_base_not_tips
    TEMPLATES.each do |name|
      source = File.read(File.join(TEST_DIR, "../../../templates", name))

      refute_includes source, "git diff <%= default_branch %>..HEAD",
                      "#{name} must not use the two-dot tip-to-tip range; " \
                      "it includes inverse changes from the default branch"
      assert_includes source, "git diff <%= default_branch %>...HEAD",
                      "#{name} must review the three-dot merge-base diff"
    end
  end
end
