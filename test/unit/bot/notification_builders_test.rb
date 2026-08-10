require "test_helper"
require "hive/bot/status_watcher"
require "hive/bot/notification_builders"

class HiveBotNotificationBuildersTest < Minitest::Test
  include HiveTestHelper

  Row = Hive::Bot::StatusWatcher::Row

  def row(action:, marker:, attrs: {}, slug: "slug-260514-abcd", stage: "2-brainstorm",
          diagnostic: nil, id: nil, display_name: nil, pr_url: nil, workflow: "coding",
          folder: "/tmp/slug-260514-abcd", state_file: nil, suggested_command: nil, next_action: nil)
    Row.new(
      project: "hive",
      slug: slug,
      id: id,
      display_name: display_name,
      stage: stage,
      workflow: workflow,
      marker: marker,
      attrs: attrs,
      folder: folder,
      state_file: state_file,
      action: action,
      action_label: "label",
      suggested_command: suggested_command,
      next_action: next_action,
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

  def test_closure_callback_encoder_rejects_unknown_prefix
    error = assert_raises(ArgumentError) do
      Hive::Bot::NotificationBuilders.encode_closure_callback(
        "delete_task", "slug" => "task"
      )
    end

    assert_equal "unsupported closure callback", error.message
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

  def test_ready_actions_share_task_action_commands
    assert_equal Hive::TaskAction::READY_COMMANDS.keys,
                 Hive::Bot::NotificationBuilders::READY_ACTIONS
    Hive::TaskAction::READY_COMMANDS.each do |action, command|
      assert_equal command, Hive::Bot::NotificationBuilders.verb_for_action(action)
    end
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

  def test_generic_waiting_row_uses_neutral_run_notification
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "needs_input", marker: "waiting", stage: "2-gather", workflow: "dispatch")
    )

    assert_match(/Needs input: waiting/, notification.text)
    refute_match(/Brainstorm questions/, notification.text)
    labels = notification.keyboard.flatten.map { |button| button[:text] }
    assert_equal [ "Run" ], labels
    assert_equal "rerun:hive:slug-260514-abcd:2-gather:run",
                 notification.keyboard.flatten.first[:callback_data]
  end

  def test_coding_waiting_outside_brainstorm_and_plan_gets_working_button
    %w[5-open-pr].each do |stage|
      notification = Hive::Bot::NotificationBuilders.build(
        row(action: "needs_input", marker: "waiting", stage: stage, workflow: "coding")
      )

      assert_match(/Needs input: waiting/, notification.text,
                   "coding waiting at #{stage} must use the neutral default, not brainstorm copy")
      refute_match(/Brainstorm questions/, notification.text)
      refute_match(/Answer in chat/, notification.text,
                   "coding waiting at #{stage} must not offer the brainstorm /answer affordance")
      labels = notification.keyboard.flatten.map { |button| button[:text] }
      assert_equal [ "Run" ], labels
    end
  end

  def test_generic_needs_input_marker_builds_run_keyboard
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "needs_input", marker: "agent_waiting", attrs: { "reason" => "operator" })
    )

    assert_match(/Needs input: agent_waiting reason=operator/, notification.text)
    labels = notification.keyboard.flatten.map { |button| button[:text] }
    assert_equal [ "Run" ], labels
    assert_equal "rerun:hive:slug-260514-abcd:2-brainstorm:run",
                 notification.keyboard.flatten.first[:callback_data]
  end

  def test_needs_input_raises_for_unexpected_resolution_kind
    original = Hive::Bot::RowActions.method(:resolve)
    fake_resolution_class = Struct.new(:actions, :kind) do
      def suppress
        false
      end
    end
    fake_resolution = fake_resolution_class.new([ Object.new ], :unexpected_waiting)
    Hive::Bot::RowActions.define_singleton_method(:resolve) { |_row| fake_resolution }

    error = assert_raises(ArgumentError) do
      Hive::Bot::NotificationBuilders.build(row(action: "needs_input", marker: "agent_waiting"))
    end

    assert_match(/unexpected resolution kind :unexpected_waiting/, error.message)
  ensure
    Hive::Bot::RowActions.singleton_class.send(:remove_method, :resolve)
    Hive::Bot::RowActions.define_singleton_method(:resolve, &original)
  end

  def test_plan_waiting_builds_approve_and_details_keyboard
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "needs_input", marker: "waiting", stage: "3-plan")
    )

    assert_match(/Plan draft is ready/, notification.text)
    labels = notification.keyboard.flatten.map { |button| button[:text] }
    assert_equal [ "Approve", "Show details" ], labels
    callbacks = notification.keyboard.flatten.map { |button| button[:callback_data] }
    assert_equal [
      "approve_plan:hive:slug-260514-abcd:3-plan",
      "details:hive:slug-260514-abcd:3-plan"
    ], callbacks
  end

  def test_execute_waiting_builds_rerun_and_details_keyboard
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "needs_input", marker: "execute_waiting", stage: "4-execute")
    )

    assert_match(/Execute paused — needs your input/, notification.text)
    labels = notification.keyboard.flatten.map { |button| button[:text] }
    assert_equal [ "Re-run", "Show details" ], labels
    callbacks = notification.keyboard.flatten.map { |button| button[:callback_data] }
    assert_equal [
      "rerun:hive:slug-260514-abcd:4-execute:develop",
      "details:hive:slug-260514-abcd:4-execute"
    ], callbacks
  end

  def test_finalize_waiting_builds_run_and_details_keyboard
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "needs_input", marker: "waiting", stage: "8-finalize")
    )

    assert_match(/Finalize paused — ready to run/, notification.text)
    labels = notification.keyboard.flatten.map { |button| button[:text] }
    assert_equal [ "Run", "Show details" ], labels
    callbacks = notification.keyboard.flatten.map { |button| button[:callback_data] }
    assert_equal [
      "rerun:hive:slug-260514-abcd:8-finalize:finalize",
      "details:hive:slug-260514-abcd:8-finalize"
    ], callbacks
  end

  def test_needs_input_rejects_unexpected_row_action_resolution_kind
    primary = Hive::Bot::RowActions::Action.new(
      role: :approve,
      callback: "approve:run:hive:slug-260514-abcd:3-plan",
      primary: true
    )
    unexpected = Hive::Bot::RowActions::Resolution.new(actions: [ primary ], kind: :stage_approval)

    error = with_replaced_singleton_method(Hive::Bot::RowActions, :resolve, ->(_row) { unexpected }) do
      assert_raises(ArgumentError) do
        Hive::Bot::NotificationBuilders.build(row(action: "needs_input", marker: "waiting"))
      end
    end

    assert_match(/unexpected resolution kind :stage_approval/, error.message)
  end

  def test_none_and_complete_needs_input_rows_are_suppressed
    %w[none complete].each do |marker|
      assert_nil Hive::Bot::NotificationBuilders.build(row(action: "needs_input", marker: marker)),
                 "marker=#{marker} needs_input rows must not push a notification"
    end
  end

  def test_needs_input_raises_for_unmapped_resolution_kind
    action = Hive::Bot::RowActions.action(:details, "details:hive:slug-260514-abcd:3-plan", primary: true)
    unexpected_resolution = Struct.new(:suppress, :actions, :kind).new(false, [ action ], :mystery)
    original = Hive::Bot::RowActions.method(:resolve)
    Hive::Bot::RowActions.define_singleton_method(:resolve) { |_row| unexpected_resolution }

    error = begin
      assert_raises(ArgumentError) do
        Hive::Bot::NotificationBuilders.build(row(action: "needs_input", marker: "waiting"))
      end
    ensure
      Hive::Bot::RowActions.singleton_class.send(:remove_method, :resolve)
      Hive::Bot::RowActions.define_singleton_method(:resolve, &original)
    end

    assert_match(/unexpected resolution kind :mystery/, error.message)
  end

  def test_details_reply_for_default_needs_input_has_summary_and_laptop_hint
    text = Hive::Bot::NotificationBuilders.details_reply(
      row(action: "needs_input", marker: "agent_waiting", attrs: { "reason" => "operator" },
          workflow: "dispatch", stage: "2-gather", diagnostic: nil)
    )

    assert_includes text, "Slug… — hive/slug-260514-abcd (2-gather)"
    assert_includes text, "Action: label"
    assert_includes text, "Marker: agent_waiting"
    assert_includes text, "Attrs: reason=operator"
    assert_includes text, "Open on a laptop to advance."
    refute_includes text, "No diagnostic available"
  end

  def test_details_reply_prefers_structured_next_step_when_available
    text = Hive::Bot::NotificationBuilders.details_reply(
      row(action: "needs_input", marker: "waiting", workflow: "research", stage: "2-gather",
          next_action: { "kind" => "run", "command" => "hive run slug-260514-abcd" })
    )

    assert_includes text, "Next step: hive run slug-260514-abcd"
    refute_includes text, "Open on a laptop to advance."
  end

  def test_details_reply_structured_next_action_command_wins_over_flat_suggested_command
    # next_step_hint precedence contract: a present structured
    # next_action["command"] wins over the flat suggested_command. Set BOTH to
    # different non-blank values so an inverted-precedence refactor fails here
    # (each single-field test alone would still pass after such a flip).
    text = Hive::Bot::NotificationBuilders.details_reply(
      row(action: "needs_input", marker: "agent_waiting", workflow: "research", stage: "2-gather",
          next_action: { "kind" => "run", "command" => "hive run STRUCTURED" },
          suggested_command: "hive run FLAT")
    )

    assert_includes text, "Next step: hive run STRUCTURED"
    refute_includes text, "hive run FLAT"
  end

  def test_details_reply_falls_back_to_flat_command_when_structured_next_action_lacks_command
    # next_step_hint's "present next_action Hash but blank/missing command →
    # fall back to flat suggested_command" branch: only the nil-next_action
    # fallback was exercised before.
    text = Hive::Bot::NotificationBuilders.details_reply(
      row(action: "needs_input", marker: "agent_waiting", workflow: "research", stage: "2-gather",
          next_action: { "kind" => "run" },
          suggested_command: "hive run slug-260514-abcd")
    )

    assert_includes text, "Next step: hive run slug-260514-abcd"
  end

  def test_details_reply_for_coding_brainstorm_waiting_points_to_answer
    text = Hive::Bot::NotificationBuilders.details_reply(
      row(action: "needs_input", marker: "waiting", stage: "2-brainstorm", workflow: "coding")
    )

    assert_includes text, "Reply /answer slug-260514-abcd to provide input."
    refute_includes text, "No diagnostic available"
  end

  def test_details_reply_for_plan_waiting_points_to_plan_and_approval
    text = Hive::Bot::NotificationBuilders.details_reply(
      row(action: "needs_input", marker: "waiting", stage: "3-plan", workflow: "coding",
          state_file: "/tmp/slug-260514-abcd/plan.md")
    )

    assert_includes text, "Plan draft: /tmp/slug-260514-abcd/plan.md"
    assert_includes text, "Approve when ready with /approve slug-260514-abcd."
    refute_match(/diagnostic/i, text)
  end

  def test_details_reply_for_plan_waiting_still_appends_present_diagnostic
    # Plan rows carry nil diagnostics in practice, so the refute_match above
    # passes trivially. details_reply appends a present diagnostic regardless
    # of surface (plan U1 step 3): pin that a plan_waiting row WITH a populated
    # diagnostic still gets it appended, so the nil-only guard above can't mask
    # a regression in that surface-independent contract.
    text = Hive::Bot::NotificationBuilders.details_reply(
      row(action: "needs_input", marker: "waiting", stage: "3-plan", workflow: "coding",
          state_file: "/tmp/slug-260514-abcd/plan.md",
          diagnostic: { "summary" => "PLAN_DIAG summary", "detail" => "plan diagnostic detail" })
    )

    assert_includes text, "Plan draft: /tmp/slug-260514-abcd/plan.md"
    assert_includes text, "Approve when ready with /approve slug-260514-abcd."
    assert_includes text, "PLAN_DIAG summary"
    assert_includes text, "plan diagnostic detail"
  end

  def test_details_reply_for_review_waiting_fix_guardrail_has_fix_hint
    text = Hive::Bot::NotificationBuilders.details_reply(
      row(action: "needs_input", marker: "review_waiting", stage: "6-review",
          attrs: { "reason" => "fix_guardrail" })
    )

    assert_includes text, "Open on a laptop to inspect the fix before continuing."
  end

  def test_details_reply_for_manual_recovery_includes_cause_manual_hint_folder_and_diagnostic
    diagnostic = {
      "summary" => "EXECUTE_STALE pass=1",
      "detail" => "execute log tail"
    }
    text = Hive::Bot::NotificationBuilders.details_reply(
      row(action: "recover_execute", marker: "execute_stale", stage: "4-execute",
          folder: "/tmp/slug-260514-abcd", diagnostic: diagnostic)
    )

    assert_includes text, "The execute agent stalled before it could finish."
    assert_includes text, "Hive has no automatic recovery for this state - open it on a laptop."
    assert_includes text, "Logs/artifacts: /tmp/slug-260514-abcd"
    assert_includes text, "EXECUTE_STALE pass=1"
    assert_includes text, "execute log tail"
  end

  def test_details_reply_appends_diagnostic_only_when_present
    diagnostic = { "summary" => "REVIEW_ERROR pass=2", "detail" => "review detail" }
    with_diagnostic = Hive::Bot::NotificationBuilders.details_reply(
      row(action: "recover_review", marker: "review_error", stage: "6-review",
          diagnostic: diagnostic)
    )
    without_diagnostic = Hive::Bot::NotificationBuilders.details_reply(
      row(action: "recover_review", marker: "review_error", stage: "6-review",
          diagnostic: nil)
    )

    assert_includes with_diagnostic, "REVIEW_ERROR pass=2"
    assert_includes with_diagnostic, "review detail"
    refute_includes without_diagnostic, "REVIEW_ERROR pass=2"
    assert_includes without_diagnostic, "Slug… — hive/slug-260514-abcd (6-review)"
  end

  def test_details_reply_truncates_oversized_diagnostic_detail_to_telegram_limit
    text = Hive::Bot::NotificationBuilders.details_reply(
      row(action: "recover_review", marker: "review_error", stage: "6-review",
          diagnostic: { "summary" => "REVIEW_ERROR pass=2", "detail" => "x" * 6000 })
    )

    assert_operator text.length, :<=, Hive::Bot::NotificationBuilders::TELEGRAM_MESSAGE_MAX_CHARS
    assert text.end_with?(Hive::Bot::NotificationBuilders::DETAILS_TRUNCATION_MARKER)
  end

  def test_details_reply_truncates_oversized_summary_without_diagnostic
    text = Hive::Bot::NotificationBuilders.details_reply(
      row(action: "needs_input", marker: "agent_waiting", display_name: "x" * 6000,
          workflow: "dispatch", stage: "2-gather", diagnostic: nil)
    )

    assert_operator text.length, :<=, Hive::Bot::NotificationBuilders::TELEGRAM_MESSAGE_MAX_CHARS
    assert text.end_with?(Hive::Bot::NotificationBuilders::DETAILS_TRUNCATION_MARKER)
  end

  def test_details_reply_truncation_preserves_summary_prefix
    # Trimming the oversized detail must keep the (short) summary intact — the
    # length/marker checks above don't prove the prefix survives.
    text = Hive::Bot::NotificationBuilders.details_reply(
      row(action: "recover_review", marker: "review_error", stage: "6-review",
          diagnostic: { "summary" => "REVIEW_ERROR pass=2", "detail" => "x" * 6000 })
    )

    assert_operator text.length, :<=, Hive::Bot::NotificationBuilders::TELEGRAM_MESSAGE_MAX_CHARS
    assert text.end_with?(Hive::Bot::NotificationBuilders::DETAILS_TRUNCATION_MARKER)
    assert_includes text, "REVIEW_ERROR pass=2",
                    "the summary prefix must survive when only the detail is trimmed"
  end

  def test_details_reply_truncates_summary_only_oversized_diagnostic
    # Exercises truncate_diagnostic_reply's detail-empty early return: a
    # summary-only diagnostic has no detail to trim, so it falls back to
    # whole-text truncation.
    text = Hive::Bot::NotificationBuilders.details_reply(
      row(action: "recover_review", marker: "review_error", stage: "6-review",
          diagnostic: { "summary" => "y" * 6000, "detail" => "" })
    )

    assert_operator text.length, :<=, Hive::Bot::NotificationBuilders::TELEGRAM_MESSAGE_MAX_CHARS
    assert text.end_with?(Hive::Bot::NotificationBuilders::DETAILS_TRUNCATION_MARKER)
  end

  def test_details_reply_truncates_when_summary_alone_exhausts_budget
    # Exercises truncate_diagnostic_reply's available-not-positive early return:
    # the summary prefix already overruns the Telegram limit, leaving no room
    # for any detail, so it falls back to whole-text truncation.
    text = Hive::Bot::NotificationBuilders.details_reply(
      row(action: "recover_review", marker: "review_error", stage: "6-review",
          diagnostic: { "summary" => "z" * 5000, "detail" => "tail detail" })
    )

    assert_operator text.length, :<=, Hive::Bot::NotificationBuilders::TELEGRAM_MESSAGE_MAX_CHARS
    assert text.end_with?(Hive::Bot::NotificationBuilders::DETAILS_TRUNCATION_MARKER)
  end

  def test_details_reply_renders_summary_only_diagnostic
    text = Hive::Bot::NotificationBuilders.details_reply(
      row(action: "recover_review", marker: "review_error", stage: "6-review",
          diagnostic: { "summary" => "REVIEW_ERROR pass=2", "detail" => "" })
    )

    assert_includes text, "REVIEW_ERROR pass=2"
  end

  def test_details_reply_renders_detail_only_diagnostic
    text = Hive::Bot::NotificationBuilders.details_reply(
      row(action: "recover_review", marker: "review_error", stage: "6-review",
          diagnostic: { "summary" => "", "detail" => "only the detail body" })
    )

    assert_includes text, "only the detail body"
  end

  def test_details_reply_appends_no_section_for_blank_diagnostic
    # A diagnostic hash whose summary and detail are both blank appends no
    # diagnostic section — byte-identical to a nil diagnostic (the
    # reject(&:empty?) / summary-and-detail-blank guards).
    blank = Hive::Bot::NotificationBuilders.details_reply(
      row(action: "recover_review", marker: "review_error", stage: "6-review",
          diagnostic: { "summary" => "", "detail" => "" })
    )
    none = Hive::Bot::NotificationBuilders.details_reply(
      row(action: "recover_review", marker: "review_error", stage: "6-review",
          diagnostic: nil)
    )

    assert_equal none, blank
  end

  def test_details_reply_uses_flat_suggested_command_when_no_structured_next_action
    # next_step_hint's suggested_command fallback (:446): with no structured
    # next_action, the flat suggested_command sources the "Next step:" line.
    text = Hive::Bot::NotificationBuilders.details_reply(
      row(action: "needs_input", marker: "agent_waiting", workflow: "research", stage: "2-gather",
          next_action: nil, suggested_command: "hive run slug-260514-abcd")
    )

    assert_includes text, "Next step: hive run slug-260514-abcd"
  end

  def test_details_reply_treats_dash_command_sentinel_as_no_hint
    # next_step_hint's `== "-"` sentinel (:448): a "-" command yields no hint,
    # so the reply falls through to the laptop fallback.
    text = Hive::Bot::NotificationBuilders.details_reply(
      row(action: "needs_input", marker: "agent_waiting", workflow: "research", stage: "2-gather",
          suggested_command: "-")
    )

    refute_includes text, "Next step:"
    assert_includes text, "Open on a laptop to advance."
  end

  def test_details_reply_for_plan_waiting_derives_plan_path_from_folder
    # state_file nil → the hint falls back to <folder>/plan.md, the realistic
    # production shape (folder is always present on live rows).
    text = Hive::Bot::NotificationBuilders.details_reply(
      row(action: "needs_input", marker: "waiting", stage: "3-plan", workflow: "coding",
          state_file: nil, folder: "/tmp/plan-task-260514-abcd")
    )

    assert_includes text, "Plan draft: /tmp/plan-task-260514-abcd/plan.md"
    assert_includes text, "Approve when ready with /approve slug-260514-abcd."
  end

  def test_details_reply_for_plan_waiting_without_any_path_omits_plan_draft
    # With neither state_file nor folder, File.join would emit a bogus bare
    # "plan.md" — the hint must drop the "Plan draft:" line entirely.
    text = Hive::Bot::NotificationBuilders.details_reply(
      row(action: "needs_input", marker: "waiting", stage: "3-plan", workflow: "coding",
          state_file: nil, folder: nil)
    )

    refute_includes text, "Plan draft:"
    assert_includes text, "Approve when ready with /approve slug-260514-abcd."
  end

  def test_details_reply_for_manual_recovery_without_folder_omits_logs_line
    # Manual-only recovery hint with no folder (:426) must skip the
    # "Logs/artifacts:" line rather than emit a blank path.
    text = Hive::Bot::NotificationBuilders.details_reply(
      row(action: "recover_execute", marker: "execute_stale", stage: "4-execute", folder: nil)
    )

    assert_includes text, "Hive has no automatic recovery for this state - open it on a laptop."
    refute_includes text, "Logs/artifacts:"
  end

  def test_details_reply_for_auto_recoverable_recovery_row_falls_through_to_generic_hint
    # A recovery row that is auto-recoverable (review_error outside the fix
    # phase) is NOT manual-only, so details_hint must skip the manual-only
    # branch and fall through to the generic advance hint — never the
    # "no automatic recovery" line, which belongs only to manual-only states.
    text = Hive::Bot::NotificationBuilders.details_reply(
      row(action: "recover_review", marker: "review_error", stage: "6-review",
          attrs: { "phase" => "triage", "pass" => "1" })
    )

    assert_includes text, "Hive will keep retrying this error automatically"
    refute_includes text, "no automatic recovery"
  end

  def test_details_reply_for_dirty_worktree_error_explains_continuing_retry
    text = Hive::Bot::NotificationBuilders.details_reply(
      row(action: "error", marker: "error", stage: "8-finalize",
          attrs: { "reason" => "dirty_worktree" })
    )

    assert_includes text, "Hive will keep retrying this error automatically; tap Autofix to retry now."
    refute_includes text, "Hive has no automatic recovery for this state - open it on a laptop."
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
    assert_includes notification.text, "Tap Autofix to retry the stage cleanly."
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
                    "REVIEW_WAITING is not recoverable — must not surface an Autofix button"
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

    # Pin the un-flattened row structure so a regression to one-per-row or
    # all-on-one-row fails: Accept all / Reject all share the top row, Show
    # details sits on its own row beneath them.
    row_labels = notification.keyboard.map { |keyboard_row| keyboard_row.map { |button| button[:text] } }
    assert_equal [ [ "Accept all", "Reject all" ], [ "Show details" ] ], row_labels
  end

  def test_recovery_match_attr_review_stale_uses_marker_generation
    attrs = {
      "pass" => "3", "reason" => "timeout",
      "marker_id" => "review-stale-generation-3"
    }
    r = row(action: "recover_review", marker: "review_stale", attrs: attrs)
    autofix = Hive::Bot::NotificationBuilders.autofix_callback(r)
    assert_match(/:marker_id=review-stale-generation-3,reason=timeout\z/, autofix)
  end

  def test_recovery_match_attr_review_error_prefers_marker_generation
    attrs = {
      "pass" => "3", "phase" => "integrity", "reason" => "timeout",
      "marker_id" => "review-generation-3"
    }
    r = row(action: "recover_review", marker: "review_error", attrs: attrs)
    autofix = Hive::Bot::NotificationBuilders.autofix_callback(r)

    assert_match(/:marker_id=review-generation-3,reason=timeout\z/, autofix,
                 "review-error recovery must guard the exact marker generation")
    refute_match(/:pass=3\z/, autofix,
                 "a reused pass must not supersede the marker generation guard")
  end

  def test_recovery_match_attr_error_encodes_marker_id_and_reason
    attrs = { "reason" => "exit_code", "exit_code" => "137", "marker_id" => "err-137" }
    r = row(action: "error", marker: "error", attrs: attrs)
    autofix = Hive::Bot::NotificationBuilders.autofix_callback(r)
    # F1: when a marker_id is present, encode `marker_id=<hex>,reason=<r>` as
    # a comma-separated pair so callbacks retain the reason as an additional
    # guarded assertion. marker_id stays the LEADING token so AlertStore's
    # first-token guard (parse_match_attr) keeps using it as the race-safe
    # invalidation key.
    assert_match(/:marker_id=err-137,reason=exit_code\z/, autofix,
                 "generic `error` marker must carry marker_id (race-safe guard) + reason " \
                 "(manual-only routing key), leading with marker_id")
  end

  def test_recovery_match_attr_error_does_not_synthesize_legacy_identity
    attrs = { "reason" => "exit_code", "exit_code" => "137" }
    r = row(action: "error", marker: "error", attrs: attrs)
    autofix = Hive::Bot::NotificationBuilders.autofix_callback(r)
    refute_match(/reason=exit_code|exit_code=137/, autofix)
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
      row(action: "recover_review", marker: "review_error",
          attrs: { "pass" => "2", "marker_id" => "review-generation-2" },
          slug: "we-need-to-improve-this-260522-db23", stage: "6-review",
          diagnostic: retry_diagnostic)
    )

    assert_equal 1, notification.keyboard.length
    assert_equal 1, notification.keyboard.first.length
    button = notification.keyboard.first.first
    assert_equal "🔧 Autofix", button[:text]
    assert_equal "autofix:hive:we-need-to-improve-this-260522-db23:6-review:" \
                 "review_error:marker_id=review-generation-2",
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

  def test_fix_tampered_review_error_offers_autofix
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "recover_review", marker: "review_error",
          attrs: { "phase" => "fix", "reason" => "fix_tampered" },
          stage: "6-review", diagnostic: retry_diagnostic)
    )

    labels = notification.keyboard.flatten.map { |button| button[:text] }
    assert_includes labels, "🔧 Autofix"
    refute_includes labels, "Open laptop",
                    "Open laptop button retired everywhere"
    refute_includes labels, "Show details"
  end

  def test_fix_status_check_failed_review_error_offers_autofix
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "recover_review", marker: "review_error",
          attrs: { "phase" => "fix", "reason" => "fix_status_check_failed", "pass" => "1" },
          stage: "6-review", diagnostic: retry_diagnostic)
    )

    assert_includes notification.text, "Tap Autofix to retry the stage cleanly."
    labels = notification.keyboard.flatten.map { |button| button[:text] }
    assert_equal [ "🔧 Autofix" ], labels
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
