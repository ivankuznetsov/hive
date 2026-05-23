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
  # (Update.apply_open_red_status_detail), so the view never does
  # per-frame disk I/O. Tests pass the precomputed label directly,
  # matching how production opens the screen.
  def model_for(row, cols: 100, rows: 24, agent_label: "codex")
    state = Hive::Tui::Model::RedStatusDetailState.new(
      row: row,
      marker_signature: "review_error",
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
    # Caller resolution failure surfaces as a nil agent_label on
    # RedStatusDetailState (the rescue in resolve_agent_label is
    # exercised in test_resolve_agent_label_*).
    output = Hive::Tui::Views::RedStatusDetail.render(model_for(row, agent_label: nil))

    assert_includes output, "Open in agent"
    assert_includes output, "your project's development agent"
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

  def test_resolve_agent_label_blank_bin_uses_fallback
    profile = Struct.new(:bin).new("")
    label = nil
    with_singleton_method_stub(Hive::Config, :load, ->(_root) { { "execute" => { "agent" => "claude" } } }) do
      with_singleton_method_stub(Hive::AgentProfiles, :lookup, ->(_name, cfg:) { profile }) do
        label = Hive::Tui::Views::RedStatusDetail.resolve_agent_label(row)
      end
    end

    assert_equal Hive::Tui::Views::RedStatusDetail::AGENT_FALLBACK, label
  end

  def test_resolve_agent_label_falls_back_on_psych_error
    # Malformed YAML raises Psych::SyntaxError from Config.load. The
    # resolver must catch it so an unhealthy config can't crash the
    # detail-screen open path. See plan Risk #4 / codex review row.
    label = nil
    with_singleton_method_stub(Hive::Config, :load, ->(_root) { raise Psych::SyntaxError.new("config.yml", 1, 1, 0, "bad", "context") }) do
      label = Hive::Tui::Views::RedStatusDetail.resolve_agent_label(row)
    end

    assert_equal Hive::Tui::Views::RedStatusDetail::AGENT_FALLBACK, label
  end

  private

  # Module-singleton stub with original-method restore. Used only by
  # the two resolve_agent_label tests above; the render-path tests
  # avoid stubbing module singletons entirely because the agent label
  # is now cached on RedStatusDetailState at open time.
  def with_singleton_method_stub(target, name, stub_proc)
    original = target.method(name)
    target.define_singleton_method(name, &stub_proc)
    yield
  ensure
    target.define_singleton_method(name, original) if original
  end
end
