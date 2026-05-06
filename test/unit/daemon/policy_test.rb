require "test_helper"
require "hive/daemon/policy"

# Pin Hive::Daemon::Policy's decision matrix. The daemon's safety
# guarantees rest on this module being a closed-default switch over the
# `Hive::Schemas::TaskActionKind` enum: any action not in the explicit
# advance / merge / edit-resume sets returns :skip, including unknown
# future values added forward-compat-style.
class HiveDaemonPolicyTest < Minitest::Test
  T0 = Time.utc(2026, 5, 6, 12, 0, 0)

  # ── advance actions: workflow-verb advances ────────────────────────────

  def test_ready_to_brainstorm_dispatches
    assert_equal :dispatch, decide(action: "ready_to_brainstorm",
                                   command: "hive brainstorm slug-a")
  end

  def test_ready_to_plan_dispatches
    assert_equal :dispatch, decide(action: "ready_to_plan",
                                   command: "hive plan slug-a --from 2-brainstorm")
  end

  def test_ready_to_develop_dispatches
    assert_equal :dispatch, decide(action: "ready_to_develop",
                                   command: "hive develop slug-a --from 3-plan")
  end

  def test_ready_for_review_dispatches
    assert_equal :dispatch, decide(action: "ready_for_review",
                                   command: "hive review slug-a --from 4-execute")
  end

  def test_ready_for_pr_dispatches
    assert_equal :dispatch, decide(action: "ready_for_pr",
                                   command: "hive pr slug-a --from 5-review")
  end

  # ── merge wait: hand off to PrMergeWatcher ─────────────────────────────

  def test_ready_to_archive_polls_for_merge
    # Even though the suggested_command is `hive archive ...`, the
    # daemon does NOT dispatch it directly — it routes to U10
    # PrMergeWatcher which gates on `gh pr view --json state == MERGED`.
    assert_equal :poll_for_merge, decide(action: "ready_to_archive",
                                         command: "hive archive slug-a --from 6-pr")
  end

  # ── edit-resume: mtime-debounced re-runs ───────────────────────────────

  def test_needs_input_first_sight_with_settled_mtime_dispatches
    # No prior dispatch + mtime > debounce ago → fresh entry, dispatch.
    assert_equal :dispatch, decide(action: "needs_input",
                                   command: "hive brainstorm slug-a --from 2-brainstorm",
                                   state_file_mtime: T0 - 60,
                                   last_dispatched_state_file_mtime: nil)
  end

  def test_needs_input_first_sight_with_fresh_mtime_waits_for_debounce
    # No prior dispatch but mtime is fresh — operator might still be
    # typing. Wait for the file to settle.
    assert_equal :wait_for_debounce, decide(action: "needs_input",
                                            command: "hive brainstorm slug-a --from 2-brainstorm",
                                            state_file_mtime: T0 - 5,
                                            last_dispatched_state_file_mtime: nil)
  end

  def test_needs_input_unchanged_mtime_skips
    # Prior dispatch already happened; mtime hasn't moved → user
    # hasn't provided new input yet, nothing to do.
    assert_equal :skip, decide(action: "needs_input",
                               command: "hive brainstorm slug-a --from 2-brainstorm",
                               state_file_mtime: T0 - 600,
                               last_dispatched_state_file_mtime: T0 - 600)
  end

  def test_needs_input_mtime_moved_within_debounce_waits
    # User edited 5s ago, debounce is 30s — wait.
    assert_equal :wait_for_debounce, decide(action: "needs_input",
                                            command: "hive brainstorm slug-a --from 2-brainstorm",
                                            state_file_mtime: T0 - 5,
                                            last_dispatched_state_file_mtime: T0 - 600)
  end

  def test_needs_input_mtime_moved_past_debounce_dispatches
    # User edited 60s ago, debounce is 30s — file has settled, fire.
    assert_equal :dispatch, decide(action: "needs_input",
                                   command: "hive brainstorm slug-a --from 2-brainstorm",
                                   state_file_mtime: T0 - 60,
                                   last_dispatched_state_file_mtime: T0 - 600)
  end

  def test_needs_input_with_nil_mtime_skips
    # Defensive: status row malformation (state file deleted between
    # status emission and consumer fetch) → don't crash, just skip.
    assert_equal :skip, decide(action: "needs_input",
                               command: "hive brainstorm slug-a --from 2-brainstorm",
                               state_file_mtime: nil,
                               last_dispatched_state_file_mtime: nil)
  end

  def test_review_findings_treated_as_edit_resume
    # Legacy 4-execute findings path (mostly inert post-ADR-014 since
    # 5-review owns triage). Still classified as edit-resume so the
    # daemon respects user edits to the findings file.
    assert_equal :dispatch, decide(action: "review_findings",
                                   command: "hive findings slug-a",
                                   state_file_mtime: T0 - 600,
                                   last_dispatched_state_file_mtime: nil)
  end

  def test_custom_debounce_respected
    # Operator can tune the debounce window via daemon.edit_debounce_sec.
    # 90s edit + 60s debounce → dispatch; 30s edit + 60s debounce → wait.
    assert_equal :dispatch, decide(action: "needs_input",
                                   command: "hive plan slug-a --from 3-plan",
                                   state_file_mtime: T0 - 90,
                                   last_dispatched_state_file_mtime: T0 - 600,
                                   edit_debounce_sec: 60)
    assert_equal :wait_for_debounce, decide(action: "needs_input",
                                            command: "hive plan slug-a --from 3-plan",
                                            state_file_mtime: T0 - 30,
                                            last_dispatched_state_file_mtime: T0 - 600,
                                            edit_debounce_sec: 60)
  end

  # ── skip actions: human-required states ────────────────────────────────

  def test_recover_execute_skips
    assert_equal :skip, decide(action: "recover_execute",
                               command: "hive findings slug-a")
  end

  def test_recover_review_skips
    # Includes :review_stale, :review_ci_stale, :review_error per
    # Hive::TaskAction's classifier. Daemon must NOT auto-clear
    # recovery markers (origin "Outside this product's identity").
    assert_equal :skip, decide(action: "recover_review",
                               command: nil)
  end

  def test_agent_running_skips
    # In-flight task — per-task .lock would block double-spawn anyway,
    # but skipping here saves the noise and keeps the global concurrency
    # cap accurate.
    assert_equal :skip, decide(action: "agent_running",
                               command: nil)
  end

  def test_archived_skips
    # 7-done with :complete marker: terminal, no further work.
    assert_equal :skip, decide(action: "archived",
                               command: nil)
  end

  def test_error_skips
    assert_equal :skip, decide(action: "error",
                               command: nil)
  end

  # ── defensive / forward-compat ─────────────────────────────────────────

  def test_unknown_action_skips
    # Closed-default: any future TaskActionKind value the daemon
    # doesn't know about is :skip until the daemon is taught.
    assert_equal :skip, decide(action: "totally_made_up", command: "echo hi")
  end

  def test_nil_action_skips
    assert_equal :skip, decide(action: nil, command: nil)
  end

  def test_advance_action_with_nil_command_skips
    # Defensive: status surface should always emit a command for
    # advance actions, but if it doesn't, refuse to dispatch a nil.
    assert_equal :skip, decide(action: "ready_to_plan", command: nil)
  end

  def test_advance_action_with_empty_command_skips
    assert_equal :skip, decide(action: "ready_to_plan", command: "")
  end

  private

  def decide(action:, command:, state_file_mtime: nil,
             last_dispatched_state_file_mtime: nil, now: T0, edit_debounce_sec: 30)
    Hive::Daemon::Policy.decide(
      action: action,
      command: command,
      state_file_mtime: state_file_mtime,
      last_dispatched_state_file_mtime: last_dispatched_state_file_mtime,
      now: now,
      edit_debounce_sec: edit_debounce_sec
    )
  end
end
