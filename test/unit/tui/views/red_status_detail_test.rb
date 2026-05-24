require "test_helper"
require "hive/tui/model"
require "hive/tui/snapshot"
require "hive/tui/views/red_status_detail"

class HiveTuiViewsRedStatusDetailTest < Minitest::Test
  def row(diagnostic: nil, action_key: "recover_review", stage: "6-review",
          marker: "review_error", attrs: { "phase" => "fix", "pass" => "2" },
          folder: "/tmp/demo/.hive-state/stages/6-review/red-task")
    Hive::Tui::Snapshot::Row.new(
      project_name: "alpha", stage: stage, slug: "red-task", folder: folder,
      state_file: File.join(folder, "task.md"), marker: marker,
      attrs: attrs, mtime: nil, age_seconds: 0,
      claude_pid: nil, claude_pid_alive: nil,
      action_key: action_key, action_label: "Needs recovery",
      suggested_command: nil, next_action: nil, diagnostic: diagnostic
    )
  end

  # The agent label is cached on RedStatusDetailState at open time
  # (BubbleModel#resolve_agent_label populates it before delegating to
  # Update.apply), so the view never does per-frame disk I/O. Tests
  # pass the precomputed label directly, matching how production opens
  # the screen.
  def model_for(row, cols: 100, rows: 24, agent_label: "codex")
    state = Hive::Tui::Model::RedStatusDetailState.new(
      row: row,
      agent_label: agent_label
    )
    Hive::Tui::Model.initial.with(mode: :red_status_detail, red_status_detail_state: state, cols: cols, rows: rows)
  end

  def test_renders_user_facing_summary_with_two_actions
    diagnostic = {
      "summary" => "The review fixer stopped before tests completed."
    }

    output = Hive::Tui::Views::RedStatusDetail.render(model_for(row(diagnostic: diagnostic)))

    assert_includes output, "Task needs attention"
    assert_includes output, "red-task"
    assert_includes output, "Project: alpha"
    assert_includes output, "Stage: 6-review"
    assert_includes output, "The review fixer stopped before tests completed."
    assert_includes output, "Recover"
    assert_includes output, "Open in agent"
    assert_includes output, "codex"
    assert_includes output, "[Enter]"
    assert_includes output, "[o]"
    assert_includes output, "[Esc] back"
    refute_includes output, "marker_signature"
    refute_includes output, "Marker:"
    refute_includes output, "$EDITOR"
    refute_includes output, "manual fix"
    refute_includes output, "autofix"
    refute_includes output, "recover_review"
    refute_includes output, "recover_execute"
    refute_includes output, "EXECUTE_STALE"
    refute_includes output, "phase=fix"
    refute_includes output, "pass=2"
    refute_includes output, "Q: Why is this red?"
    refute_includes output, "Q: What can Hive do next?"
  end

  def test_sanitizes_ansi_sequences_from_diagnostic_text
    diagnostic = {
      "summary" => "\e[31mbad\e[0m",
      "artifact_paths" => []
    }

    output = Hive::Tui::Views::RedStatusDetail.render(model_for(row(diagnostic: diagnostic)))

    refute_includes output, "\e["
    assert_includes output, "bad"
  end

  def test_falls_back_when_agent_label_is_missing
    # Caller resolution failure surfaces as the canonical AGENT_FALLBACK
    # label on RedStatusDetailState (the rescue in BubbleModel
    # #resolve_agent_label is exercised in bubble_model_test.rb). Pin
    # via the constant so a future rewording of the fallback copy stays
    # in one place.
    fallback = Hive::Tui::Model::RedStatusDetailState::AGENT_FALLBACK
    output = Hive::Tui::Views::RedStatusDetail.render(model_for(row, agent_label: fallback))

    assert_includes output, "Open in agent"
    assert_includes output, fallback
  end

  def test_recover_execute_rows_still_show_two_actions_with_enter_affordance
    output = Hive::Tui::Views::RedStatusDetail.render(
      model_for(
        row(
          action_key: "recover_execute",
          stage: "4-execute",
          marker: "execute_stale",
          attrs: { "pass" => "3" },
          folder: "/tmp/demo/.hive-state/stages/4-execute/red-task"
        )
      )
    )

    # The unified contract: [Enter] Recover always shown regardless of
    # action_key. recover_execute rows route refusals through the
    # bubble_model flash so the operator's binary gesture never leaves
    # them stranded on the detail screen.
    assert_includes output, "[Enter] Recover"
    assert_includes output, "[o]     Open in agent"
    refute_includes output, "[f] manual fix"
    refute_includes output, "[R] refresh diagnosis"
    refute_includes output, "EXECUTE_STALE"
  end

  def test_recover_review_row_shows_enter_affordance
    # Positive pin for the unified [Enter] Recover contract — paired
    # with test_recover_execute_rows_still_show_two_actions_with_enter_affordance
    # so a future split-by-action_key regression breaks both tests.
    output = Hive::Tui::Views::RedStatusDetail.render(model_for(row))

    assert_includes output, "[Enter] Recover"
    assert_includes output, "[o]     Open in agent"
  end

  def test_missing_diagnostic_uses_plain_english_fallback
    output = Hive::Tui::Views::RedStatusDetail.render(model_for(row(diagnostic: nil)))

    assert_includes output, "Hive does not have a diagnosis yet"
    refute_includes output, "marker_signature"
    refute_includes output, "Marker:"
  end

  def test_marker_summary_string_falls_back_to_plain_english
    # Older artifacts can leak `TaskAction#marker_summary`-shaped strings
    # ("REVIEW_ERROR phase=fix pass=2") into diagnostic["summary"]. The
    # detail screen must detect that shape and use the plain-English
    # fallback rather than dump debug copy.
    diagnostic = { "summary" => "REVIEW_ERROR phase=fix pass=2" }
    output = Hive::Tui::Views::RedStatusDetail.render(model_for(row(diagnostic: diagnostic)))

    assert_includes output, "Hive does not have a diagnosis yet"
    refute_includes output, "REVIEW_ERROR"
    refute_includes output, "phase=fix"
    refute_includes output, "pass=2"
  end

  def test_marker_summary_pattern_passes_through_bare_uppercase_verdict
    # `ABORTED` looks like the leading-token portion of a marker_summary
    # but has no `key=value` attrs — the tightened regex requires at
    # least one attrs token, so a legitimate bare upper-case verdict
    # must survive unmodified.
    diagnostic = { "summary" => "ABORTED" }
    output = Hive::Tui::Views::RedStatusDetail.render(model_for(row(diagnostic: diagnostic)))

    assert_includes output, "ABORTED"
    refute_includes output, "Hive does not have a diagnosis yet"
  end

  def test_marker_summary_pattern_passes_through_legitimate_sentence
    # A normal human-readable sentence shares no shape with the
    # marker_summary pattern and must render verbatim.
    diagnostic = { "summary" => "Build failed: out of memory" }
    output = Hive::Tui::Views::RedStatusDetail.render(model_for(row(diagnostic: diagnostic)))

    assert_includes output, "Build failed: out of memory"
    refute_includes output, "Hive does not have a diagnosis yet"
  end

  def test_renders_without_border_on_narrow_terminals
    # Below the 40-col threshold the border is skipped so the body
    # gets the full inner width. Plan Risk #5 — the dual-path render
    # exists precisely to keep the screen legible on narrow terminals.
    output = Hive::Tui::Views::RedStatusDetail.render(model_for(row, cols: 30, rows: 20))

    refute_includes output, "╭", "narrow terminals must skip the box-drawing border"
    refute_includes output, "╰"
    assert_includes output, "Task needs attention"
    assert_includes output, "[Enter] Recover"
  end

  def test_renders_with_border_on_wide_terminals
    # Above the threshold the rounded border wraps the body. Pin the
    # box-drawing corners so a style swap that drops the border would
    # break the test rather than silently regress.
    output = Hive::Tui::Views::RedStatusDetail.render(model_for(row, cols: 80, rows: 24))

    assert_includes output, "╭", "wide terminals must render the rounded border"
    assert_includes output, "╰"
    assert_includes output, "[Enter] Recover"
  end

  def test_footer_survives_short_rows_and_long_summaries
    # With body_height too small to fit every body line, the footer
    # must still render — it is the only on-screen reference for the
    # action keys. Reserve test pins the "footer outside truncation"
    # invariant called out in the review.
    diagnostic = {
      "summary" => "A " * 400
    }
    output = Hive::Tui::Views::RedStatusDetail.render(model_for(row(diagnostic: diagnostic), cols: 80, rows: 8))

    assert_includes output, "[Enter] Recover   [o] Open in agent   [Esc] back",
                    "the action-keys footer must always be on screen even when the body is truncated"
  end

  def test_footer_stacks_per_key_on_very_narrow_terminals
    # At rows=6 the body is trimmed and at cols=40 the joined FOOTER
    # (~52 chars) won't fit on one line — `truncate` would drop the
    # tail and hide `[Esc] back`. The stacked-footer branch puts one
    # key per line so every affordance stays visible.
    output = Hive::Tui::Views::RedStatusDetail.render(model_for(row, cols: 40, rows: 12))

    assert_includes output, "[Enter] Recover",
                    "narrow terminals must keep [Enter] Recover visible"
    assert_includes output, "[o] Open in agent",
                    "narrow terminals must keep [o] Open in agent visible"
    assert_includes output, "[Esc] back",
                    "narrow terminals must keep [Esc] back visible — the only documented dismiss affordance"
  end

  def test_renders_flash_on_detail_screen
    # KeyMap fires `Messages::Flash` for refusal keystrokes (e.g.,
    # `s`/`f`/`R` muscle-memory drift in :red_status_detail). The flash
    # must be visible without backing out to the grid — otherwise the
    # documented refusal contract is invisible until dismiss.
    state = Hive::Tui::Model::RedStatusDetailState.new(row: row, agent_label: "codex")
    model = Hive::Tui::Model.initial.with(
      mode: :red_status_detail,
      red_status_detail_state: state,
      cols: 100, rows: 24,
      flash: "press o for Open in agent",
      flash_set_at: Time.now
    )
    output = Hive::Tui::Views::RedStatusDetail.render(model)

    assert_includes output, "press o for Open in agent",
                    "active flash must surface on the detail screen so refusal hints are observable"
  end

  def test_unknown_action_still_offers_recover_and_open_agent
    unknown_row = Hive::Tui::Snapshot::Row.new(
      project_name: "alpha", stage: "9-archive", slug: "red-task",
      folder: "/tmp/red-task", state_file: "/tmp/red-task/task.md",
      marker: "none", attrs: {}, mtime: nil,
      age_seconds: 0, claude_pid: nil, claude_pid_alive: nil,
      action_key: "inspect", action_label: "Needs inspection",
      suggested_command: nil, next_action: nil, diagnostic: nil
    )

    output = Hive::Tui::Views::RedStatusDetail.render(model_for(unknown_row))

    assert_includes output, "[Enter] Recover"
    assert_includes output, "[o]     Open in agent"
    assert_includes output, "Hive does not have a diagnosis yet"
    refute_includes output, "[f] manual fix"
  end
end
