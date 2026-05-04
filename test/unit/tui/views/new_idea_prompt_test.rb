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

  # ---- project_label decoration logic ----
  # The render path covers these transitively, but a direct test pins
  # the ★→ fallback marker, the explicit-scope path, and the empty-
  # snapshot placeholder so a regression in the decoration logic
  # surfaces independently of the prompt layout.

  def test_project_label_marks_star_fallback_with_arrow_prefix
    model = Hive::Tui::Model.initial.with(
      snapshot: make_snapshot(%w[hive seyarabata]), scope: 0
    )
    assert_equal "★→hive", Hive::Tui::Views::NewIdeaPrompt.project_label(model),
                 "scope=0 fallback must be visually distinguished from explicit selection"
  end

  def test_project_label_returns_plain_name_when_scope_n
    model = Hive::Tui::Model.initial.with(
      snapshot: make_snapshot(%w[hive seyarabata]), scope: 2
    )
    assert_equal "seyarabata", Hive::Tui::Views::NewIdeaPrompt.project_label(model),
                 "explicit scope must NOT carry the ★→ fallback marker"
  end

  def test_project_label_handles_no_projects_gracefully
    model = Hive::Tui::Model.initial.with(snapshot: nil)
    assert_equal "(no projects)", Hive::Tui::Views::NewIdeaPrompt.project_label(model)
  end

  # ---- Width clamping (sliding-window for long buffers) ----
  # Without this, a long title like "I want to collect and process
  # bookmarks from my twitter account..." overflows the terminal —
  # the rendered line just runs off the right edge instead of
  # scrolling. Operator-visible regression on first dogfood.

  def test_long_buffer_slides_to_show_tail_within_cols
    long = ("a" * 60) + ("z" * 60) # 120 chars
    model = Hive::Tui::Model.initial.with(
      mode: :new_idea, snapshot: make_snapshot(%w[hive]),
      scope: 0, new_idea_buffer: long, cols: 50
    )
    out = Hive::Tui::Views::NewIdeaPrompt.render(model)
    refute_includes out, ("a" * 60),
                    "leading 60 a's must NOT render at cols=50; sliding-window keeps the tail"
    assert_includes out, "zzzz",
                    "trailing portion of buffer must remain visible (cursor stays at right edge)"
  end

  def test_buffer_within_cols_renders_in_full
    model = Hive::Tui::Model.initial.with(
      mode: :new_idea, snapshot: make_snapshot(%w[hive]),
      scope: 0, new_idea_buffer: "rss feeds", cols: 100
    )
    out = Hive::Tui::Views::NewIdeaPrompt.render(model)
    assert_includes out, "rss feeds", "short buffer must render verbatim"
  end

  def test_explicit_width_kwarg_clamps_independently_of_cols
    model = Hive::Tui::Model.initial.with(
      mode: :new_idea, snapshot: make_snapshot(%w[hive]),
      scope: 0, new_idea_buffer: "x" * 80, cols: 200
    )
    out = Hive::Tui::Views::NewIdeaPrompt.render(model, width: 30)
    refute_match(/x{80}/, out, "width: kwarg must clamp regardless of model.cols")
  end
end
