require "test_helper"
require "hive/bot/handlers/slash_handlers"
require "hive/bot/handlers/callback_handlers"
require "hive/bot/idea_draft_store"
require "hive/bot/notification_builders"

class HiveBotSlashHandlersTest < Minitest::Test
  Result = Struct.new(:action, :text, :reply_markup, :command_argv, :commands,
                      :project, :slug, :question_n, :answer_text, :mode,
                      :intent, :alert_reset, :clear_keyboard, :format,
                      :attachment, keyword_init: true)
  Update = Struct.new(:text, :chat_id, keyword_init: true) do
    def effective_text = text
    def media? = false
  end
  MediaUpdate = Struct.new(:text, :chat_id, :effective_text, keyword_init: true) do
    def media? = true
  end
  PolicyResult = Struct.new(:status, :file_id, :file_size, :ext, keyword_init: true)

  FakeAttachmentPolicy = Struct.new(:result, keyword_init: true) do
    def classify(_update, _draft, max_bytes:, max_count:)
      result
    end
  end

  def setup
    @handlers = Hive::Bot::Handlers::SlashHandlers.new(
      projects_provider: -> { [] },
      pending_ideas: {},
      last_project: -> { nil },
      result_class: Result
    )
  end

  def test_status_without_project_dispatches_global_status
    result = @handlers.status(Update.new(text: "/status"))

    assert_equal :dispatch_then_reply, result.action
    assert_equal [ "hive", "status", "--json" ], result.command_argv
    assert_nil result.project
  end

  def test_status_with_project_dispatches_filtered_status
    result = @handlers.status(Update.new(text: "/status hive"))

    assert_equal :dispatch_then_reply, result.action
    # argv stays flag-free; project filter rides on Result.project
    assert_equal [ "hive", "status", "--json" ], result.command_argv
    assert_equal "hive", result.project
  end

  def test_status_preserves_multi_word_project_names
    result = @handlers.status(Update.new(text: "/status my project"))

    assert_equal :dispatch_then_reply, result.action
    assert_equal [ "hive", "status", "--json" ], result.command_argv
    assert_equal "my project", result.project
  end

  def test_help_documents_project_status_argument
    result = @handlers.help(Update.new(text: "/help"))

    assert_includes result.text, "/status [project]"
  end

  def test_status_with_json_flag_sets_format_json
    result = @handlers.status(Update.new(text: "/status --json"))

    assert_equal :json, result.format
    assert_nil result.project, "/status --json without a project must produce a no-project filter"
    assert_equal [ "hive", "status", "--json" ], result.command_argv
  end

  def test_status_with_json_flag_and_project_filters_and_sets_format_json
    result = @handlers.status(Update.new(text: "/status --json hive"))

    assert_equal :json, result.format
    assert_equal "hive", result.project
    assert_equal [ "hive", "status", "--json" ], result.command_argv
  end

  FakeConversationState = Struct.new(:slug, keyword_init: true)

  class FakeConversationStore
    attr_reader :cleared

    def initialize(pending: 0, state: nil)
      @pending = pending
      @state = state
      @cleared = []
    end

    def pending_confirm_count(chat_id:) = @pending
    def get(chat_id:) = @state
    def clear(chat_id:, slug:) = (@cleared << [ chat_id, slug ])
  end

  Row = Struct.new(:project, :slug, :stage, :marker, :attrs, :diagnostic, keyword_init: true)

  def autofix_handlers(snapshot)
    Hive::Bot::Handlers::SlashHandlers.new(
      projects_provider: -> { [] },
      pending_ideas: {},
      last_project: -> { nil },
      result_class: Result,
      status_snapshot_provider: -> { snapshot }
    )
  end

  REVIEW_ERROR_ROW = Row.new(
    project: "hive",
    slug: "stuck-260525-abcd",
    stage: "6-review",
    marker: "review_error",
    attrs: { "phase" => "fix", "pass" => "2" },
    diagnostic: { "suggested_next_action" => { "kind" => "retry" } }
  ).freeze

  EXECUTE_STALE_ROW = Row.new(
    project: "hive",
    slug: "stale-260525-abcd",
    stage: "4-execute",
    marker: "execute_stale",
    attrs: {},
    diagnostic: nil
  ).freeze

  def test_autofix_with_default_snapshot_provider_replies_slug_not_found
    # SlashHandlers default-constructs status_snapshot_provider to -> { [] }
    # so it works in isolation when nobody injects one (e.g., scripts that
    # instantiate SlashHandlers directly without Router). Cover the default
    # lambda body by NOT passing status_snapshot_provider.
    handlers = Hive::Bot::Handlers::SlashHandlers.new(
      projects_provider: -> { [] },
      pending_ideas: {},
      last_project: -> { nil },
      result_class: Result
    )

    result = handlers.autofix(Update.new(text: "/autofix any-slug-260526", chat_id: 1))

    assert_equal :reply, result.action
    assert_match(/Slug not found/, result.text)
  end

  def test_autofix_dispatches_expected_recover_sequence_argv
    handlers = autofix_handlers([ REVIEW_ERROR_ROW ])

    result = handlers.autofix(Update.new(text: "/autofix stuck-260525-abcd", chat_id: 1))

    assert_equal :dispatch_commands, result.action
    assert_equal "hive", result.project
    assert_equal "stuck-260525-abcd", result.slug
    assert_equal [
      [ "hive", "markers", "clear", "stuck-260525-abcd", "--name", "REVIEW_ERROR",
        "--project", "hive", "--match-attr", "pass=2", "--json" ],
      [ "hive", "review", "stuck-260525-abcd", "--from", "6-review", "--project", "hive", "--json" ]
    ], result.commands
    assert_equal({ project: "hive", slug: "stuck-260525-abcd", stage: "6-review",
                   marker: "review_error", match_attr: "pass=2" }, result.alert_reset)
    refute result.clear_keyboard,
           "slash path must NOT clear keyboard (no inline button was tapped)"
  end

  def test_autofix_slash_and_inline_button_dispatch_byte_identical_argv
    # The whole point of RecoverySequence is that the /autofix slash command
    # and the inline 🔧 Autofix button produce IDENTICAL dispatches for the
    # same row. Drive BOTH surfaces from the same Row and compare — without
    # this, the two surfaces could silently diverge (the prior test only
    # inspected the slash side and the file name overclaimed parity).
    row = REVIEW_ERROR_ROW
    slash = autofix_handlers([ row ]).autofix(Update.new(text: "/autofix #{row.slug}", chat_id: 1))

    callback_data = Hive::Bot::NotificationBuilders.autofix_callback(row)
    button = Hive::Bot::Handlers::CallbackHandlers.new(
      pending_ideas: {}, set_last_project: ->(_p) { }, conversation_store: nil,
      result_class: Result, logger: nil
    ).handle(:callback_autofix, Struct.new(:callback_data).new(callback_data))

    assert_equal button.commands, slash.commands,
                 "slash and inline-button autofix must dispatch byte-identical argv for the same row"
    assert_equal button.alert_reset, slash.alert_reset,
                 "alert_reset must match across surfaces so dedupe behaves identically"
    # The one legitimate divergence: the button clears its inline keyboard;
    # the slash command has no keyboard to clear.
    assert button.clear_keyboard, "inline button clears its keyboard"
    refute slash.clear_keyboard, "slash command has no keyboard to clear"
  end

  def test_autofix_with_cold_snapshot_replies_still_loading
    handlers = Hive::Bot::Handlers::SlashHandlers.new(
      projects_provider: -> { [] }, pending_ideas: {}, last_project: -> { nil },
      result_class: Result, status_snapshot_provider: -> { nil }
    )

    result = handlers.autofix(Update.new(text: "/autofix any-260526-zzzz", chat_id: 1))

    assert_equal :reply, result.action
    assert_match(/still loading/, result.text)
  end

  def test_autofix_with_ambiguous_slug_refuses_rather_than_guessing_project
    other = Row.new(project: "writero", slug: "stuck-260525-abcd", stage: "6-review",
                    marker: "review_error", attrs: {}, diagnostic: nil)
    handlers = autofix_handlers([ REVIEW_ERROR_ROW, other ])

    result = handlers.autofix(Update.new(text: "/autofix stuck-260525-abcd", chat_id: 1))

    assert_equal :reply, result.action
    assert_match(/Multiple active tasks match/, result.text)
  end

  def test_autofix_with_raising_snapshot_provider_degrades_to_retry_hint
    handlers = Hive::Bot::Handlers::SlashHandlers.new(
      projects_provider: -> { [] }, pending_ideas: {}, last_project: -> { nil },
      result_class: Result, status_snapshot_provider: -> { raise "boom" }
    )

    result = handlers.autofix(Update.new(text: "/autofix any-260526-zzzz", chat_id: 1))

    assert_equal :reply, result.action
    assert_match(/Status lookup failed/, result.text)
  end

  def test_autofix_without_slug_arg_replies_with_usage_hint_and_no_dispatch
    handlers = autofix_handlers([ REVIEW_ERROR_ROW ])

    result = handlers.autofix(Update.new(text: "/autofix", chat_id: 1))

    assert_equal :reply, result.action
    assert_equal "Use /autofix <slug>.", result.text
  end

  def test_autofix_with_unknown_slug_replies_with_archive_hint
    handlers = autofix_handlers([ REVIEW_ERROR_ROW ])

    result = handlers.autofix(Update.new(text: "/autofix unknown-260525-zzzz", chat_id: 1))

    assert_equal :reply, result.action
    assert_match(/Slug not found/, result.text)
  end

  def test_autofix_manual_only_marker_replies_with_open_laptop_hint
    handlers = autofix_handlers([ EXECUTE_STALE_ROW ])

    result = handlers.autofix(Update.new(text: "/autofix stale-260525-abcd", chat_id: 1))

    assert_equal :reply, result.action
    assert_match(/no automatic recovery/, result.text)
  end

  def test_autofix_refuses_attrs_gated_manual_only_fix_tampered_row
    # review_error + phase=fix + reason=fix_tampered is manual-only, but that
    # is gated on attrs, not the marker name. The callback_data doesn't carry
    # attrs; the slash path does, so a directly-typed /autofix on such a row
    # must refuse (not dispatch a retry against a tampered fix).
    tampered = Row.new(project: "hive", slug: "tampered-260525-abcd", stage: "6-review",
                       marker: "review_error",
                       attrs: { "phase" => "fix", "reason" => "fix_tampered" }, diagnostic: nil)
    handlers = autofix_handlers([ tampered ])

    result = handlers.autofix(Update.new(text: "/autofix tampered-260525-abcd", chat_id: 1))

    assert_equal :reply, result.action
    assert_match(/no automatic recovery/, result.text)
  end

  def test_autofix_refuses_attrs_gated_manual_only_fix_status_check_failed_row
    status_check_failed = Row.new(project: "hive", slug: "status-260530-abcd", stage: "6-review",
                                  marker: "review_error",
                                  attrs: {
                                    "phase" => "fix",
                                    "reason" => "fix_status_check_failed",
                                    "pass" => "1"
                                  },
                                  diagnostic: { "suggested_next_action" => { "kind" => "retry" } })
    handlers = autofix_handlers([ status_check_failed ])

    result = handlers.autofix(Update.new(text: "/autofix status-260530-abcd", chat_id: 1))

    assert_equal :reply, result.action
    assert_match(/no automatic recovery/, result.text)
  end

  def test_autofix_no_retry_verb_for_stage_replies_cleanly
    # A retryable 9-done row passes the retryable gate but has no retry verb,
    # so RecoverySequence.build's stage check produces the clean refusal.
    done_retryable = Row.new(project: "hive", slug: "done-260525-abcd", stage: "9-done",
                             marker: "review_error", attrs: {},
                             diagnostic: { "suggested_next_action" => { "kind" => "retry" } })
    handlers = autofix_handlers([ done_retryable ])

    result = handlers.autofix(Update.new(text: "/autofix done-260525-abcd", chat_id: 1))

    assert_equal :reply, result.action
    assert_match(/No retry verb for stage 9-done/, result.text)
  end

  def test_autofix_non_retryable_recovery_row_points_to_details
    # P2a: a recovery row with no suggested_next_action.retry is not auto-
    # retryable. Manually typed /autofix must refuse and point to /details
    # rather than dispatch markers-clear + a retry verb (the gate the inline
    # button and the /status link already enforce).
    non_retryable = Row.new(project: "hive", slug: "norefry-260525-abcd", stage: "6-review",
                            marker: "review_error", attrs: { "pass" => "2" }, diagnostic: nil)
    handlers = autofix_handlers([ non_retryable ])

    result = handlers.autofix(Update.new(text: "/autofix norefry-260525-abcd", chat_id: 1))

    assert_equal :reply, result.action
    assert_match(/no automatic retry available/, result.text)
    assert_match(%r{/details norefry-260525-abcd}, result.text)
  end

  def test_details_dispatches_status_diagnose_argv
    handlers = autofix_handlers([ REVIEW_ERROR_ROW ])

    result = handlers.details(Update.new(text: "/details stuck-260525-abcd", chat_id: 1))

    assert_equal :dispatch_then_reply, result.action
    assert_equal "hive", result.project
    assert_equal [ "hive", "status", "--diagnose", "stuck-260525-abcd",
                   "--project", "hive", "--stage", "6-review", "--json" ], result.command_argv
  end

  def test_details_without_slug_arg_replies_with_usage_hint
    handlers = autofix_handlers([ REVIEW_ERROR_ROW ])

    result = handlers.details(Update.new(text: "/details", chat_id: 1))

    assert_equal :reply, result.action
    assert_equal "Use /details <slug>.", result.text
  end

  def test_details_with_unknown_slug_replies_with_archive_hint
    handlers = autofix_handlers([])

    result = handlers.details(Update.new(text: "/details whatever-260525-zzzz", chat_id: 1))

    assert_equal :reply, result.action
    assert_match(/Slug not found/, result.text)
  end

  def test_done_dispatches_hive_run_and_clears_conversation_state
    store = FakeConversationStore.new(state: FakeConversationState.new(slug: "ship-it-260526-abcd"))

    result = @handlers.done(Update.new(text: "/done", chat_id: 12345), store)

    assert_equal :dispatch_then_reply, result.action
    assert_equal [ "hive", "run", "ship-it-260526-abcd", "--json" ], result.command_argv
    assert_equal "ship-it-260526-abcd", result.slug
    assert_equal [ [ 12345, "ship-it-260526-abcd" ] ], store.cleared,
                 "/done must clear the active conversation so the auto-dispatch path doesn't double-fire"
  end

  def test_done_with_pending_confirm_drafts_warns_without_dispatch
    store = FakeConversationStore.new(pending: 2)

    result = @handlers.done(Update.new(text: "/done", chat_id: 12345), store)

    assert_equal :reply, result.action
    assert_match(/2 draft answers/, result.text)
  end

  def test_done_without_active_conversation_replies_with_friendly_hint
    store = FakeConversationStore.new(state: nil)

    result = @handlers.done(Update.new(text: "/done", chat_id: 12345), store)

    assert_equal :reply, result.action
    assert_match(/No active brainstorm conversation/, result.text)
  end

  def test_idea_without_text_and_without_draft_store_replies_usage
    result = @handlers.idea(Update.new(text: "/idea", chat_id: 1))

    assert_equal :reply, result.action
    assert_equal "Use /idea <text> to capture a new idea.", result.text
  end

  def test_idea_with_text_uses_default_clock_for_legacy_pending_idea
    pending = {}
    handlers = Hive::Bot::Handlers::SlashHandlers.new(
      projects_provider: -> { [ "hive" ] },
      pending_ideas: pending,
      last_project: -> { nil },
      result_class: Result
    )

    result = handlers.idea(Update.new(text: "/idea fix login", chat_id: 1))

    assert_equal :reply, result.action
    assert_equal "Pick a project for the idea.", result.text
    entry = pending.values.fetch(0)
    assert_equal "fix login", entry.fetch(:text)
    assert entry.fetch(:created_at).is_a?(Time)
  end

  def test_capture_idea_text_rejects_blank_and_expired_draft
    store = Hive::Bot::IdeaDraftStore.new
    handlers = idea_handlers(draft_store: store)

    blank = handlers.capture_idea_text(Update.new(text: "  ", chat_id: 7))
    expired = handlers.capture_idea_text(Update.new(text: "fix login", chat_id: 7))

    assert_equal "Send the idea text in your next message.", blank.text
    assert_equal "That idea draft expired. Send /idea again.", expired.text
  end

  def test_idea_media_stages_file_and_prompts_for_text
    store = Hive::Bot::IdeaDraftStore.new
    handlers = idea_handlers(
      draft_store: store,
      policy: FakeAttachmentPolicy.new(
        result: PolicyResult.new(status: :ok, file_id: "photo-id", file_size: 12, ext: "jpg")
      )
    )

    result = handlers.idea(MediaUpdate.new(text: "/idea", chat_id: 9, effective_text: ""))

    assert_equal :stage_attachment, result.action
    assert_equal "What's the idea for this file?", result.text
    assert_equal({ chat_id: 9, file_id: "photo-id", file_size: 12, ext: "jpg" }, result.attachment)
  end

  def test_idea_text_with_media_stages_then_shows_project_picker
    store = Hive::Bot::IdeaDraftStore.new
    handlers = idea_handlers(
      draft_store: store,
      policy: FakeAttachmentPolicy.new(
        result: PolicyResult.new(status: :ok, file_id: "doc-id", file_size: 12, ext: "pdf")
      )
    )

    result = handlers.idea(MediaUpdate.new(text: "/idea fix login", chat_id: 9, effective_text: "/idea fix login"))

    assert_equal :stage_attachment, result.action
    assert_equal "Pick a project for the idea.", result.text
    assert_equal :awaiting_project, store.get(chat_id: 9).phase
  end

  def test_media_reply_copy_matches_draft_phase
    # awaiting_transcript_confirm is a valid phase that media_after_stage_reply
    # does not special-case, so it exercises the generic "Attached." fallback.
    %i[awaiting_project collecting_files awaiting_transcript_confirm].each do |phase|
      store = Hive::Bot::IdeaDraftStore.new
      # :awaiting_transcript_confirm is coupled to a voice-origin draft
      # (validate_phase_origin!), so it must be started with origin: :voice.
      origin = phase == :awaiting_transcript_confirm ? :voice : nil
      store.start(chat_id: 9, phase: phase, text: "fix", token: "tok", origin: origin)
      handlers = idea_handlers(
        draft_store: store,
        policy: FakeAttachmentPolicy.new(
          result: PolicyResult.new(status: :ok, file_id: "file-id", file_size: 12, ext: "jpg")
        )
      )

      result = handlers.media(MediaUpdate.new(chat_id: 9, effective_text: ""))

      expected = {
        awaiting_project: "Pick a project for the idea.",
        collecting_files: "Attached. Send more files, or press Done.",
        awaiting_transcript_confirm: "Attached."
      }.fetch(phase)
      assert_equal expected, result.text
    end
  end

  def test_media_policy_rejection_messages_include_configured_limits
    {
      too_large: "under 7 MB",
      disallowed_type: "Unsupported attachment type",
      cap_reached: "already has 3 attachments",
      unknown: "I could not attach that file."
    }.each do |status, text|
      store = Hive::Bot::IdeaDraftStore.new
      handlers = idea_handlers(
        draft_store: store,
        policy: FakeAttachmentPolicy.new(result: PolicyResult.new(status: status)),
        max_attachment_bytes: 7 * 1024 * 1024,
        max_attachment_count: 3
      )

      result = handlers.media(MediaUpdate.new(chat_id: 9, effective_text: ""))

      assert_equal :reply, result.action
      assert_match text, result.text
      assert_nil store.get(chat_id: 9), "bare rejected media must not leave a phantom draft"
    end
  end

  private

  def idea_handlers(draft_store:, policy: FakeAttachmentPolicy.new(result: PolicyResult.new(status: :ok)),
                    max_attachment_bytes: nil, max_attachment_count: nil)
    Hive::Bot::Handlers::SlashHandlers.new(
      projects_provider: -> { [ "hive" ] },
      pending_ideas: {},
      last_project: -> { nil },
      result_class: Result,
      idea_draft_store: draft_store,
      idea_attachment_policy: policy,
      max_attachment_bytes: max_attachment_bytes,
      max_attachment_count: max_attachment_count
    )
  end
end
