require "test_helper"
require "hive/stages/finalize"
require "hive/stages/base"

class StagesFinalizePromptTest < Minitest::Test
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
