require "test_helper"
require "hive/tui/model"
require "hive/tui/snapshot"
require "hive/tui/views/archive_pane"

class HiveTuiViewsArchivePaneTest < Minitest::Test
  def task(slug:, stage:, project: "demo", marker: "complete", age: 120, archived: false)
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
      "action" => archived ? "archived" : "ready_to_plan",
      "action_label" => archived ? "Archived" : "Ready to plan",
      "suggested_command" => nil
    }
  end

  def snapshot(projects, archive_projects: [])
    Hive::Tui::Snapshot.from_payload(
      {
        "generated_at" => "2026-06-04T12:00:00Z",
        "projects" => projects
      },
      archive_payload: {
        "generated_at" => "2026-06-04T12:00:00Z",
        "projects" => archive_projects
      }
    )
  end

  def model(snapshot)
    Hive::Tui::Model.initial.with(snapshot: snapshot, cols: 100, rows: 30, mode: :archive)
  end

  def row(slug:, project:, age: 120)
    Struct.new(:slug, :project_name, :age_seconds).new(slug, project, age)
  end

  def test_renders_all_done_rows_and_excludes_other_stages
    ordinary = [
      {
        "name" => "alpha",
        "path" => "/tmp/alpha",
        "hive_state_path" => "/tmp/alpha/.hive-state",
        "tasks" => [ task(slug: "active-task", stage: "4-execute", project: "alpha") ]
      }
    ]
    archive = [
                      {
                        "name" => "alpha",
                        "path" => "/tmp/alpha",
                        "hive_state_path" => "/tmp/alpha/.hive-state",
                        "tasks" => [
                          task(slug: "old-archived", stage: "9-done", project: "alpha",
                               age: 5 * 86_400, archived: true),
                          task(slug: "recent-archived", stage: "9-done", project: "alpha",
                               age: 3600, archived: true)
                        ]
                      },
                      {
                        "name" => "beta",
                        "path" => "/tmp/beta",
                        "hive_state_path" => "/tmp/beta/.hive-state",
                        "tasks" => [
                          task(slug: "beta-archived", stage: "4-published", project: "beta",
                               age: 86_400, archived: true)
                        ]
                      }
                    ]
    snap = snapshot(ordinary, archive_projects: archive)

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

  def test_sanitizes_control_characters_in_slug_and_project_name
    archive = [
                      {
                        "name" => "de\e[2Jmo",
                        "path" => "/tmp/de",
                        "hive_state_path" => "/tmp/de/.hive-state",
                        "tasks" => [ task(slug: "demo\e[2Jtask", stage: "9-done", project: "de\e[2Jmo") ]
                      }
                    ]
    snap = snapshot([], archive_projects: archive)

    out = Hive::Tui::Views::ArchivePane.render(model(snap), width: 100)

    refute_includes out, "\e["
    refute_includes out, "\e[2J"
    assert_includes out, "demotask"
    assert_includes out, "demo"
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

  # Wide (CJK) characters occupy two terminal cells. Padding with String's
  # column-naive `ljust` pads to a CHARACTER count, so a wide project name
  # overruns PROJECT_WIDTH and pushes the age column right relative to
  # ASCII rows. The pane must pad by cells (Format.ljust_cells/rjust_cells).
  def test_wide_project_name_keeps_age_column_aligned_with_ascii_rows
    pane = Hive::Tui::Views::ArchivePane
    fmt = Hive::Tui::Views::Format

    offsets = {
      "task-a" => "demo",
      "task-b" => "项目"
    }.map do |slug, project|
      line = pane.render_row(row(slug: slug, project: project, age: 60), 100)
      fmt.display_width(line.split("1m", 2).first)
    end

    # Prefix before the right-justified "1m" spans slug + separator +
    # project + separator + the age's own left padding (AGE_WIDTH - 2 cells).
    expected = pane::SLUG_WIDTH + 1 + pane::PROJECT_WIDTH + 1 + pane::AGE_WIDTH - 2
    assert_equal [ expected ] * 2, offsets,
                 "wide (CJK) project names must not shift the age column"
  end
end
