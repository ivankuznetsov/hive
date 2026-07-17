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
      "id" => 42,
      "display_name" => "First Task",
      "depends_on" => "base-task",
      "blocked_by" => "base-task",
      "dependency_stage" => "7-artifacts",
      "blocked" => true,
      "admission_error" => nil,
      "folder" => "/tmp/hive/#{slug}",
      "state_file" => "/tmp/hive/#{slug}/idea.md",
      "pr_url" => nil,
      "marker" => marker,
      "attrs" => {},
      "mtime" => "2026-04-27T12:00:00Z",
      "folder_mtime" => "2026-04-27T11:59:00Z",
      "age_seconds" => 42,
      "claude_pid" => nil,
      "claude_pid_alive" => nil,
      "live_task_lock" => true,
      "task_lock_pid" => 12_345,
      "task_lock_process_start_time" => "recorded-start",
      "task_lock_id" => "recorded-generation",
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
    assert_equal 42, first.id
    assert_equal "First Task", first.display_name
    assert_equal "base-task", first.depends_on
    assert_equal "base-task", first.blocked_by
    assert_equal "7-artifacts", first.dependency_stage
    assert_equal true, first.blocked
    assert_nil first.admission_error
    assert_equal "/tmp/hive/first-task", first.folder
    assert_equal "/tmp/hive/first-task/idea.md", first.state_file
    assert_nil first.pr_url
    assert_equal "waiting", first.marker
    assert_equal({}, first.attrs)
    assert_equal "2026-04-27T12:00:00Z", first.mtime
    assert_equal "2026-04-27T11:59:00Z", first.folder_mtime
    assert_equal 42, first.age_seconds
    assert_nil first.claude_pid
    assert_nil first.claude_pid_alive
    assert_equal true, first.live_task_lock
    assert_equal 12_345, first.task_lock_pid
    assert_equal "recorded-start", first.task_lock_process_start_time
    assert_equal "recorded-generation", first.task_lock_id
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

  def test_from_payload_defaults_missing_folder_mtime_to_nil
    row = sample_task(slug: "legacy-payload")
    row.delete("folder_mtime")
    payload = sample_payload([
                               {
                                 "name" => "alpha",
                                 "path" => "/tmp/alpha",
                                 "hive_state_path" => "/tmp/alpha/.hive-state",
                                 "tasks" => [ row ]
                               }
                             ])

    snapshot = Hive::Tui::Snapshot.from_payload(payload)

    assert_nil snapshot.rows.first.folder_mtime
  end

  def test_from_payload_preserves_content_workflow_stage_rows
    row = sample_task(slug: "content-row", stage: "2-research")
    row["workflow"] = "content_fixture"
    row["action"] = "ready_to_run"
    row["action_label"] = "Ready to run"
    row["suggested_command"] = "hive run content-row"
    payload = sample_payload([
                               {
                                 "name" => "alpha",
                                 "path" => "/tmp/alpha",
                                 "hive_state_path" => "/tmp/alpha/.hive-state",
                                 "tasks" => [ row ]
                               }
                             ])

    snapshot = Hive::Tui::Snapshot.from_payload(payload)
    content = snapshot.rows.first

    assert_equal "content_fixture", content.workflow
    assert_equal "2-research", content.stage
    assert_equal "ready_to_run", content.action_key
    assert_equal "hive run content-row", content.suggested_command
  end

  def test_from_payload_preserves_quota_held_field
    row = sample_task(slug: "quota-row", stage: "4-execute", marker: "error")
    row["attrs"] = {
      "reason" => "limits_reached",
      "provider" => "codex",
      "retry_after" => "2026-06-24T23:20:00Z"
    }
    row["held"] = {
      "reason" => "quota",
      "provider" => "codex",
      "retry_after" => "2026-06-24T23:20:00Z"
    }
    payload = sample_payload([
                               {
                                 "name" => "alpha",
                                 "path" => "/tmp/alpha",
                                 "hive_state_path" => "/tmp/alpha/.hive-state",
                                 "tasks" => [ row ]
                               }
                             ])

    snapshot = Hive::Tui::Snapshot.from_payload(payload)

    assert_equal row.fetch("held"), snapshot.rows.first.held
  end

  def test_from_payload_preserves_admission_error
    row = sample_task(slug: "held-row")
    row["action"] = "admission_error"
    row["action_label"] = "Admission error"
    row["suggested_command"] = nil
    row["blocked_by"] = nil
    row["dependency_stage"] = nil
    row["admission_error"] = {
      "reason_code" => "dependency_cycle",
      "offending_ref" => "app:a -> app:b -> app:a",
      "safe_correction" => "Break the cycle."
    }
    snapshot = Hive::Tui::Snapshot.from_payload(sample_payload([
      { "name" => "alpha", "tasks" => [ row ] }
    ]))

    assert_equal row["admission_error"], snapshot.rows.first.admission_error
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

  def test_filter_by_slug_matches_display_name_and_id
    first = sample_task(slug: "slug-a")
    first["id"] = 17
    first["display_name"] = "Readable Alpha"
    first["pr_url"] = "https://github.com/example/repo/pull/561"
    second = sample_task(slug: "slug-b")
    second["id"] = 23
    second["display_name"] = "Other Beta"
    payload = sample_payload([
                               {
                                 "name" => "alpha",
                                 "path" => "/tmp/alpha",
                                 "hive_state_path" => "/tmp/alpha/.hive-state",
                                 "tasks" => [ first, second ]
                               }
                             ])
    snapshot = Hive::Tui::Snapshot.from_payload(payload)

    assert_equal [ "slug-a" ], snapshot.filter_by_slug("readable").rows.map(&:slug)
    assert_equal [ "slug-b" ], snapshot.filter_by_slug("23").rows.map(&:slug)
    assert_equal "https://github.com/example/repo/pull/561", snapshot.rows.first.pr_url
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

  # Rows must be sorted by `Status::ACTION_LABEL_ORDER` at construction
  # time so the cursor `>` in the renderer always lines up with the row
  # `at_cursor(snapshot)` returns. Without the sort, a project that
  # spans multiple action_labels lets the cursor highlight one row while
  # Enter / verb-keystrokes act on another (issue #10).
  def test_build_project_view_sorts_rows_by_action_label_order
    develop = sample_task(slug: "fix-stuff")
    develop["action"] = "ready_to_develop"
    develop["action_label"] = "Ready to develop"

    brainstorm = sample_task(slug: "brand-new")
    # Already labelled "Ready to brainstorm" by sample_task.

    needs_input = sample_task(slug: "input-please")
    needs_input["action"] = "needs_your_input"
    needs_input["action_label"] = "Needs your input"

    payload = sample_payload([
                               {
                                 "name" => "alpha",
                                 "path" => "/tmp/alpha",
                                 "hive_state_path" => "/tmp/alpha/.hive-state",
                                 # Deliberately NOT in ACTION_LABEL_ORDER sequence:
                                 "tasks" => [ develop, brainstorm, needs_input ]
                               }
                             ])

    snapshot = Hive::Tui::Snapshot.from_payload(payload)
    rows = snapshot.projects.first.rows

    assert_equal "Ready to brainstorm", rows[0].action_label,
                 "first row must be the highest-ranked label per ACTION_LABEL_ORDER"
    assert_equal "Needs your input", rows[1].action_label
    assert_equal "Ready to develop", rows[2].action_label
  end

  def test_build_project_view_sorts_differentiated_waiting_labels_above_error
    waiting_labels = [
      "Answer questions",
      "Review plan draft",
      "Needs review decision",
      "Confirm finalize"
    ]
    rows = waiting_labels.map.with_index do |label, index|
      sample_task(slug: "waiting-#{index}").merge(
        "action" => "needs_input",
        "action_label" => label
      )
    end
    error = sample_task(slug: "error-row").merge(
      "action" => "error",
      "action_label" => "Error"
    )
    payload = sample_payload([
                               {
                                 "name" => "alpha",
                                 "path" => "/tmp/alpha",
                                 "hive_state_path" => "/tmp/alpha/.hive-state",
                                 "tasks" => [ error, *rows ]
                               }
                             ])

    snapshot = Hive::Tui::Snapshot.from_payload(payload)
    sorted_labels = snapshot.projects.first.rows.map(&:action_label)

    waiting_labels.each do |label|
      assert_operator sorted_labels.index(label), :<, sorted_labels.index("Error")
    end
  end

  def test_build_project_view_preserves_json_order_within_action_label_group
    # Two rows share the same label; their JSON order must survive the
    # sort so `Status`'s upstream mtime-desc ranking is honoured.
    first = sample_task(slug: "older-bug")
    second = sample_task(slug: "newer-bug")
    payload = sample_payload([
                               {
                                 "name" => "alpha",
                                 "path" => "/tmp/alpha",
                                 "hive_state_path" => "/tmp/alpha/.hive-state",
                                 "tasks" => [ first, second ]
                               }
                             ])

    snapshot = Hive::Tui::Snapshot.from_payload(payload)
    rows = snapshot.projects.first.rows
    assert_equal [ "older-bug", "newer-bug" ], rows.map(&:slug),
                 "JSON order is the stable secondary sort within a label group"
  end

  # The Snapshot must preserve the JSON's `legacy_stage_dirs` field on
  # each ProjectView so the renderer can flag projects with task folders
  # stuck under a renamed stage dir without re-walking the filesystem.
  def test_from_payload_preserves_legacy_stage_dirs_array
    legacy_entries = [
      { "stage_dir" => "5-review", "task_count" => 2 },
      { "stage_dir" => "6-pr",     "task_count" => 1 }
    ]
    payload = sample_payload([
                               {
                                 "name" => "alpha",
                                 "path" => "/tmp/alpha",
                                 "hive_state_path" => "/tmp/alpha/.hive-state",
                                 "tasks" => [],
                                 "legacy_stage_dirs" => legacy_entries,
                                 "legacy_migrate_command" => "hive migrate"
                               }
                             ])

    snapshot = Hive::Tui::Snapshot.from_payload(payload)
    project = snapshot.projects.first
    assert_equal legacy_entries, project.legacy_stage_dirs,
                 "ProjectView must preserve legacy_stage_dirs verbatim"
    # The machine-readable recovery hint must flow through ProjectView
    # so non-TUI consumers (and the TUI itself, eventually) can read it
    # without re-deriving "is this project clean?". Issue #94.
    assert_equal "hive migrate", project.legacy_migrate_command,
                 "ProjectView must preserve legacy_migrate_command verbatim"
  end

  def test_from_payload_defaults_legacy_stage_dirs_to_empty_array_when_key_absent
    payload = sample_payload([
                               {
                                 "name" => "alpha",
                                 "path" => "/tmp/alpha",
                                 "hive_state_path" => "/tmp/alpha/.hive-state",
                                 "tasks" => []
                                 # no legacy_stage_dirs / legacy_migrate_command keys
                               }
                             ])

    snapshot = Hive::Tui::Snapshot.from_payload(payload)
    project = snapshot.projects.first
    assert_equal [], project.legacy_stage_dirs,
                 "missing legacy_stage_dirs key must default to []"
    assert_nil project.legacy_migrate_command,
               "missing legacy_migrate_command key must default to nil"
  end

  def test_build_project_view_unknown_action_labels_sort_last_and_preserve_json_order
    known = sample_task(slug: "known-task")
    unknown_one = sample_task(slug: "future-one")
    unknown_one["action"] = "future_state_a"
    unknown_one["action_label"] = "Some Future Label A"
    unknown_two = sample_task(slug: "future-two")
    unknown_two["action"] = "future_state_b"
    unknown_two["action_label"] = "Some Future Label B"

    payload = sample_payload([
                               {
                                 "name" => "alpha",
                                 "path" => "/tmp/alpha",
                                 "hive_state_path" => "/tmp/alpha/.hive-state",
                                 # Unknown labels appear FIRST in JSON order; they must end up LAST.
                                 "tasks" => [ unknown_one, unknown_two, known ]
                               }
                             ])

    snapshot = Hive::Tui::Snapshot.from_payload(payload)
    rows = snapshot.projects.first.rows

    assert_equal "known-task", rows[0].slug,
                 "known label sorts ahead of any unknown labels"
    assert_equal [ "future-one", "future-two" ], rows[1..2].map(&:slug),
                 "unknown labels keep their JSON order against each other"
  end

  def test_without_old_archived_drops_old_archived_rows_by_task_mtime
    now = Time.utc(2026, 6, 4, 12, 0, 0)
    old_archived = sample_task(slug: "old-archived", stage: "9-done", marker: "complete")
    old_archived["action"] = "archived"
    old_archived["action_label"] = "Archived"
    old_archived["mtime"] = (now - (5 * 86_400)).utc.iso8601
    old_archived["folder_mtime"] = (now - (5 * 86_400)).utc.iso8601

    recent_archived = sample_task(slug: "recent-archived", stage: "9-done", marker: "complete")
    recent_archived["action"] = "archived"
    recent_archived["action_label"] = "Archived"
    recent_archived["mtime"] = (now - 86_400).utc.iso8601
    recent_archived["folder_mtime"] = (now - 86_400).utc.iso8601

    errored_archived = sample_task(slug: "errored-archived", stage: "9-done", marker: "error")
    errored_archived["action"] = "error"
    errored_archived["action_label"] = "Error"
    errored_archived["mtime"] = (now - (10 * 86_400)).utc.iso8601
    errored_archived["folder_mtime"] = (now - (10 * 86_400)).utc.iso8601

    old_execute = sample_task(slug: "old-execute", stage: "4-execute", marker: "execute_complete")
    old_execute["mtime"] = (now - (99 * 86_400)).utc.iso8601
    old_execute["folder_mtime"] = (now - (99 * 86_400)).utc.iso8601

    snapshot = Hive::Tui::Snapshot.from_payload(sample_payload([
                                                                 {
                                                                   "name" => "alpha",
                                                                   "path" => "/tmp/alpha",
                                                                   "hive_state_path" => "/tmp/alpha/.hive-state",
                                                                   "tasks" => [
                                                                     old_archived,
                                                                     recent_archived,
                                                                     errored_archived,
                                                                     old_execute
                                                                   ]
                                                                 }
                                                               ]))

    filtered = snapshot.without_old_archived(now: now)

    refute_includes filtered.rows.map(&:slug), "old-archived"
    assert_includes filtered.rows.map(&:slug), "recent-archived"
    refute_includes filtered.rows.map(&:slug), "errored-archived"
    assert_includes filtered.rows.map(&:slug), "old-execute"
    assert_equal 2, snapshot.hidden_old_archived_count(now: now)
  end

  def test_without_old_archived_tolerates_blank_or_invalid_mtime
    now = Time.utc(2026, 6, 4, 12, 0, 0)
    blank = sample_task(slug: "blank-mtime", stage: "9-done", marker: "complete")
    blank["mtime"] = ""
    blank["folder_mtime"] = ""
    invalid = sample_task(slug: "invalid-mtime", stage: "9-done", marker: "complete")
    invalid["mtime"] = "not-a-time"
    invalid["folder_mtime"] = "not-a-time"
    snapshot = Hive::Tui::Snapshot.from_payload(sample_payload([
                                                                 {
                                                                   "name" => "alpha",
                                                                   "path" => "/tmp/alpha",
                                                                   "hive_state_path" => "/tmp/alpha/.hive-state",
                                                                   "tasks" => [ blank, invalid ]
                                                                 }
                                                               ]))

    filtered = snapshot.without_old_archived(now: now)

    assert_equal [ "blank-mtime", "invalid-mtime" ], filtered.rows.map(&:slug)
    assert_equal 0, snapshot.hidden_old_archived_count(now: now)
  end
end
