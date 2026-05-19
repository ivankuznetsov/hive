require "test_helper"
require "hive/bot/status_watcher"
require "hive/bot/notification_builders"

class HiveBotNotificationBuildersTest < Minitest::Test
  Row = Hive::Bot::StatusWatcher::Row

  def row(action:, marker:, attrs: {}, slug: "slug-260514-abcd", stage: "2-brainstorm")
    Row.new(
      project: "hive",
      slug: slug,
      stage: stage,
      marker: marker,
      attrs: attrs,
      folder: "/tmp/#{slug}",
      action: action,
      action_label: "label",
      suggested_command: nil
    )
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

  def test_waiting_builds_brainstorm_answer_keyboard
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "needs_input", marker: "waiting")
    )

    assert_match(/Brainstorm questions/, notification.text)
    assert_equal "Answer in chat", notification.keyboard.first.first[:text]
    assert_equal "Ask Codex", notification.keyboard[1].first[:text]
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

  def test_review_waiting_fix_guardrail_builds_operator_keyboard_without_invalid_clear
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "needs_input", marker: "review_waiting", attrs: { "reason" => "fix_guardrail" })
    )

    assert_match(/fix guardrail/i, notification.text)
    labels = notification.keyboard.flatten.map { |button| button[:text] }
    refute_includes labels, "Clear and retry",
                    "REVIEW_WAITING is not a clearable marker — must not surface a clear_retry button"
    assert_includes labels, "Open laptop"
    assert_includes labels, "Show details"
  end

  def test_recovery_marker_builds_full_recovery_keyboard
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "recover_review", marker: "review_error", attrs: { "phase" => "fix", "reason" => "timeout" })
    )

    labels = notification.keyboard.flatten.map { |button| button[:text] }
    # "Refresh diagnosis" is the bot-side parity of the TUI's R
    # keystroke — issue #91. Order is locked so a future keyboard
    # tweak cannot accidentally drop or duplicate the button.
    assert_equal [ "Clear and retry", "Open laptop", "Show details", "Refresh diagnosis" ], labels
  end

  def test_fix_tampered_recovery_falls_back_to_laptop
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "recover_review", marker: "review_error", attrs: { "phase" => "fix", "reason" => "fix_tampered" })
    )

    labels = notification.keyboard.flatten.map { |button| button[:text] }
    refute_includes labels, "Clear and retry"
    assert_equal [ "Open laptop", "Show details", "Refresh diagnosis" ], labels
  end

  def test_refresh_diagnosis_button_carries_callback_with_project_slug_and_stage
    # The button data must round-trip through the router's callback_intent
    # regex (\Arefresh_diagnose:/) and split cleanly into
    # prefix:project:slug:stage for CallbackHandlers#refresh_diagnose.
    # Pin the exact callback shape.
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "recover_review", marker: "review_error",
          attrs: { "phase" => "fix", "reason" => "timeout" })
    )
    refresh_btn = notification.keyboard.flatten.find { |b| b[:text] == "Refresh diagnosis" }
    refute_nil refresh_btn, "Refresh diagnosis button must be present on the recovery keyboard"

    raw = Hive::Bot::NotificationBuilders.resolve_callback(refresh_btn[:callback_data])
    assert raw.start_with?("refresh_diagnose:"),
           "Refresh diagnosis callback must use the refresh_diagnose: prefix; got #{raw.inspect}"
    parts = raw.split(":")
    assert_equal(
      [ "refresh_diagnose", "hive", "slug-260514-abcd", "2-brainstorm" ],
      parts,
      "callback data must be refresh_diagnose:<project>:<slug>:<stage>"
    )
  end

  def test_show_details_button_carries_stage_for_disambiguation
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "recover_review", marker: "review_error",
          attrs: { "phase" => "fix", "reason" => "timeout" }, stage: "6-review")
    )
    details_btn = notification.keyboard.flatten.find { |b| b[:text] == "Show details" }

    assert_equal "details:hive:slug-260514-abcd:6-review",
                 Hive::Bot::NotificationBuilders.resolve_callback(details_btn[:callback_data])
  end

  def test_recovery_notification_appends_diagnostic_summary_when_present
    # Operators reading the bot notification get the "why is this red"
    # one-liner inline instead of needing to round-trip through Show
    # details. Mirrors what the TUI red_status_detail view shows at the
    # top of the screen. See PR #84 review row 23.
    diag = {
      "summary" => "REVIEW_ERROR phase=fix pass=2 reason=timeout",
      "detail" => "agent timed out",
      "generated_by" => "local"
    }
    row_with_diag = row(action: "recover_review", marker: "review_error",
                        attrs: { "phase" => "fix", "reason" => "timeout" })
    # Re-construct with diagnostic since the test helper does not pass it.
    enriched = Row.new(
      project: row_with_diag.project, slug: row_with_diag.slug,
      stage: row_with_diag.stage, marker: row_with_diag.marker,
      attrs: row_with_diag.attrs, folder: row_with_diag.folder,
      action: row_with_diag.action, action_label: row_with_diag.action_label,
      suggested_command: row_with_diag.suggested_command,
      diagnostic: diag
    )

    notification = Hive::Bot::NotificationBuilders.build(enriched)
    assert_includes notification.text, diag["summary"],
                    "recovery notification must surface diagnostic.summary inline"
  end

  def test_recovery_notification_omits_diagnostic_when_nil
    # Pre-schema snapshots / non-red rows return nil diagnostic. The
    # notification must work without the inline summary — the existing
    # "Needs recovery: marker attrs" line carries enough operator signal.
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "recover_review", marker: "review_error",
          attrs: { "phase" => "fix", "reason" => "timeout" })
    )
    refute_nil notification
    assert_match(/Needs recovery/, notification.text)
  end

  def test_fingerprint_changes_when_marker_attrs_change
    first = row(action: "recover_review", marker: "review_error", attrs: { "pass" => "2" })
    second = row(action: "recover_review", marker: "review_error", attrs: { "pass" => "3" })

    refute_equal Hive::Bot::NotificationBuilders.fingerprint(first),
                 Hive::Bot::NotificationBuilders.fingerprint(second)
  end
end
