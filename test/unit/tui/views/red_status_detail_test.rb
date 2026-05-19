require "test_helper"
require "hive/tui/model"
require "hive/tui/snapshot"
require "hive/tui/views/red_status_detail"

class HiveTuiViewsRedStatusDetailTest < Minitest::Test
  def row(diagnostic: nil)
    Hive::Tui::Snapshot::Row.new(
      project_name: "alpha", stage: "6-review", slug: "red-task", folder: "/tmp/red-task",
      state_file: "/tmp/red-task/task.md", marker: "review_error",
      attrs: { "phase" => "fix", "pass" => "2" }, mtime: nil, age_seconds: 0,
      claude_pid: nil, claude_pid_alive: nil,
      action_key: "recover_review", action_label: "Needs recovery",
      suggested_command: nil, next_action: nil, diagnostic: diagnostic
    )
  end

  def model_for(row)
    state = Hive::Tui::Model::RedStatusDetailState.new(
      row: row,
      marker_signature: "review_error"
    )
    Hive::Tui::Model.initial.with(mode: :red_status_detail, red_status_detail_state: state, cols: 100, rows: 24)
  end

  def test_renders_q_and_a_diagnosis_and_actions
    diagnostic = {
      "summary" => "REVIEW_ERROR phase=fix pass=2",
      "detail" => "Fix agent failed before tests completed.",
      "artifact_paths" => [ "/tmp/red-task/reviews/errors-02.md" ]
    }

    output = Hive::Tui::Views::RedStatusDetail.render(model_for(row(diagnostic: diagnostic)))

    assert_includes output, "Q: Why is this red?"
    assert_includes output, "REVIEW_ERROR phase=fix pass=2"
    assert_includes output, "Q: What can Hive do next?"
    assert_includes output, "/tmp/red-task/reviews/errors-02.md"
    assert_includes output, "[Enter] autofix / retry"
  end

  def test_sanitizes_ansi_sequences_from_diagnostic_text
    diagnostic = {
      "summary" => "\e[31mbad\e[0m",
      "detail" => "detail\e[2J",
      "artifact_paths" => []
    }

    output = Hive::Tui::Views::RedStatusDetail.render(model_for(row(diagnostic: diagnostic)))

    refute_includes output, "\e["
    assert_includes output, "bad"
  end

  # Footer is row-dependent: recover_review / error rows advertise
  # [Enter] autofix; recover_execute rows DO NOT (Enter would be a no-op
  # because EXECUTE_STALE has no auto-retry recipe). Pinning both
  # branches so the footer cannot regress to advertising a non-op.
  # See PR #84 review row 25.
  def test_footer_includes_enter_affordance_for_recover_review_rows
    output = Hive::Tui::Views::RedStatusDetail.render(model_for(row))
    assert_includes output, "[Enter] autofix / retry",
                    "recover_review rows must keep the [Enter] affordance"
  end

  def test_footer_omits_enter_affordance_for_recover_execute_rows
    execute_row = Hive::Tui::Snapshot::Row.new(
      project_name: "alpha", stage: "4-execute", slug: "stale-task",
      folder: "/tmp/stale-task", state_file: "/tmp/stale-task/task.md",
      marker: "execute_stale", attrs: { "pass" => "3" }, mtime: nil,
      age_seconds: 0, claude_pid: nil, claude_pid_alive: nil,
      action_key: "recover_execute", action_label: "Needs recovery",
      suggested_command: nil, next_action: nil, diagnostic: nil
    )

    output = Hive::Tui::Views::RedStatusDetail.render(model_for(execute_row))

    refute_includes output, "[Enter] autofix / retry",
                    "recover_execute rows MUST NOT advertise [Enter] (Enter is a no-op for EXECUTE_STALE)"
    assert_includes output, "[f] manual fix",
                    "recover_execute rows must keep the manual-fix affordance"
    assert_includes output, "[R] refresh diagnosis",
                    "recover_execute rows must keep the refresh affordance"
    assert_includes output, "[q] back",
                    "recover_execute rows must keep the back affordance"
  end
end
