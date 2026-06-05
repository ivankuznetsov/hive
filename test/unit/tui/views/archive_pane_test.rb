require "test_helper"
require "hive/tui/model"
require "hive/tui/snapshot"
require "hive/tui/views/archive_pane"

class HiveTuiViewsArchivePaneTest < Minitest::Test
  def task(slug:, stage:, project: "demo", marker: "complete", age: 120)
    {
      "stage" => stage,
      "slug" => slug,
      "folder" => "/tmp/#{project}/#{slug}",
      "state_file" => "/tmp/#{project}/#{slug}/task.md",
      "marker" => marker,
      "attrs" => {},
      "mtime" => "2026-05-01T00:00:00Z",
      "folder_mtime" => "2026-05-01T00:00:00Z",
      "age_seconds" => age,
      "claude_pid" => nil,
      "claude_pid_alive" => nil,
      "action" => stage == "9-done" ? "archived" : "ready_to_plan",
      "action_label" => stage == "9-done" ? "Archived" : "Ready to plan",
      "suggested_command" => nil
    }
  end

  def snapshot(projects)
    Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-06-04T12:00:00Z",
      "projects" => projects
    )
  end

  def model(snapshot)
    Hive::Tui::Model.initial.with(snapshot: snapshot, cols: 100, rows: 30, mode: :archive)
  end

  def test_renders_all_done_rows_and_excludes_other_stages
    snap = snapshot([
                      {
                        "name" => "alpha",
                        "path" => "/tmp/alpha",
                        "hive_state_path" => "/tmp/alpha/.hive-state",
                        "tasks" => [
                          task(slug: "old-archived", stage: "9-done", project: "alpha", age: 5 * 86_400),
                          task(slug: "recent-archived", stage: "9-done", project: "alpha", age: 3600),
                          task(slug: "active-task", stage: "4-execute", project: "alpha")
                        ]
                      },
                      {
                        "name" => "beta",
                        "path" => "/tmp/beta",
                        "hive_state_path" => "/tmp/beta/.hive-state",
                        "tasks" => [
                          task(slug: "beta-archived", stage: "9-done", project: "beta", age: 86_400)
                        ]
                      }
                    ])

    out = Hive::Tui::Views::ArchivePane.render(model(snap), width: 100)

    assert_includes out, "Archive · all done tasks"
    assert_includes out, "old-archived"
    assert_includes out, "recent-archived"
    assert_includes out, "beta-archived"
    assert_includes out, "alpha"
    assert_includes out, "beta"
    refute_includes out, "active-task"
    assert_includes out, "q/Esc close"
  end

  # Wide-char (emoji/CJK) slugs are 2 terminal cells per glyph. The slug
  # column must be padded by display cells (Format.ljust_cells), not code
  # units, or the project column drifts and the pane borders misalign.
  def test_wide_char_slug_does_not_shift_the_project_column
    ascii = snapshot([
                       {
                         "name" => "alpha",
                         "path" => "/tmp/alpha",
                         "hive_state_path" => "/tmp/alpha/.hive-state",
                         "tasks" => [ task(slug: "plain", stage: "9-done", project: "alpha") ]
                       }
                     ])
    wide = snapshot([
                      {
                        "name" => "alpha",
                        "path" => "/tmp/alpha",
                        "hive_state_path" => "/tmp/alpha/.hive-state",
                        "tasks" => [ task(slug: "🤖🤖task", stage: "9-done", project: "alpha") ]
                      }
                    ])

    ascii_row = Hive::Tui::Views::ArchivePane.render_row(ascii.rows.first, 100)
    wide_row = Hive::Tui::Views::ArchivePane.render_row(wide.rows.first, 100)

    # The project name "alpha" must begin at the same cell offset in both
    # rows; a code-unit ljust would push it right by the emoji over-pad.
    ascii_offset = Hive::Tui::Views::Format.display_width(ascii_row.split("alpha", 2).first)
    wide_offset = Hive::Tui::Views::Format.display_width(wide_row.split("alpha", 2).first)
    assert_equal ascii_offset, wide_offset,
                 "wide-char slug must not shift the fixed-width project column"
  end

  def test_renders_empty_placeholder_when_no_archived_tasks
    snap = snapshot([
                      {
                        "name" => "alpha",
                        "path" => "/tmp/alpha",
                        "hive_state_path" => "/tmp/alpha/.hive-state",
                        "tasks" => [ task(slug: "active-task", stage: "4-execute", project: "alpha") ]
                      }
                    ])

    out = Hive::Tui::Views::ArchivePane.render(model(snap), width: 100)

    assert_includes out, "(no archived tasks)"
    refute_includes out, "active-task"
  end
end
