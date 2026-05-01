require "test_helper"
require "hive/tui/model"
require "hive/tui/snapshot"
require "hive/tui/views/new_idea_prompt"

# Hive::Tui::Views::NewIdeaPrompt is the bottom-strip widget shown in
# `:new_idea` mode (v2). Pure read of the model; tests pin label
# content and project resolution semantics. ANSI is stripped in
# non-tty so styling is verified by manual dogfood.
class HiveTuiViewsNewIdeaPromptTest < Minitest::Test
  include HiveTestHelper

  def make_snapshot(names)
    Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-01T00:00:00Z",
      "projects" => names.map { |n| { "name" => n, "tasks" => [] } }
    )
  end

  def test_renders_prompt_label_with_resolved_project
    model = Hive::Tui::Model.initial.with(
      mode: :new_idea, snapshot: make_snapshot(%w[hive seyarabata]),
      scope: 0, new_idea_buffer: "rss feeds"
    )
    out = Hive::Tui::Views::NewIdeaPrompt.render(model)
    assert_includes out, "New idea (project="
    assert_includes out, "hive", "★ All scope must resolve to first registered project"
    assert_includes out, "rss feeds", "buffer text must surface verbatim"
  end

  def test_label_indicates_star_fallback_when_scope_zero
    model = Hive::Tui::Model.initial.with(
      mode: :new_idea, snapshot: make_snapshot(%w[hive seyarabata]),
      scope: 0
    )
    out = Hive::Tui::Views::NewIdeaPrompt.render(model)
    assert_includes out, "★→hive",
                    "scope=0 should be labeled with ★→<first> so the operator sees the fallback"
  end

  def test_label_uses_explicit_project_when_scope_n
    model = Hive::Tui::Model.initial.with(
      mode: :new_idea, snapshot: make_snapshot(%w[hive seyarabata]),
      scope: 2
    )
    out = Hive::Tui::Views::NewIdeaPrompt.render(model)
    assert_includes out, "seyarabata"
    refute_includes out, "★→", "explicit scope must NOT carry the ★→ fallback prefix"
  end

  def test_label_handles_nil_snapshot
    model = Hive::Tui::Model.initial.with(mode: :new_idea, snapshot: nil)
    out = Hive::Tui::Views::NewIdeaPrompt.render(model)
    assert_includes out, "(no projects)"
  end

  def test_label_handles_empty_projects
    model = Hive::Tui::Model.initial.with(
      mode: :new_idea, snapshot: make_snapshot([]), scope: 0
    )
    out = Hive::Tui::Views::NewIdeaPrompt.render(model)
    assert_includes out, "(no projects)"
  end

  def test_resolve_project_name_returns_nil_when_no_projects
    model = Hive::Tui::Model.initial.with(snapshot: nil)
    assert_nil Hive::Tui::Views::NewIdeaPrompt.resolve_project_name(model)
  end

  def test_resolve_project_name_returns_first_project_when_scope_zero
    model = Hive::Tui::Model.initial.with(
      snapshot: make_snapshot(%w[alpha beta]), scope: 0
    )
    assert_equal "alpha", Hive::Tui::Views::NewIdeaPrompt.resolve_project_name(model)
  end

  def test_resolve_project_name_returns_nth_project_when_scope_n
    model = Hive::Tui::Model.initial.with(
      snapshot: make_snapshot(%w[alpha beta gamma]), scope: 2
    )
    assert_equal "beta", Hive::Tui::Views::NewIdeaPrompt.resolve_project_name(model)
  end

  def test_resolve_project_name_returns_nil_when_scope_out_of_range
    model = Hive::Tui::Model.initial.with(
      snapshot: make_snapshot(%w[alpha]), scope: 99
    )
    assert_nil Hive::Tui::Views::NewIdeaPrompt.resolve_project_name(model)
  end
end
