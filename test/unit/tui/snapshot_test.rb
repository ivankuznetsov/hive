require "test_helper"
require "hive/tui/snapshot"

# Snapshot is a frozen value-object view over one `hive status` JSON
# payload. These tests pin the `from_payload` constructor's tolerance,
# the renderer-facing helpers (filter / scope / row_at), and the
# verbatim preservation of every field the Status command emits.
class TuiSnapshotTest < Minitest::Test
  include HiveTestHelper

  def sample_task(slug:, stage: "1-inbox", marker: "waiting")
    {
      "stage" => stage,
      "slug" => slug,
      "folder" => "/tmp/hive/#{slug}",
      "state_file" => "/tmp/hive/#{slug}/idea.md",
      "marker" => marker,
      "attrs" => {},
      "mtime" => "2026-04-27T12:00:00Z",
      "age_seconds" => 42,
      "claude_pid" => nil,
      "claude_pid_alive" => nil,
      "action" => "ready_to_brainstorm",
      "action_label" => "Ready to brainstorm",
      "suggested_command" => "hive brainstorm #{slug}"
    }
  end

  def sample_payload(projects)
    {
      "schema" => "hive-status",
      "schema_version" => 1,
      "generated_at" => "2026-04-27T12:00:00Z",
      "projects" => projects
    }
  end

  def test_from_payload_preserves_all_task_fields_verbatim
    payload = sample_payload([
                               {
                                 "name" => "alpha",
                                 "path" => "/tmp/alpha",
                                 "hive_state_path" => "/tmp/alpha/.hive-state",
                                 "tasks" => [
                                   sample_task(slug: "first-task"),
                                   sample_task(slug: "second-task", stage: "2-brainstorm", marker: "complete")
                                 ]
                               }
                             ])

    snapshot = Hive::Tui::Snapshot.from_payload(payload)

    assert_equal "2026-04-27T12:00:00Z", snapshot.generated_at,
                 "generated_at must be preserved verbatim"
    assert_equal 1, snapshot.projects.size
    assert_equal 2, snapshot.rows.size, "rows flattens across all projects"

    first = snapshot.rows.first
    assert_equal "alpha", first.project_name
    assert_equal "1-inbox", first.stage
    assert_equal "first-task", first.slug
    assert_equal "/tmp/hive/first-task", first.folder
    assert_equal "/tmp/hive/first-task/idea.md", first.state_file
    assert_equal "waiting", first.marker
    assert_equal({}, first.attrs)
    assert_equal "2026-04-27T12:00:00Z", first.mtime
    assert_equal 42, first.age_seconds
    assert_nil first.claude_pid
    assert_nil first.claude_pid_alive
    assert_equal "ready_to_brainstorm", first.action_key,
                 "JSON 'action' lands on :action_key"
    assert_equal "Ready to brainstorm", first.action_label
    assert_equal "hive brainstorm first-task", first.suggested_command

    assert snapshot.frozen?, "snapshot must be frozen"
    assert first.frozen?, "row records must be frozen"
  end

  def test_from_payload_with_empty_projects_yields_empty_rows
    snapshot = Hive::Tui::Snapshot.from_payload(sample_payload([]))
    assert_equal [], snapshot.projects
    assert_equal [], snapshot.rows
  end

  def test_from_payload_handles_nil_payload
    snapshot = Hive::Tui::Snapshot.from_payload(nil)
    assert_nil snapshot.generated_at
    assert_equal [], snapshot.projects
  end

  def test_project_with_missing_path_error_keeps_project_with_empty_rows
    payload = sample_payload([
                               {
                                 "name" => "broken",
                                 "path" => "/nonexistent",
                                 "hive_state_path" => "/nonexistent/.hive-state",
                                 "error" => "missing_project_path",
                                 "tasks" => []
                               }
                             ])
    snapshot = Hive::Tui::Snapshot.from_payload(payload)
    project = snapshot.projects.first
    assert_equal "broken", project.name
    assert_equal "missing_project_path", project.error
    assert_equal [], project.rows
    assert_equal [], snapshot.rows
  end

  def test_filter_by_slug_matches_case_insensitive_substring
    payload = sample_payload([
                               {
                                 "name" => "alpha",
                                 "path" => "/tmp/alpha",
                                 "hive_state_path" => "/tmp/alpha/.hive-state",
                                 "tasks" => [
                                   sample_task(slug: "auth-fix"),
                                   sample_task(slug: "cache-bug"),
                                   sample_task(slug: "AUTH-renew")
                                 ]
                               }
                             ])
    snapshot = Hive::Tui::Snapshot.from_payload(payload)

    filtered = snapshot.filter_by_slug("auth")
    assert_equal 2, filtered.rows.size, "case-insensitive substring match"
    slugs = filtered.rows.map(&:slug).sort
    assert_equal [ "AUTH-renew", "auth-fix" ], slugs
  end

  def test_filter_by_slug_with_empty_substring_returns_self
    snapshot = Hive::Tui::Snapshot.from_payload(sample_payload([]))
    assert_same snapshot, snapshot.filter_by_slug(""),
                "empty substring is a no-op"
    assert_same snapshot, snapshot.filter_by_slug(nil),
                "nil substring is a no-op"
  end

  def test_filter_by_slug_keeps_projects_with_zero_matches
    payload = sample_payload([
                               {
                                 "name" => "alpha",
                                 "path" => "/tmp/alpha",
                                 "hive_state_path" => "/tmp/alpha/.hive-state",
                                 "tasks" => [ sample_task(slug: "no-match") ]
                               }
                             ])
    snapshot = Hive::Tui::Snapshot.from_payload(payload)
    filtered = snapshot.filter_by_slug("zzz")
    assert_equal 1, filtered.projects.size,
                 "project preserved so renderer can show empty state"
    assert_equal [], filtered.projects.first.rows
  end

  def test_scope_to_project_index_zero_returns_self
    payload = sample_payload([
                               { "name" => "a", "path" => "/a", "hive_state_path" => "/a/.hive-state", "tasks" => [] },
                               { "name" => "b", "path" => "/b", "hive_state_path" => "/b/.hive-state", "tasks" => [] }
                             ])
    snapshot = Hive::Tui::Snapshot.from_payload(payload)
    assert_same snapshot, snapshot.scope_to_project_index(0)
  end

  def test_scope_to_project_index_one_returns_first_project
    payload = sample_payload([
                               { "name" => "a", "path" => "/a", "hive_state_path" => "/a/.hive-state",
                                 "tasks" => [ sample_task(slug: "t1") ] },
                               { "name" => "b", "path" => "/b", "hive_state_path" => "/b/.hive-state", "tasks" => [] }
                             ])
    snapshot = Hive::Tui::Snapshot.from_payload(payload)
    scoped = snapshot.scope_to_project_index(1)
    assert_equal 1, scoped.projects.size
    assert_equal "a", scoped.projects.first.name
  end

  def test_scope_to_project_index_out_of_range_returns_empty_projects
    payload = sample_payload([
                               { "name" => "a", "path" => "/a", "hive_state_path" => "/a/.hive-state", "tasks" => [] }
                             ])
    snapshot = Hive::Tui::Snapshot.from_payload(payload)
    scoped = snapshot.scope_to_project_index(99)
    assert_equal [], scoped.projects, "out-of-range index yields empty-state snapshot"
  end

  def test_row_at_returns_row_for_valid_cursor
    payload = sample_payload([
                               { "name" => "a", "path" => "/a", "hive_state_path" => "/a/.hive-state",
                                 "tasks" => [ sample_task(slug: "only-task") ] }
                             ])
    snapshot = Hive::Tui::Snapshot.from_payload(payload)
    row = snapshot.row_at([ 0, 0 ])
    refute_nil row
    assert_equal "only-task", row.slug
  end

  def test_row_at_returns_nil_for_out_of_range_row_index
    payload = sample_payload([
                               { "name" => "a", "path" => "/a", "hive_state_path" => "/a/.hive-state",
                                 "tasks" => [ sample_task(slug: "only-task") ] }
                             ])
    snapshot = Hive::Tui::Snapshot.from_payload(payload)
    assert_nil snapshot.row_at([ 0, 5 ])
  end

  def test_row_at_returns_nil_for_out_of_range_project_index
    payload = sample_payload([
                               { "name" => "a", "path" => "/a", "hive_state_path" => "/a/.hive-state",
                                 "tasks" => [ sample_task(slug: "only-task") ] }
                             ])
    snapshot = Hive::Tui::Snapshot.from_payload(payload)
    assert_nil snapshot.row_at([ 5, 0 ])
  end

  def test_row_at_returns_nil_for_nil_cursor
    snapshot = Hive::Tui::Snapshot.from_payload(sample_payload([]))
    assert_nil snapshot.row_at(nil)
  end
end
