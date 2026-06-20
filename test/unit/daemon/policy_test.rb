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
                                   command: "hive review slug-a --from 5-open-pr")
  end

  def test_ready_to_open_pr_dispatches
    assert_equal :dispatch, decide(action: "ready_to_open_pr",
                                   command: "hive open-pr slug-a --from 4-execute")
  end

  def test_ready_to_artifacts_dispatches
    assert_equal :dispatch, decide(action: "ready_to_artifacts",
                                   command: "hive artifacts slug-a --from 6-review")
  end

  def test_ready_to_finalize_dispatches
    assert_equal :dispatch, decide(action: "ready_to_finalize",
                                   command: "hive finalize slug-a --from 7-artifacts")
  end

  def test_ready_to_advance_dispatches
    assert_equal :dispatch, decide(action: "ready_to_advance",
                                   command: "hive approve slug-a --from 2-gather")
  end

  def test_ready_to_run_dispatches
    assert_equal :dispatch, decide(action: "ready_to_run",
                                   command: "hive run slug-a")
  end

  def test_coding_policy_decision_matrix_is_characterized
    # U6 characterization: adding generic workflow dispatch keys must leave
    # the existing coding daemon policy outcomes byte-for-byte equivalent.
    cases = [
      {
        name: "advance",
        expected: :dispatch,
        args: { action: "ready_to_develop", stage: "3-plan",
                command: "hive develop slug-a --from 3-plan" }
      },
      {
        name: "plan approval",
        expected: :dispatch,
        args: { action: "needs_input", stage: "3-plan",
                command: "hive plan slug-a --from 3-plan",
                state_file_mtime: T0 - 60,
                last_dispatched_state_file_mtime: nil }
      },
      {
        name: "edit resume",
        expected: :dispatch,
        args: { action: "needs_input", stage: "2-brainstorm",
                command: "hive brainstorm slug-a --from 2-brainstorm",
                state_file_mtime: T0 - 60,
                last_dispatched_state_file_mtime: T0 - 600 }
      },
      {
        name: "merge wait",
        expected: :poll_for_merge,
        args: { action: "ready_to_archive", stage: "8-finalize",
                command: "hive archive slug-a --from 8-finalize" }
      }
    ]

    cases.each do |example|
      assert_equal example.fetch(:expected), decide(**example.fetch(:args)), example.fetch(:name)
    end
  end

  # ── merge wait: hand off to PrMergeWatcher ─────────────────────────────

  def test_ready_to_archive_polls_for_merge
    # Even though the suggested_command is `hive archive ...`, the
    # daemon does NOT dispatch it directly — it routes to U10
    # PrMergeWatcher which gates on `gh pr view --json state == MERGED`.
    assert_equal :poll_for_merge, decide(action: "ready_to_archive",
                                         command: "hive archive slug-a --from 8-finalize")
  end

  # ── dependency gate ───────────────────────────────────────────────────

  def test_blocked_advance_action_does_not_dispatch
    assert_equal :blocked_on_dependency,
                 decide(action: "ready_to_develop",
                        command: "hive develop slug-a --from 3-plan",
                        blocked: true)
  end

  def test_blocked_ready_to_advance_does_not_dispatch
    assert_equal :blocked_on_dependency,
                 decide(action: "ready_to_advance",
                        command: "hive approve slug-a --from 2-gather",
                        blocked: true)
  end

  def test_blocked_ready_to_run_does_not_dispatch
    assert_equal :blocked_on_dependency,
                 decide(action: "ready_to_run",
                        command: "hive run slug-a",
                        blocked: true)
  end

  def test_unblocked_advance_action_dispatches_normally
    assert_equal :dispatch,
                 decide(action: "ready_to_develop",
                        command: "hive develop slug-a --from 3-plan",
                        blocked: false)
  end

  def test_blocked_plan_approval_does_not_dispatch
    assert_equal :blocked_on_dependency,
                 decide(action: "needs_input",
                        stage: "3-plan",
                        command: "hive develop slug-a --from 3-plan",
                        state_file_mtime: T0 - 600,
                        last_dispatched_state_file_mtime: nil,
                        blocked: true)
  end

  def test_blocked_edit_resume_records_baseline_before_gate
    assert_equal :record_baseline,
                 decide(action: "needs_input",
                        command: "hive brainstorm slug-a --from 2-brainstorm",
                        state_file_mtime: T0 - 60,
                        last_dispatched_state_file_mtime: nil,
                        blocked: true)
  end

  def test_blocked_edit_resume_does_not_dispatch_after_debounce
    assert_equal :blocked_on_dependency,
                 decide(action: "needs_input",
                        command: "hive brainstorm slug-a --from 2-brainstorm",
                        state_file_mtime: T0 - 60,
                        last_dispatched_state_file_mtime: T0 - 600,
                        blocked: true)
  end

  def test_blocked_does_not_suppress_merge_polling
    assert_equal :poll_for_merge,
                 decide(action: "ready_to_archive",
                        command: "hive archive slug-a --from 8-finalize",
                        blocked: true)
  end

  # ── edit-resume: mtime-debounced re-runs ───────────────────────────────

  def test_needs_input_first_sight_records_baseline
    # PR-40 review P1 #1: first-sight `kind: edit` cannot distinguish
    # "agent just wrote WAITING" from "user already answered". The
    # safe choice is to skip + record the current mtime as baseline;
    # the dispatcher seeds the controller. The next genuine user edit
    # (mtime > baseline) triggers a dispatch.
    assert_equal :record_baseline, decide(action: "needs_input",
                                          command: "hive brainstorm slug-a --from 2-brainstorm",
                                          state_file_mtime: T0 - 60,
                                          last_dispatched_state_file_mtime: nil)
  end

  def test_plan_needs_input_dispatches_without_mtime_edit
    # Plan-stage WAITING is an approval pause, not a request for fresh
    # typed answers. In daemon-enabled projects, enabling the daemon is
    # the approval gesture, so the generated plan should advance to
    # develop without requiring a user to open and close the file.
    assert_equal :dispatch, decide(action: "needs_input",
                                   stage: "3-plan",
                                   command: "hive develop slug-a --from 3-plan",
                                   state_file_mtime: T0 - 600,
                                   last_dispatched_state_file_mtime: nil)
  end

  def test_generic_plan_named_needs_input_does_not_hit_coding_plan_approval
    assert_equal :record_baseline,
                 decide(action: "needs_input",
                        workflow: "dispatch",
                        stage: "3-plan",
                        command: "hive run slug-a",
                        state_file_mtime: T0 - 600,
                        last_dispatched_state_file_mtime: nil)
  end

  def test_needs_input_first_sight_with_fresh_mtime_records_baseline
    # First-sight always records baseline regardless of mtime age.
    assert_equal :record_baseline, decide(action: "needs_input",
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

  def test_needs_input_after_agent_write_does_not_redispatch
    # PR-40 review P1 #1: agent's own write of `_WAITING` bumps mtime,
    # but the Dispatcher refreshes `last_dispatched_state_file_mtime`
    # to the post-completion value. Status's snapshot mtime equals the
    # recorded mtime → :skip (no spurious re-dispatch).
    agent_post_write_mtime = T0 - 100
    assert_equal :skip, decide(action: "needs_input",
                               command: "hive brainstorm slug-a --from 2-brainstorm",
                               state_file_mtime: agent_post_write_mtime,
                               last_dispatched_state_file_mtime: agent_post_write_mtime)
  end

  def test_needs_input_after_user_edit_dispatches_when_debounce_clears
    # User edits AFTER agent's write → state_file_mtime > recorded.
    # If debounce has elapsed, dispatch.
    agent_post_write = T0 - 600
    user_edit = T0 - 60
    assert_equal :dispatch, decide(action: "needs_input",
                                   command: "hive brainstorm slug-a --from 2-brainstorm",
                                   state_file_mtime: user_edit,
                                   last_dispatched_state_file_mtime: agent_post_write)
  end

  def test_needs_input_after_user_edit_within_debounce_waits
    agent_post_write = T0 - 600
    user_edit_recent = T0 - 5
    assert_equal :wait_for_debounce, decide(action: "needs_input",
                                            command: "hive brainstorm slug-a --from 2-brainstorm",
                                            state_file_mtime: user_edit_recent,
                                            last_dispatched_state_file_mtime: agent_post_write)
  end

  def test_legacy_review_findings_string_still_skips
    # `review_findings` used to be a real action key (TUI-triage entry
    # point) but was removed from the schema by PR #122. Pins the
    # daemon's forward-compat default branch: the literal string still
    # routes to `:skip` rather than dispatching its command, so a
    # hand-crafted state file or replayed legacy snapshot can't
    # accidentally auto-dispatch `hive findings` (a read-only listing).
    # See ADR-028 in wiki/decisions.md for the in-place schema edit.
    assert_equal :skip, decide(action: "review_findings",
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

  def test_manual_steering_skips
    assert_equal :skip, decide(action: "manual_steering",
                               command: nil)
  end

  def test_manual_steering_skips_even_after_state_file_edit
    assert_equal :skip, decide(action: "manual_steering",
                               command: nil,
                               state_file_mtime: T0 - 60,
                               last_dispatched_state_file_mtime: T0 - 600)
  end

  def test_archived_skips
    # 9-done with :complete marker: terminal, no further work.
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

  def test_ready_to_advance_with_nil_command_skips
    assert_equal :skip, decide(action: "ready_to_advance", command: nil)
  end

  def test_plan_approval_matches_only_literal_3_plan_stage
    # PR #83 code review finding #4 (cross-corroborated by 4
    # reviewers): the earlier `/\A\d+-plan\z/` regex matched any
    # digit-prefixed plan stage. Only `"3-plan"` exists in
    # `Hive::Stages::DIRS`, so any other `N-plan` value coming
    # through the status surface (typo, future renumbering,
    # hostile injection) should take the standard mtime-debounce
    # path, NOT auto-dispatch. With `stage: nil` and a non-nil
    # mtime + nil last_dispatched, the brainstorm-shaped behavior
    # is :record_baseline.
    assert_equal :record_baseline,
                 decide(action: "needs_input", stage: "1-plan",
                        command: "hive plan slug-a --from 1-plan",
                        state_file_mtime: T0 - 60,
                        last_dispatched_state_file_mtime: nil)
    assert_equal :record_baseline,
                 decide(action: "needs_input", stage: "13-plan",
                        command: "hive plan slug-a --from 13-plan",
                        state_file_mtime: T0 - 60,
                        last_dispatched_state_file_mtime: nil)
    # Positive control: real "3-plan" still auto-dispatches.
    assert_equal :dispatch,
                 decide(action: "needs_input", stage: "3-plan",
                        command: "hive plan slug-a --from 3-plan",
                        state_file_mtime: T0 - 60,
                        last_dispatched_state_file_mtime: nil)
  end

  def test_plan_approval_dispatches_on_subsequent_tick_with_unchanged_mtime
    # PR #83 code review finding #8: pin the contrast between the
    # brainstorm-path (same-mtime returns :skip because user hasn't
    # edited since last dispatch) and the plan-path (must still
    # return :dispatch because plan_approval? fires BEFORE
    # decide_edit). A refactor reordering the branches in
    # Policy#decide would silently break second-and-later ticks
    # while every existing test still passes.
    same_mtime = T0 - 600
    # Brainstorm-stage control: same mtime + non-nil last_dispatched
    # → :skip via decide_edit's "mtime hasn't moved" branch.
    assert_equal :skip,
                 decide(action: "needs_input", stage: "2-brainstorm",
                        command: "hive brainstorm slug-a --from 2-brainstorm",
                        state_file_mtime: same_mtime,
                        last_dispatched_state_file_mtime: same_mtime),
                 "brainstorm path: unchanged mtime since last dispatch → :skip (sanity)"
    # Plan-stage: plan_approval? fires first, returns :dispatch
    # regardless of mtime state. This is what makes the auto-advance
    # work — the brainstorm rule does not apply.
    assert_equal :dispatch,
                 decide(action: "needs_input", stage: "3-plan",
                        command: "hive plan slug-a --from 3-plan",
                        state_file_mtime: same_mtime,
                        last_dispatched_state_file_mtime: same_mtime),
                 "plan path: plan_approval? fires before decide_edit; subsequent ticks must still :dispatch"
  end

  def test_plan_approval_with_nil_or_empty_command_skips
    # PR #83 code review finding #3: the nil-command guard must
    # explicitly cover plan_approval? rows, not rely on the
    # accidental overlap with edit_resume? (`needs_input` is in
    # both sets today, but a future refactor extending plan_approval?
    # to a non-edit_resume action would silently lose this coverage
    # and a malformed status row would dispatch a nil command).
    assert_equal :skip, decide(action: "needs_input", stage: "3-plan", command: nil)
    assert_equal :skip, decide(action: "needs_input", stage: "3-plan", command: "")
  end

  # ── answers_pending gate (brainstorm Q&A) ──────────────────────────────

  def test_needs_input_holds_dispatch_when_answers_pending
    # Would dispatch (mtime past debounce), but unanswered questions remain.
    assert_equal :wait_for_answers,
                 decide(action: "needs_input",
                        command: "hive brainstorm slug-a --from 2-brainstorm",
                        state_file_mtime: T0 - 60,
                        last_dispatched_state_file_mtime: T0 - 600,
                        answers_pending: true)
  end

  def test_needs_input_dispatches_when_answers_complete
    assert_equal :dispatch,
                 decide(action: "needs_input",
                        command: "hive brainstorm slug-a --from 2-brainstorm",
                        state_file_mtime: T0 - 60,
                        last_dispatched_state_file_mtime: T0 - 600,
                        answers_pending: false)
  end

  def test_blocked_takes_precedence_over_answers_pending_on_debounced_resume
    # A debounced edit-resume row that is BOTH dependency-blocked and has
    # unanswered Q&A must resolve to the dependency gate, not the Q&A hold —
    # the `blocked` branch is checked before `answers_pending`. A future
    # reordering of those two branches would otherwise pass CI.
    assert_equal :blocked_on_dependency,
                 decide(action: "needs_input",
                        command: "hive brainstorm slug-a --from 2-brainstorm",
                        state_file_mtime: T0 - 60,
                        last_dispatched_state_file_mtime: T0 - 600,
                        answers_pending: true,
                        blocked: true)
  end

  def test_answers_pending_does_not_override_record_baseline
    # First-sight must still seed the baseline even while answers pend,
    # otherwise the editor-bulk-save path would never get a baseline to
    # compare against and could never resume.
    assert_equal :record_baseline,
                 decide(action: "needs_input",
                        command: "hive brainstorm slug-a --from 2-brainstorm",
                        state_file_mtime: T0 - 60,
                        last_dispatched_state_file_mtime: nil,
                        answers_pending: true)
  end

  def test_answers_pending_does_not_override_debounce_or_skip
    assert_equal :wait_for_debounce,
                 decide(action: "needs_input",
                        command: "hive brainstorm slug-a --from 2-brainstorm",
                        state_file_mtime: T0 - 5,
                        last_dispatched_state_file_mtime: T0 - 600,
                        answers_pending: true)
    assert_equal :skip,
                 decide(action: "needs_input",
                        command: "hive brainstorm slug-a --from 2-brainstorm",
                        state_file_mtime: T0 - 100,
                        last_dispatched_state_file_mtime: T0 - 100,
                        answers_pending: true)
  end

  private

  def decide(action:, command:, stage: nil, workflow: nil, state_file_mtime: nil,
             last_dispatched_state_file_mtime: nil, now: T0, edit_debounce_sec: 30,
             answers_pending: false, blocked: false)
    Hive::Daemon::Policy.decide(
      action: action,
      stage: stage,
      workflow: workflow,
      command: command,
      state_file_mtime: state_file_mtime,
      last_dispatched_state_file_mtime: last_dispatched_state_file_mtime,
      now: now,
      edit_debounce_sec: edit_debounce_sec,
      answers_pending: answers_pending,
      blocked: blocked
    )
  end
end
