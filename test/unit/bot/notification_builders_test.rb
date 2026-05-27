require "test_helper"
require "hive/bot/status_watcher"
require "hive/bot/notification_builders"

class HiveBotNotificationBuildersTest < Minitest::Test
  Row = Hive::Bot::StatusWatcher::Row

  def row(action:, marker:, attrs: {}, slug: "slug-260514-abcd", stage: "2-brainstorm",
          diagnostic: nil)
    Row.new(
      project: "hive",
      slug: slug,
      stage: stage,
      marker: marker,
      attrs: attrs,
      folder: "/tmp/#{slug}",
      action: action,
      action_label: "label",
      suggested_command: nil,
      diagnostic: diagnostic
    )
  end

  def legacy_stage_dirs(task_count: 3, command: "hive migrate")
    Hive::Bot::StatusWatcher::LegacyStageDirs.new(
      project: "hive",
      project_path: "/tmp/hive",
      hive_state_path: "/tmp/hive/.hive-state",
      legacy_stage_dirs: [
        { "stage_dir" => "5-review", "task_count" => task_count - 1 },
        { "stage_dir" => "6-pr", "task_count" => 1 }
      ],
      legacy_migrate_command: command
    )
  end

  def retry_diagnostic(command: "hive review slug --json")
    { "suggested_next_action" => { "kind" => "retry", "command" => command } }
  end

  def manual_diagnostic
    { "suggested_next_action" => { "kind" => "manual_fix", "command" => nil } }
  end

  def test_legacy_stage_dirs_notification_renders_project_count_dirs_and_command
    notification = Hive::Bot::NotificationBuilders.build(legacy_stage_dirs)

    assert_equal "Project hive has 3 tasks hidden in legacy stage dirs (5-review, 6-pr) - run `hive migrate /tmp/hive`",
                 notification.text
    assert_nil notification.keyboard
  end

  def test_legacy_stage_dirs_notification_renders_singular_and_command_fallback
    notification = Hive::Bot::NotificationBuilders.build(legacy_stage_dirs(task_count: 1, command: nil))

    assert_equal "Project hive has 1 task hidden in legacy stage dirs (6-pr) - run `hive migrate /tmp/hive`",
                 notification.text
    assert_nil notification.keyboard
  end

  def test_legacy_stage_dirs_notification_handles_malformed_command_payload
    notification = Hive::Bot::NotificationBuilders.build(legacy_stage_dirs(command: "hive 'migrate"))

    assert_equal "Project hive has 3 tasks hidden in legacy stage dirs (5-review, 6-pr) - run `hive migrate /tmp/hive`",
                 notification.text
    assert_nil notification.keyboard
  end

  def test_ready_to_plan_builds_approval_keyboard
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "ready_to_plan", marker: "complete")
    )

    assert_match(/Ready for plan/, notification.text)
    assert_equal "Approve", notification.keyboard.first.first[:text]
    assert_match(/\Aapprove:plan:hive:slug-260514-abcd:2-brainstorm\z/,
                 notification.keyboard.first.first[:callback_data])
  end

  def test_ready_to_open_pr_builds_current_open_pr_keyboard
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "ready_to_open_pr", marker: "execute_complete", stage: "4-execute")
    )

    assert_match(/Ready for open-pr/, notification.text)
    assert_equal "approve:open-pr:hive:slug-260514-abcd:4-execute",
                 notification.keyboard.first.first[:callback_data]
  end

  def test_ready_to_artifacts_builds_artifacts_approval_keyboard
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "ready_to_artifacts", marker: "review_complete", stage: "6-review")
    )

    assert_match(/Ready for artifacts/, notification.text)
    assert_equal "approve:artifacts:hive:slug-260514-abcd:6-review",
                 notification.keyboard.first.first[:callback_data]
  end

  def test_ready_to_finalize_builds_finalize_approval_keyboard
    # ready_to_finalize replaced ready_for_pr after the rename in
    # bfbaaad / hive.rb. The bot's READY_ACTIONS and verb_for_action
    # tables must follow or every "Ready to finalize" row falls
    # through `build()` and gets NO Telegram notification. See PR #84
    # review C2.
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "ready_to_finalize", marker: "complete", stage: "7-artifacts")
    )

    refute_nil notification, "ready_to_finalize must produce a notification (not silently fall through)"
    assert_match(/Ready for finalize/, notification.text)
    assert_equal "approve:finalize:hive:slug-260514-abcd:7-artifacts",
                 notification.keyboard.first.first[:callback_data]
  end

  def test_legacy_ready_for_pr_does_not_silently_match_old_table
    # Guard against re-introduction of the stale ready_for_pr key in
    # READY_ACTIONS / verb_for_action. If a future refactor brings it
    # back, this test catches it before the bot starts ghosting users.
    refute_includes Hive::Bot::NotificationBuilders::READY_ACTIONS, "ready_for_pr",
                    "ready_for_pr was renamed to ready_to_finalize in bfbaaad"
    assert_nil Hive::Bot::NotificationBuilders.verb_for_action("ready_for_pr"),
               "verb_for_action must not resolve the legacy ready_for_pr key"
    assert_equal "artifacts", Hive::Bot::NotificationBuilders.verb_for_action("ready_to_artifacts")
    assert_equal "finalize", Hive::Bot::NotificationBuilders.verb_for_action("ready_to_finalize")
  end

  def test_waiting_builds_brainstorm_answer_keyboard
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "needs_input", marker: "waiting")
    )

    assert_match(/Brainstorm questions/, notification.text)
    assert_match(/provide input/, notification.text)
    assert_match(%r{/answer slug-260514-abcd}, notification.text)
    labels = notification.keyboard.flatten.map { |button| button[:text] }
    assert_equal [ "Answer in chat" ], labels,
                 "brainstorm-waiting keyboard is deterministic Q-by-Q only — no Codex draft, no laptop button"
  end

  def test_generic_needs_input_marker_builds_show_details_only_keyboard
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "needs_input", marker: "agent_waiting", attrs: { "reason" => "operator" })
    )

    assert_match(/Needs input: agent_waiting reason=operator/, notification.text)
    labels = notification.keyboard.flatten.map { |button| button[:text] }
    assert_equal [ "Show details" ], labels,
                 "the only useful action for an unknown waiting marker is Show details"
  end

  def test_compacted_callback_round_trips
    long_slug = "slug-" + ("a" * 80)
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "ready_to_plan", marker: "complete", slug: long_slug)
    )
    token = notification.keyboard.first.first[:callback_data]

    assert_operator token.bytesize, :<=, Hive::Bot::NotificationBuilders::CALLBACK_DATA_MAX
    assert_match(/\A#approve:/, token)
    assert_equal "approve:plan:hive:#{long_slug}:2-brainstorm",
                 Hive::Bot::NotificationBuilders.resolve_callback(token)
  end

  def test_review_waiting_fix_guardrail_builds_show_details_only_keyboard
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "needs_input", marker: "review_waiting", attrs: { "reason" => "fix_guardrail" })
    )

    assert_match(/fix guardrail/i, notification.text)
    labels = notification.keyboard.flatten.map { |button| button[:text] }
    refute_includes labels, "Clear and retry",
                    "REVIEW_WAITING is not a clearable marker — must not surface a clear_retry button"
    refute_includes labels, "Open laptop",
                    "Open laptop was retired — operators are on Telegram and the button has no payload"
    assert_includes labels, "Show details"
  end

  def test_review_waiting_non_guardrail_builds_findings_triage_keyboard
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "needs_input", marker: "review_waiting", attrs: { "reason" => "needs_findings" })
    )

    assert_match(/Review triage is waiting/, notification.text)
    labels = notification.keyboard.flatten.map { |button| button[:text] }
    assert_includes labels, "Accept all"
    assert_includes labels, "Reject all"
    assert_includes labels, "Show details"
  end

  def test_recovery_match_attr_review_stale_uses_pass_reason
    attrs = { "pass" => "3", "reason" => "timeout" }
    r = row(action: "recover_review", marker: "review_stale", attrs: attrs)
    autofix = Hive::Bot::NotificationBuilders.autofix_callback(r)
    assert_match(/:pass=3\z/, autofix,
                 "review_stale must drive recovery_match_attr toward the pass=<n> key")
  end

  def test_recovery_match_attr_error_prefers_marker_id
    attrs = { "reason" => "exit_code", "exit_code" => "137", "marker_id" => "err-137" }
    r = row(action: "error", marker: "error", attrs: attrs)
    autofix = Hive::Bot::NotificationBuilders.autofix_callback(r)
    assert_match(/:marker_id=err-137\z/, autofix,
                 "generic `error` marker must prefer the high-cardinality marker_id guard")
  end

  def test_recovery_match_attr_error_legacy_falls_back_to_observed_attrs
    attrs = { "reason" => "exit_code", "exit_code" => "137" }
    r = row(action: "error", marker: "error", attrs: attrs)
    autofix = Hive::Bot::NotificationBuilders.autofix_callback(r)
    assert_match(/:reason=exit_code,exit_code=137\z/, autofix,
                 "legacy `error` marker must use observed reason and exit_code together")
  end

  def test_recovery_match_attr_unknown_marker_omits_match_attr_suffix
    r = row(action: "recover_execute", marker: "execute_stale", attrs: { "pass" => "1" })
    autofix = Hive::Bot::NotificationBuilders.autofix_callback(r)
    refute_match(/=/, autofix.split(":").last.to_s,
                 "unknown-to-recovery_match_attr markers must produce a no-match_attr callback")
  end

  def test_recovery_marker_builds_plain_language_autofix_notification
    notification = Hive::Bot::NotificationBuilders.build(
      row(
        action: "recover_review",
        marker: "review_error",
        attrs: { "phase" => "fix", "reason" => "timeout", "exception_class" => "Encoding::CompatibilityError" },
        slug: "we-need-to-improve-this-260522-db23",
        stage: "6-review",
        diagnostic: retry_diagnostic(command: "hive review we-need-to-improve-this-260522-db23 --json")
      )
    )

    assert_includes notification.text, "⚠ Review stuck — \"We need to improve this…\""
    assert_includes notification.text, "The review agent crashed before it could finish."
    assert_includes notification.text, "Tap Autofix to retry the stage cleanly."
    refute_includes notification.text, "phase="
    refute_includes notification.text, "reason="
    refute_includes notification.text, "marker"
    refute_includes notification.text, "exception_class"
    refute_includes notification.text, "-260522-db23"
    refute_includes notification.text, "(6-review)"
    refute_includes notification.text, "Encoding::CompatibilityError"
  end

  def test_recovery_keyboard_is_single_autofix_button
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "recover_review", marker: "review_error", attrs: { "pass" => "2" },
          slug: "we-need-to-improve-this-260522-db23", stage: "6-review",
          diagnostic: retry_diagnostic)
    )

    assert_equal 1, notification.keyboard.length
    assert_equal 1, notification.keyboard.first.length
    button = notification.keyboard.first.first
    assert_equal "🔧 Autofix", button[:text]
    assert_equal "autofix:hive:we-need-to-improve-this-260522-db23:6-review:review_error:pass=2",
                 Hive::Bot::NotificationBuilders.resolve_callback(button[:callback_data])
  end

  def test_manual_recovery_diagnostic_does_not_offer_autofix
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "recover_execute", marker: "execute_stale", stage: "4-execute",
          diagnostic: manual_diagnostic)
    )

    assert_includes notification.text, "Tap Show details to see what needs manual intervention."
    labels = notification.keyboard.flatten.map { |button| button[:text] }
    assert_equal [ "Show details" ], labels,
                 "manual recovery surfaces Show details only — no Autofix, no laptop button"
    refute_includes labels, "🔧 Autofix"
  end

  def test_fix_tampered_review_error_does_not_offer_autofix
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "recover_review", marker: "review_error",
          attrs: { "phase" => "fix", "reason" => "fix_tampered" },
          stage: "6-review", diagnostic: retry_diagnostic)
    )

    labels = notification.keyboard.flatten.map { |button| button[:text] }
    refute_includes labels, "🔧 Autofix"
    refute_includes labels, "Open laptop",
                    "Open laptop button retired everywhere"
    assert_includes labels, "Show details"
  end

  def test_cause_sentence_for_execute_stale
    r = row(action: "recover_review", marker: "execute_stale")
    notification = Hive::Bot::NotificationBuilders.build(r)
    assert_includes notification.text, "The execute agent stalled before it could finish."
  end

  def test_cause_sentence_for_review_stale
    r = row(action: "recover_review", marker: "review_stale")
    notification = Hive::Bot::NotificationBuilders.build(r)
    assert_includes notification.text, "The review run stalled before it could finish."
  end

  def test_cause_sentence_for_review_ci_stale
    r = row(action: "recover_review", marker: "review_ci_stale")
    notification = Hive::Bot::NotificationBuilders.build(r)
    assert_includes notification.text, "The review run stalled before it could finish."
  end

  def test_cause_sentence_for_unknown_marker_uses_generic_fallback
    r = row(action: "recover_review", marker: "totally_unknown_marker")
    notification = Hive::Bot::NotificationBuilders.build(r)
    assert_includes notification.text, "The agent crashed before it could finish."
  end

  def test_fingerprint_changes_when_marker_attrs_change
    first = row(action: "recover_review", marker: "review_error", attrs: { "pass" => "2" })
    second = row(action: "recover_review", marker: "review_error", attrs: { "pass" => "3" })

    refute_equal Hive::Bot::NotificationBuilders.fingerprint(first),
                 Hive::Bot::NotificationBuilders.fingerprint(second)
  end

  def test_fingerprint_changes_when_stage_changes
    first = row(action: "recover_review", marker: "review_error", attrs: { "pass" => "2" }, stage: "5-open-pr")
    second = row(action: "recover_review", marker: "review_error", attrs: { "pass" => "2" }, stage: "6-review")

    refute_equal Hive::Bot::NotificationBuilders.fingerprint(first),
                 Hive::Bot::NotificationBuilders.fingerprint(second)
  end
end
