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
      "closure" => {
        "status" => "complete",
        "reason" => "already_delivered",
        "receipt_digest" => "a" * 64
      },
      "marker" => marker,
      "attrs" => {},
      "mtime" => "2026-04-27T12:00:00Z",
      "observation_mtime" => "2026-04-27T11:59:30Z",
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
    assert_equal "already_delivered", first.closure.fetch("reason")
    assert_equal "waiting", first.marker
    assert_equal({}, first.attrs)
    assert_equal "2026-04-27T12:00:00Z", first.mtime
    assert_equal "2026-04-27T11:59:30Z", first.observation_mtime
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

  def test_from_payload_defaults_missing_additive_mtimes_to_nil
    row = sample_task(slug: "legacy-payload")
    row.delete("observation_mtime")
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

    assert_nil snapshot.rows.first.observation_mtime
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

  def test_snapshot_uses_producer_rows_and_hidden_count_without_reclassifying_mtime
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
                                                                     old_execute
                                                                   ],
                                                                   "hidden_archived_task_count" => 2
                                                                 }
                                                               ]))

    visible = snapshot.visible_projection(scope: 0, filter: nil, now: now)

    assert_equal snapshot.rows, visible.rows
    assert_includes visible.rows.map(&:slug), "old-archived",
                    "Snapshot must not re-evaluate producer rows from task mtime"
    assert_equal 2, snapshot.hidden_archived_task_count
    refute_includes Hive::Tui::Snapshot::Row.members, :hidden_archived_task_count
  end

  def test_snapshot_keeps_dedicated_archive_rows_separate_from_ordinary_rows
    old_archived = sample_task(slug: "old-archived", stage: "9-done", marker: "complete")
    old_archived["action"] = "archived"
    old_archived["action_label"] = "Archived"
    recent_archived = sample_task(slug: "recent-archived", stage: "9-done", marker: "complete")
    recent_archived["action"] = "archived"
    recent_archived["action_label"] = "Archived"
    active = sample_task(slug: "active")

    ordinary = sample_payload([
      {
        "name" => "alpha",
        "path" => "/tmp/alpha",
        "hive_state_path" => "/tmp/alpha/.hive-state",
        "tasks" => [ recent_archived, active ],
        "hidden_archived_task_count" => 1
      }
    ])
    archive = sample_payload([
      {
        "name" => "alpha",
        "path" => "/tmp/alpha",
        "hive_state_path" => "/tmp/alpha/.hive-state",
        "tasks" => [ old_archived, recent_archived ]
      }
    ])

    snapshot = Hive::Tui::Snapshot.from_payload(ordinary, archive_payload: archive)

    assert_equal [ "recent-archived", "active" ].sort, snapshot.rows.map(&:slug).sort
    assert_equal [ "old-archived", "recent-archived" ].sort,
                 snapshot.archive_rows.map(&:slug).sort
    assert_equal 1, snapshot.hidden_archived_task_count
  end

  def test_hidden_archived_count_respects_project_scope
    snapshot = Hive::Tui::Snapshot.from_payload(sample_payload([
      { "name" => "alpha", "tasks" => [], "hidden_archived_task_count" => 1 },
      { "name" => "beta", "tasks" => [], "hidden_archived_task_count" => 2 }
    ]))

    assert_equal 3, snapshot.hidden_archived_task_count
    assert_equal 1, snapshot.hidden_archived_task_count(scope: 1)
    assert_equal 2, snapshot.hidden_archived_task_count(scope: 2)
    assert_equal 0, snapshot.hidden_archived_task_count(scope: 99)
  end

  def test_new_idea_admission_keeps_only_unique_healthy_projects_in_registry_order
    snapshot = Hive::Tui::Snapshot.from_payload(sample_payload([
      { "name" => "beta", "tasks" => [] },
      { "name" => "duplicate", "tasks" => [] },
      { "name" => "broken", "error" => "missing_project_path", "tasks" => [] },
      { "name" => "duplicate", "tasks" => [] },
      { "name" => "alpha", "tasks" => [] }
    ]))

    admission = snapshot.new_idea_admission

    assert_equal :available, admission.state
    assert_equal %w[beta alpha], admission.projects.map(&:name)
    assert_equal [ "duplicate" ], admission.ambiguous_names
    assert_predicate admission, :frozen?
    assert_predicate admission.projects, :frozen?
    assert_predicate admission.ambiguous_names, :frozen?
    assert_raises(FrozenError) { admission.projects << snapshot.projects.first }
  end

  def test_new_idea_admission_distinguishes_unhealthy_ambiguous_and_empty_snapshots
    unhealthy = Hive::Tui::Snapshot.from_payload(sample_payload([
      { "name" => "broken-a", "error" => "missing_project_path", "tasks" => [] },
      { "name" => "broken-b", "error" => "not_initialised", "tasks" => [] }
    ])).new_idea_admission
    both_healthy = Hive::Tui::Snapshot.from_payload(sample_payload([
      { "name" => "duplicate", "tasks" => [] },
      { "name" => "duplicate", "tasks" => [] }
    ])).new_idea_admission
    mixed_health = Hive::Tui::Snapshot.from_payload(sample_payload([
      { "name" => "duplicate", "tasks" => [] },
      { "name" => "duplicate", "error" => "not_initialised", "tasks" => [] }
    ])).new_idea_admission
    empty = Hive::Tui::Snapshot.from_payload(sample_payload([])).new_idea_admission

    assert_equal :unhealthy, unhealthy.state
    assert_empty unhealthy.projects
    assert_equal :repair_projects, unhealthy.recovery
    assert_equal :ambiguous, both_healthy.state
    assert_equal [ "duplicate" ], both_healthy.ambiguous_names
    assert_equal :ambiguous, mixed_health.state,
      "duplicate-name ambiguity must take precedence over project health"
    assert_equal [ "duplicate" ], mixed_health.ambiguous_names
    assert_equal :no_projects, empty.state
  end

  def test_new_idea_admission_classifies_recovery_without_exposing_raw_errors
    missing_only = Hive::Tui::Snapshot.from_payload(sample_payload([
      { "name" => "broken-a", "error" => "missing_project_path", "tasks" => [] },
      { "name" => "broken-b", "error" => "missing_project_path", "tasks" => [] }
    ])).new_idea_admission
    mixed = Hive::Tui::Snapshot.from_payload(sample_payload([
      { "name" => "broken-a", "error" => "missing_project_path", "tasks" => [] },
      { "name" => "broken-b", "error" => "not_initialised", "tasks" => [] }
    ])).new_idea_admission

    assert_equal :prune_missing, missing_only.recovery
    assert_equal :repair_projects, mixed.recovery
    refute_respond_to missing_only, :unhealthy_errors
  end

  def test_new_idea_admission_names_blank_registry_identity
    [
      [ { "name" => nil, "tasks" => [] } ],
      [ { "name" => "", "tasks" => [] }, { "name" => nil, "tasks" => [] } ]
    ].each do |projects|
      admission = Hive::Tui::Snapshot.from_payload(sample_payload(projects)).new_idea_admission

      assert_equal :invalid_identity, admission.state
      assert_equal :repair_registry, admission.recovery
      assert_empty admission.projects
      assert_empty admission.ambiguous_names
    end
  end

  def test_new_idea_admission_stays_registry_wide_on_scope_and_filter_projections
    snapshot = Hive::Tui::Snapshot.from_payload(sample_payload([
      { "name" => "alpha", "tasks" => [ { "slug" => "visible", "stage" => "1-inbox" } ] },
      { "name" => "beta", "tasks" => [] }
    ]))

    scoped = snapshot.scope_to_project_index(1)
    filtered = snapshot.filter_by_slug("visible")
    empty_scope = snapshot.scope_to_project_index(99)

    assert_same snapshot.new_idea_admission, scoped.new_idea_admission
    assert_same snapshot.new_idea_admission, filtered.new_idea_admission
    assert_same snapshot.new_idea_admission, empty_scope.new_idea_admission
    assert_equal %w[alpha beta], scoped.new_idea_admission.projects.map(&:name)
  end

  def test_new_idea_value_objects_reject_unknown_states
    assert_raises(ArgumentError) do
      Hive::Tui::Snapshot::NewIdeaAdmission.new(state: :unknown, projects: [])
    end
    assert_raises(ArgumentError) do
      Hive::Tui::Snapshot::NewIdeaResolution.new(state: :unknown)
    end
    assert_raises(ArgumentError) do
      Hive::Tui::Snapshot::NewIdeaAdmission.new(
        state: :unhealthy,
        projects: [],
        recovery: :unknown
      )
    end
  end

  def test_new_idea_name_resolution_is_closed_and_ambiguity_precedes_health
    snapshot = Hive::Tui::Snapshot.from_payload(sample_payload([
      { "name" => "alpha", "tasks" => [] },
      { "name" => "broken", "error" => "missing_project_path", "tasks" => [] },
      { "name" => "duplicate", "tasks" => [] },
      { "name" => "duplicate", "error" => "not_initialised", "tasks" => [] }
    ]))

    available = snapshot.resolve_new_idea_project(name: "alpha")
    unhealthy = snapshot.resolve_new_idea_project(name: "broken")
    ambiguous = snapshot.resolve_new_idea_project(name: "duplicate")
    disappeared = snapshot.resolve_new_idea_project(name: "ghost")
    required = snapshot.resolve_new_idea_project(name: nil)

    assert_equal :available, available.state
    assert_equal "alpha", available.name
    assert_same snapshot.projects.first, available.project
    assert_predicate available, :available?
    assert_predicate available, :frozen?
    assert_equal :unhealthy, unhealthy.state
    assert_equal "missing_project_path", unhealthy.detail
    assert_equal :ambiguous, ambiguous.state
    assert_equal :disappeared, disappeared.state
    assert_equal :selection_required, required.state
    refute_predicate ambiguous, :available?
  end

  def test_new_idea_resolution_preserves_pinned_disappearance_for_an_empty_snapshot
    snapshot = Hive::Tui::Snapshot.from_payload(sample_payload([]))

    disappeared = snapshot.resolve_new_idea_project(name: "ghost")

    assert_equal :disappeared, disappeared.state
    assert_equal "ghost", disappeared.name
    assert_equal :no_projects, snapshot.resolve_new_idea_project(name: nil).state
    assert_equal :no_projects, snapshot.resolve_new_idea_entry(scope: 1).state
  end

  def test_new_idea_entry_resolution_rejects_invalid_scopes_and_name_conflicts
    snapshot = Hive::Tui::Snapshot.from_payload(sample_payload([
      { "name" => "alpha", "tasks" => [] },
      { "name" => "beta", "tasks" => [] }
    ]))

    [ 0, -1, 3, "1", nil ].each do |scope|
      resolution = snapshot.resolve_new_idea_entry(scope: scope)
      assert_equal :invalid_scope, resolution.state, "expected #{scope.inspect} to be invalid"
      scope.nil? ? assert_nil(resolution.detail) : assert_equal(scope, resolution.detail)
    end

    conflict = snapshot.resolve_new_idea_entry(scope: 1, name: "alpha")
    available = snapshot.resolve_new_idea_entry(scope: 2)

    assert_equal :invalid_scope, conflict.state
    assert_equal "alpha", conflict.name
    assert_equal :available, available.state
    assert_equal "beta", available.name
  end

  def test_new_idea_entry_resolution_reuses_name_policy_for_unhealthy_and_ambiguous_rows
    snapshot = Hive::Tui::Snapshot.from_payload(sample_payload([
      { "name" => "broken", "error" => "missing_project_path", "tasks" => [] },
      { "name" => "duplicate", "tasks" => [] },
      { "name" => "duplicate", "error" => "not_initialised", "tasks" => [] }
    ]))

    assert_equal :unhealthy, snapshot.resolve_new_idea_entry(scope: 1).state
    assert_equal :ambiguous, snapshot.resolve_new_idea_entry(scope: 2).state
    assert_equal :ambiguous, snapshot.resolve_new_idea_entry(scope: 3).state
  end

  def test_new_idea_numeric_scope_is_consumed_once_then_revalidates_only_the_pinned_name
    original = Hive::Tui::Snapshot.from_payload(sample_payload([
      { "name" => "alpha", "tasks" => [] },
      { "name" => "beta", "tasks" => [] }
    ]))
    reordered = Hive::Tui::Snapshot.from_payload(sample_payload([
      { "name" => "beta", "tasks" => [] },
      { "name" => "alpha", "tasks" => [] }
    ]))
    removed = Hive::Tui::Snapshot.from_payload(sample_payload([
      { "name" => "alpha", "tasks" => [] }
    ]))

    entry = original.resolve_new_idea_entry(scope: 2)
    pinned_name = entry.name

    assert_equal "beta", pinned_name
    assert_equal :available, reordered.resolve_new_idea_project(name: pinned_name).state
    assert_equal "beta", reordered.resolve_new_idea_project(name: pinned_name).name
    assert_equal :disappeared, removed.resolve_new_idea_project(name: pinned_name).state
  end

  def test_invalid_numeric_entry_stays_unpinned_after_a_valid_refresh
    original = Hive::Tui::Snapshot.from_payload(sample_payload([
      { "name" => "alpha", "tasks" => [] }
    ]))
    refreshed = Hive::Tui::Snapshot.from_payload(sample_payload([
      { "name" => "alpha", "tasks" => [] },
      { "name" => "beta", "tasks" => [] }
    ]))

    entry = original.resolve_new_idea_entry(scope: 9)

    assert_equal :invalid_scope, entry.state
    assert_nil entry.project
    assert_equal :selection_required,
      refreshed.resolve_new_idea_project(name: entry.name).state,
      "refresh must not reinterpret the stale numeric position"
  end
end
