require "test_helper"
require "hive/tui/model"
require "hive/tui/snapshot"
require "hive/tui/views/red_status_detail"

class HiveTuiViewsRedStatusDetailTest < Minitest::Test
  ProfileStub = Struct.new(:bin, keyword_init: true)

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

  def model_for(row)
    state = Hive::Tui::Model::RedStatusDetailState.new(
      row: row,
      marker_signature: "review_error"
    )
    Hive::Tui::Model.initial.with(mode: :red_status_detail, red_status_detail_state: state, cols: 100, rows: 24)
  end

  def with_config_load_stub(stub_proc)
    sentinel = Hive::Config.method(:load)
    Hive::Config.define_singleton_method(:load, &stub_proc)
    yield
  ensure
    Hive::Config.define_singleton_method(:load, sentinel) if sentinel
  end

  def with_agent_profile_lookup_stub(stub_proc)
    sentinel = Hive::AgentProfiles.method(:lookup)
    Hive::AgentProfiles.define_singleton_method(:lookup, &stub_proc)
    yield
  ensure
    Hive::AgentProfiles.define_singleton_method(:lookup, sentinel) if sentinel
  end

  def test_renders_user_facing_summary_with_two_actions
    diagnostic = {
      "summary" => "The review fixer stopped before tests completed."
    }

    output = nil
    with_config_load_stub(->(_project_root) { { "execute" => { "agent" => "codex" } } }) do
      with_agent_profile_lookup_stub(->(_name, cfg:) { ProfileStub.new(bin: "/usr/local/bin/codex") }) do
        output = Hive::Tui::Views::RedStatusDetail.render(model_for(row(diagnostic: diagnostic)))
      end
    end

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

  def test_falls_back_when_dev_agent_lookup_fails
    output = nil
    with_config_load_stub(->(_project_root) { raise Hive::ConfigError, "broken config" }) do
      output = Hive::Tui::Views::RedStatusDetail.render(model_for(row))
    end

    assert_includes output, "Open in agent"
    assert_includes output, "your project's development agent"
  end

  def test_recover_execute_rows_still_show_only_two_actions
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

    assert_includes output, "[Enter] Recover"
    assert_includes output, "[o] Open in agent"
    refute_includes output, "[f] manual fix"
    refute_includes output, "[R] refresh diagnosis"
    refute_includes output, "EXECUTE_STALE"
  end

  def test_missing_diagnostic_uses_plain_english_fallback
    output = Hive::Tui::Views::RedStatusDetail.render(model_for(row(diagnostic: nil)))

    assert_includes output, "Hive does not have a diagnosis yet"
    refute_includes output, "marker"
  end
end
