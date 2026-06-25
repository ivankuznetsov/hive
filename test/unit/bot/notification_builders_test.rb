require "test_helper"
require "hive/bot/status_watcher"
require "hive/bot/notification_builders"

class HiveBotNotificationBuildersTest < Minitest::Test
  Row = Hive::Bot::StatusWatcher::Row

  def row(action:, marker:, attrs: {}, slug: "slug-260514-abcd", stage: "2-brainstorm",
          diagnostic: nil, id: nil, display_name: nil, pr_url: nil, workflow: "coding")
    Row.new(
      project: "hive",
      slug: slug,
      id: id,
      display_name: display_name,
      stage: stage,
      workflow: workflow,
      marker: marker,
      attrs: attrs,
      folder: "/tmp/#{slug}",
      action: action,
      action_label: "label",
      suggested_command: nil,
      diagnostic: diagnostic,
      pr_url: pr_url
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

  def assert_live_agent_skip_logged(logger, marker:, action:, slug: "slug-260514-abcd", stage: "4-execute")
    assert_equal 1, logger.events.size
    event, attrs = logger.events.first
    assert_equal :notification_skipped_live_agent, event
    assert_equal "hive", attrs[:project]
    assert_equal slug, attrs[:slug]
    assert_equal stage, attrs[:stage]
    assert_equal marker, attrs[:marker]
    assert_equal action, attrs[:action]
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
      row(action: "ready_to_plan", marker: "complete", id: 42, display_name: "Readable Plan")
    )

    assert_includes notification.text, "#42 Readable Plan — Brainstorm"
    assert_match(/Ready for plan/, notification.text)
    assert_equal "Approve", notification.keyboard.first.first[:text]
    assert_match(/\Aapprove:plan:hive:slug-260514-abcd:2-brainstorm\z/,
                 notification.keyboard.first.first[:callback_data])
  end

  def test_generic_ready_to_advance_builds_approve_keyboard
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "ready_to_advance", marker: "complete", stage: "2-gather", workflow: "research")
    )

    refute_nil notification, "a generic ready_to_advance row must produce a Telegram notification"
    assert_equal "approve:approve:hive:slug-260514-abcd:2-gather",
                 notification.keyboard.first.first[:callback_data]
  end

  def test_generic_ready_to_run_builds_run_keyboard
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "ready_to_run", marker: "none", stage: "1-intake", workflow: "research")
    )

    refute_nil notification, "a generic ready_to_run row must produce a Telegram notification"
    assert_equal "approve:run:hive:slug-260514-abcd:1-intake",
                 notification.keyboard.first.first[:callback_data]
  end

  def test_verb_for_action_maps_generic_ready_actions
    assert_equal "approve", Hive::Bot::NotificationBuilders.verb_for_action("ready_to_advance")
    assert_equal "run", Hive::Bot::NotificationBuilders.verb_for_action("ready_to_run")
  end

  def test_display_title_handles_name_without_id_and_slug_fallback
    named = row(action: "needs_input", marker: "waiting", display_name: "Named Only")
    legacy = row(action: "needs_input", marker: "waiting", slug: "task-260514-abcd")

    assert_equal "Named Only", Hive::Bot::NotificationBuilders.display_title(named)
    assert_equal "Task…", Hive::Bot::NotificationBuilders.display_title(legacy)
  end

  def test_ready_to_open_pr_builds_current_open_pr_keyboard
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "ready_to_open_pr", marker: "execute_complete", stage: "4-execute")
    )

    assert_match(/Ready for open-pr/, notification.text)
    assert_equal "approve:open-pr:hive:slug-260514-abcd:4-execute",
                 notification.keyboard.first.first[:callback_data]
  end

  def test_ready_for_review_appends_clickable_pr_link
    notification = Hive::Bot::NotificationBuilders.build(
      row(
        action: "ready_for_review",
        marker: "complete",
        stage: "5-open-pr",
        id: 12,
        display_name: "Fix <Login> & More",
        pr_url: "https://github.com/example/repo/pull/561"
      )
    )

    assert_equal :html, notification.parse_mode
    assert_includes notification.text, "#12 Fix &lt;Login&gt; &amp; More — Open PR"
    assert_includes notification.text, "Ready for review."
    assert_includes notification.text, 'PR: <a href="https://github.com/example/repo/pull/561">#561</a>'
    assert_equal "approve:review:hive:slug-260514-abcd:5-open-pr",
                 notification.keyboard.first.first[:callback_data]
  end

  def test_ready_for_review_without_pr_url_stays_plain
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "ready_for_review", marker: "complete", stage: "5-open-pr")
    )

    assert_nil notification.parse_mode
    assert_match(/Ready for review/, notification.text)
    refute_includes notification.text, "PR:"
  end

  def test_notification_accepts_documented_parse_modes
    plain = Hive::Bot::NotificationBuilders::Notification.new(text: "hi", keyboard: nil)
    html = Hive::Bot::NotificationBuilders::Notification.new(text: "hi", keyboard: nil, parse_mode: :html)

    assert_nil plain.parse_mode
    assert_equal :html, html.parse_mode
  end

  def test_notification_rejects_unsupported_parse_mode
    error = assert_raises(ArgumentError) do
      Hive::Bot::NotificationBuilders::Notification.new(text: "hi", keyboard: nil, parse_mode: :markdown)
    end

    assert_match(/unsupported parse_mode :markdown/, error.message)
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

  def test_generic_waiting_row_uses_neutral_details_notification
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "needs_input", marker: "waiting", stage: "2-gather", workflow: "dispatch")
    )

    assert_match(/Needs input: waiting/, notification.text)
    refute_match(/Brainstorm questions/, notification.text)
    labels = notification.keyboard.flatten.map { |button| button[:text] }
    assert_equal [ "Show details" ], labels
  end

  # Characterization (A7): a coding `waiting` marker only ever appears at
  # 2-brainstorm / 3-plan in practice (supervisor.rb / notification_dispatcher),
  # so the U6 routing migration is inert for coding. Pin that a coding `waiting`
  # at ANY other stage (e.g. 5-open-pr, 8-finalize) falls through to the neutral
  # "Needs input" / "Show details" default rather than the brainstorm "Answer in
  # chat" affordance — preserving the byte-identical-coding mandate. Restoring
  # the old unconditional brainstorm routing would be wrong: it would mislabel a
  # generic row as "Brainstorm questions".
  def test_coding_waiting_outside_brainstorm_and_plan_uses_neutral_default
    %w[5-open-pr 8-finalize].each do |stage|
      notification = Hive::Bot::NotificationBuilders.build(
        row(action: "needs_input", marker: "waiting", stage: stage, workflow: "coding")
      )

      assert_match(/Needs input: waiting/, notification.text,
                   "coding waiting at #{stage} must use the neutral default, not brainstorm copy")
      refute_match(/Brainstorm questions/, notification.text)
      refute_match(/Answer in chat/, notification.text,
                   "coding waiting at #{stage} must not offer the brainstorm /answer affordance")
      labels = notification.keyboard.flatten.map { |button| button[:text] }
      assert_equal [ "Show details" ], labels
    end
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

  def test_agent_running_error_marker_is_suppressed_and_logged
    logger = StubLogger.new
    r = row(action: "agent_running", marker: "error", stage: "4-execute")

    assert_nil Hive::Bot::NotificationBuilders.build(r, logger: logger)
    assert_live_agent_skip_logged(logger, marker: "error", action: "agent_running")
  end

  def test_error_action_error_marker_still_builds_recovery_notification
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "error", marker: "error", stage: "4-execute")
    )

    refute_nil notification
    assert_includes notification.text, "⚠ Execute stuck"
    assert_includes notification.text, "Tap Show details to see what needs manual intervention."
  end

  def test_recover_actions_still_build_recovery_notifications
    recover_execute = Hive::Bot::NotificationBuilders.build(
      row(action: "recover_execute", marker: "execute_stale", stage: "4-execute")
    )
    recover_review = Hive::Bot::NotificationBuilders.build(
      row(action: "recover_review", marker: "review_error", stage: "6-review")
    )

    assert_includes recover_execute.text, "⚠ Execute stuck"
    assert_includes recover_review.text, "⚠ Review stuck"
  end

  def test_agent_running_suppresses_all_stale_recovery_markers
    logger = StubLogger.new
    markers = %w[review_stale execute_stale review_error review_ci_stale]

    markers.each do |marker|
      assert_nil Hive::Bot::NotificationBuilders.build(
        row(action: "agent_running", marker: marker, stage: "6-review"),
        logger: logger
      )
    end

    assert_equal markers, logger.events.map { |_name, attrs| attrs[:marker] }
    assert(logger.events.all? { |name, attrs| name == :notification_skipped_live_agent && attrs[:action] == "agent_running" })
  end

  def test_archived_error_marker_is_suppressed
    logger = StubLogger.new
    assert_nil Hive::Bot::NotificationBuilders.build(
      row(action: "archived", marker: "error", stage: "9-done"), logger: logger
    )
    # The archived contradiction must stay diagnosable: the skip log fires with
    # the row's own action ("archived"), not a hardcoded "agent_running". A
    # regression that narrowed the log gate to agent_running, or hardcoded the
    # action, would drop this — line coverage alone (shared with the
    # agent_running gate) would not catch it.
    assert_live_agent_skip_logged(logger, marker: "error", action: "archived", stage: "9-done")
  end

  def test_bug_9281_agent_running_error_fixture_is_suppressed_and_logged_once
    logger = StubLogger.new
    slug = "bug-agentlimit-false-positives-on-260623-a4df"
    r = row(action: "agent_running", marker: "error", slug: slug, stage: "4-execute")

    assert_nil Hive::Bot::NotificationBuilders.build(r, logger: logger)
    assert_live_agent_skip_logged(logger, marker: "error", action: "agent_running", slug: slug)
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

  def test_recovery_match_attr_error_encodes_marker_id_and_reason
    attrs = { "reason" => "exit_code", "exit_code" => "137", "marker_id" => "err-137" }
    r = row(action: "error", marker: "error", attrs: attrs)
    autofix = Hive::Bot::NotificationBuilders.autofix_callback(r)
    # F1: when a marker_id is present, encode `marker_id=<hex>,reason=<r>` as
    # a comma-separated pair so the callback handler's attrs_from_match_attr
    # round-trip reconstructs both keys. manual_only? gates on `reason` to
    # refuse dirty_worktree / ensure_clean_on_exit_failed retries on the
    # inline-button path. marker_id stays the LEADING token so AlertStore's
    # first-token guard (parse_match_attr) keeps using it as the race-safe
    # invalidation key.
    assert_match(/:marker_id=err-137,reason=exit_code\z/, autofix,
                 "generic `error` marker must carry marker_id (race-safe guard) + reason " \
                 "(manual-only routing key), leading with marker_id")
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
        id: 42,
        display_name: "Improve Recovery",
        stage: "6-review",
        diagnostic: retry_diagnostic(command: "hive review we-need-to-improve-this-260522-db23 --json")
      )
    )

    assert_includes notification.text, "⚠ Review stuck — \"#42 Improve Recovery\""
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

  def test_fix_status_check_failed_review_error_does_not_offer_autofix
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "recover_review", marker: "review_error",
          attrs: { "phase" => "fix", "reason" => "fix_status_check_failed", "pass" => "1" },
          stage: "6-review", diagnostic: retry_diagnostic)
    )

    assert_includes notification.text, "Tap Show details to see what needs manual intervention."
    labels = notification.keyboard.flatten.map { |button| button[:text] }
    refute_includes labels, "🔧 Autofix"
    assert_equal [ "Show details" ], labels
  end

  def test_cause_sentence_for_review_error_reviewer_partial_failure
    r = row(action: "recover_review", marker: "review_error",
            attrs: { "phase" => "reviewers", "reason" => "reviewer_partial_failure", "pass" => "1" },
            stage: "6-review")
    notification = Hive::Bot::NotificationBuilders.build(r)
    assert_includes notification.text,
                    "Some reviewers failed; the reviewers that ran found nothing, so review coverage is incomplete."
    refute_includes notification.text, "The review agent crashed before it could finish."
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

  def test_fingerprint_ignores_pr_url
    without_pr = row(action: "ready_for_review", marker: "complete", stage: "5-open-pr")
    with_pr = row(
      action: "ready_for_review",
      marker: "complete",
      stage: "5-open-pr",
      pr_url: "https://github.com/example/repo/pull/561"
    )

    assert_equal Hive::Bot::NotificationBuilders.fingerprint(without_pr),
                 Hive::Bot::NotificationBuilders.fingerprint(with_pr)
  end

  class StubLogger
    attr_reader :events

    def initialize
      @events = []
    end

    def event(name, **attrs)
      @events << [ name, attrs ]
    end
  end
end
