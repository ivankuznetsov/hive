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
