require "test_helper"

# Structural complement to the behavior tests: new-idea policy belongs to
# Snapshot, while Update and BubbleModel may still depend on views for ordinary
# rendering. Submission behavior remains covered separately in BubbleModel and
# integration tests; source inspection alone is not evidence of preflight.
class TuiNewIdeaProjectResolutionBoundaryTest < Minitest::Test
  REPO_ROOT = File.expand_path("../../..", __dir__)

  def source(path)
    File.read(File.join(REPO_ROOT, path))
  end

  def test_direct_consumers_use_snapshot_authority_instead_of_raw_project_errors
    update = source("lib/hive/tui/update.rb")
    bubble_model = source("lib/hive/tui/bubble_model.rb")

    assert_includes update, "new_idea_admission"
    assert_includes update, "resolve_new_idea_entry"
    assert_includes bubble_model, "resolve_new_idea_project"

    [ update, bubble_model ].each do |consumer|
      refute_match(/\bproject\.error\b/, consumer)
      refute_match(/select\(&:error\)/, consumer)
    end
  end

  def test_submission_does_not_obtain_policy_from_prompt_view
    bubble_model = source("lib/hive/tui/bubble_model.rb")

    refute_includes bubble_model, "Views::NewIdeaPrompt.resolve_project_name"
    assert_includes bubble_model, "Views::NewIdeaPrompt.render",
      "ordinary rendering dependencies remain legitimate"
    assert_includes bubble_model, "Views::HelpOverlay",
      "the regression must not forbid unrelated view use"
  end

  def test_one_submit_preflight_precedes_plain_or_rich_validation
    bubble_model = source("lib/hive/tui/bubble_model.rb")
    submit = bubble_model[/      def submit_new_idea\n.*?(?=      def rich_new_idea_buffer\?)/m]
    rich = bubble_model[/      def submit_rich_new_idea\(.*?\n.*?(?=      def )/m]

    refute_nil submit
    refute_nil rich
    assert_equal 1, submit.scan(/resolve_new_idea_project/).size
    assert_operator submit.index("resolve_new_idea_project"), :<,
      submit.index("rich_new_idea_buffer?")
    refute_includes rich, "resolve_new_idea_project"
  end
end
