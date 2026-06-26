require "test_helper"
require "hive/bot/handlers/slash_handlers"
require "hive/bot/handlers/callback_handlers"
require "hive/bot/idea_draft_store"
require "hive/bot/notification_builders"
require "hive/bot/status_watcher"

class HiveBotSlashHandlersTest < Minitest::Test
  Result = Struct.new(:action, :text, :reply_markup, :command_argv, :commands,
                      :project, :slug, :stage, :question_n, :answer_text, :mode,
                      :intent, :alert_reset, :clear_keyboard, :format,
                      :attachment, keyword_init: true)
  Update = Struct.new(:text, :chat_id, keyword_init: true) do
    def effective_text = text
    def media? = false
  end
  MediaUpdate = Struct.new(:text, :chat_id, :effective_text, keyword_init: true) do
    def media? = true
  end
  VoiceUpdate = Struct.new(:chat_id, :voice, keyword_init: true)
  PolicyResult = Struct.new(:status, :file_id, :file_size, :ext, keyword_init: true)

  FakeAttachmentPolicy = Struct.new(:result, keyword_init: true) do
    def classify(_update, _draft, max_bytes:, max_count:)
      result
    end
  end

  FakeLogger = Struct.new(:events, keyword_init: true) do
    def event(name, **payload)
      events << { name: name, payload: payload }
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

  def test_start_welcomes_with_concrete_next_steps
    result = @handlers.start(Update.new(text: "/start"))
    assert_equal :reply, result.action
    assert_match(/Connected/, result.text)
    assert_match(%r{/status}, result.text, "the welcome must hand the operator a next step")
    assert_match(%r{/help}, result.text)
  end

  def test_help_documents_project_status_argument
    result = @handlers.help(Update.new(text: "/help"))

    assert_includes result.text, "/status [project]"
    assert_includes result.text, "/answer <id|slug>"
    assert_includes result.text, "/approve <id|slug>"
    assert_includes result.text, "/autofix <id|slug>"
    assert_includes result.text, "/details <id|slug>"
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

    def initialize(state: nil)
      @state = state
      @cleared = []
    end

    def get(chat_id:) = @state
    def clear(chat_id:, slug:) = (@cleared << [ chat_id, slug ])
  end

  # Use the real renderer input type rather than a hand-maintained Struct dup:
  # the production resolver only ever hands NotificationBuilders a
  # StatusWatcher::Row, and a Struct copy silently diverges as Row gains fields
  # (callback_handlers_test.rb already binds the real Row for the same reason).
  Row = Hive::Bot::StatusWatcher::Row

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
    id: 9281,
    stage: "6-review",
    workflow: "coding",
    marker: "review_error",
    attrs: { "phase" => "fix", "pass" => "2" },
    folder: "/tmp/stuck-260525-abcd",
    action: "recover_review",
    action_label: "Needs recovery",
    diagnostic: { "suggested_next_action" => { "kind" => "retry" } }
  ).freeze

  EXECUTE_STALE_ROW = Row.new(
    project: "hive",
    slug: "stale-260525-abcd",
    id: 9282,
    stage: "4-execute",
    workflow: "coding",
    marker: "execute_stale",
    attrs: {},
    folder: "/tmp/stale-260525-abcd",
    action: "recover_execute",
    action_label: "Needs recovery",
    diagnostic: nil
  ).freeze

  def test_approve_with_numeric_id_dispatches_resolved_slug
    handlers = autofix_handlers([ REVIEW_ERROR_ROW ])

    [ "9281", "#9281" ].each do |target|
      result = handlers.approve(Update.new(text: "/approve #{target}", chat_id: 1))

      assert_equal :dispatch_then_reply, result.action
      assert_equal [ "hive", "approve", "stuck-260525-abcd", "--json" ], result.command_argv
      assert_equal "stuck-260525-abcd", result.slug
      assert_nil result.text, "a resolved numeric id dispatches silently — no operator reply text"
    end
  end

  def test_numeric_id_filters_multi_row_snapshot_instead_of_taking_head
    # The head row's id (9282) does NOT match the target (9281); only the
    # second row does. Proves resolve_status_row's `select { row.id == id }`
    # actually filters by id rather than blindly taking the snapshot head —
    # guarding against a future refactor that swaps the predicate for `.first`.
    handlers = autofix_handlers([ EXECUTE_STALE_ROW, REVIEW_ERROR_ROW ])

    result = handlers.approve(Update.new(text: "/approve 9281", chat_id: 1))

    assert_equal :dispatch_then_reply, result.action
    assert_equal "stuck-260525-abcd", result.slug,
                 "must resolve the row whose id matches, not the snapshot head"
    assert_equal [ "hive", "approve", "stuck-260525-abcd", "--json" ], result.command_argv
  end

  def test_approve_with_slug_dispatches_verbatim_without_snapshot_lookup
    handlers = Hive::Bot::Handlers::SlashHandlers.new(
      projects_provider: -> { [] }, pending_ideas: {}, last_project: -> { nil },
      result_class: Result, status_snapshot_provider: -> { raise "unexpected lookup" }
    )

    result = handlers.approve(Update.new(text: "/approve approve-me-260525-abcd", chat_id: 1))

    assert_equal :dispatch_then_reply, result.action
    assert_equal [ "hive", "approve", "approve-me-260525-abcd", "--json" ], result.command_argv
    assert_equal "approve-me-260525-abcd", result.slug
  end

  def test_approve_with_missing_numeric_id_replies_with_archive_hint
    handlers = autofix_handlers([ REVIEW_ERROR_ROW ])

    [ "4242", "#4242" ].each do |target|
      result = handlers.approve(Update.new(text: "/approve #{target}", chat_id: 1))

      assert_equal :reply, result.action
      assert_equal "No active task #4242 — was it archived?", result.text
      assert_nil result.command_argv
    end
  end

  def test_approve_with_missing_numeric_id_having_leading_zeroes_reports_normalized_id
    handlers = autofix_handlers([ REVIEW_ERROR_ROW ])

    result = handlers.approve(Update.new(text: "/approve 04242", chat_id: 1))

    assert_equal :reply, result.action
    assert_equal "No active task #4242 — was it archived?", result.text,
                 "an id miss must echo the normalized id (leading zeroes stripped), not the raw 04242"
    assert_nil result.command_argv
  end

  def test_approve_with_cold_snapshot_replies_still_loading_for_numeric_id
    handlers = Hive::Bot::Handlers::SlashHandlers.new(
      projects_provider: -> { [] }, pending_ideas: {}, last_project: -> { nil },
      result_class: Result, status_snapshot_provider: -> { nil }
    )

    result = handlers.approve(Update.new(text: "/approve 9281", chat_id: 1))

    assert_equal :reply, result.action
    assert_match(/still loading/, result.text)
    assert_nil result.command_argv
  end

  def test_approve_without_arg_replies_with_usage_hint
    result = @handlers.approve(Update.new(text: "/approve", chat_id: 1))

    assert_equal :reply, result.action
    assert_equal "Use /approve <id|slug>.", result.text
  end

  def test_answer_with_numeric_id_starts_answer_for_resolved_slug
    handlers = autofix_handlers([ REVIEW_ERROR_ROW ])

    [ "9281", "#9281" ].each do |target|
      result = handlers.answer(Update.new(text: "/answer #{target}", chat_id: 1), nil)

      assert_equal :start_answer, result.action
      assert_equal "stuck-260525-abcd", result.slug
      assert_equal :path_b, result.mode
      assert_nil result.text, "a resolved numeric id starts the answer flow — no operator reply text"
    end
  end

  def test_answer_with_slug_starts_answer_verbatim_without_snapshot_lookup
    handlers = Hive::Bot::Handlers::SlashHandlers.new(
      projects_provider: -> { [] }, pending_ideas: {}, last_project: -> { nil },
      result_class: Result, status_snapshot_provider: -> { raise "unexpected lookup" }
    )

    result = handlers.answer(Update.new(text: "/answer answer-me-260525-abcd", chat_id: 1), nil)

    assert_equal :start_answer, result.action
    assert_equal "answer-me-260525-abcd", result.slug
    assert_equal :path_b, result.mode
  end

  def test_answer_with_missing_numeric_id_replies_with_archive_hint
    handlers = autofix_handlers([ REVIEW_ERROR_ROW ])

    [ "4242", "#4242" ].each do |target|
      result = handlers.answer(Update.new(text: "/answer #{target}", chat_id: 1), nil)

      assert_equal :reply, result.action
      assert_equal "No active task #4242 — was it archived?", result.text
      assert_nil result.slug
    end
  end

  def test_answer_with_cold_snapshot_replies_still_loading_for_numeric_id
    handlers = Hive::Bot::Handlers::SlashHandlers.new(
      projects_provider: -> { [] }, pending_ideas: {}, last_project: -> { nil },
      result_class: Result, status_snapshot_provider: -> { nil }
    )

    result = handlers.answer(Update.new(text: "/answer 9281", chat_id: 1), nil)

    assert_equal :reply, result.action
    assert_match(/still loading/, result.text)
    assert_nil result.slug
  end

  def test_answer_without_arg_replies_with_usage_hint
    result = @handlers.answer(Update.new(text: "/answer", chat_id: 1), nil)

    assert_equal :reply, result.action
    assert_equal "Use /answer <id|slug>.", result.text
  end

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

    assert_review_error_autofix_result(result)
  end

  def test_autofix_with_numeric_id_dispatches_expected_recover_sequence_argv
    handlers = autofix_handlers([ REVIEW_ERROR_ROW ])

    [ "9281", "#9281" ].each do |target|
      result = handlers.autofix(Update.new(text: "/autofix #{target}", chat_id: 1))

      assert_review_error_autofix_result(result)
    end
  end

  def test_autofix_manual_only_marker_resolved_by_id_replies_with_open_laptop_hint
    handlers = autofix_handlers([ EXECUTE_STALE_ROW ])

    result = handlers.autofix(Update.new(text: "/autofix 9282", chat_id: 1))

    assert_equal :reply, result.action
    assert_match(/no automatic recovery/, result.text)
  end

  def test_autofix_with_missing_numeric_id_replies_with_archive_hint
    handlers = autofix_handlers([ REVIEW_ERROR_ROW ])

    result = handlers.autofix(Update.new(text: "/autofix #4242", chat_id: 1))

    assert_equal :reply, result.action
    assert_equal "No active task #4242 — was it archived?", result.text
    # `commands` is only non-nil on the dispatch path, so contrast it: the
    # SAME handler resolving a matching id (#9281) populates the recovery
    # sequence, while the miss path must leave it nil rather than dispatch
    # against an unintended row. (Bare `assert_nil` here would pass for any
    # :reply regardless of correctness.)
    refute_nil handlers.autofix(Update.new(text: "/autofix #9281", chat_id: 1)).commands,
               "control: a matching id populates the recovery commands"
    assert_nil result.commands,
               "a missing id must not populate the recovery commands the success path sets"
  end

  def test_autofix_numeric_target_does_not_match_nil_id_rows
    nil_id_row = Row.new(project: "hive", slug: "nil-id-260525-abcd", id: nil,
                         stage: "6-review", marker: "review_error", attrs: {},
                         diagnostic: { "suggested_next_action" => { "kind" => "retry" } })
    handlers = autofix_handlers([ nil_id_row ])

    result = handlers.autofix(Update.new(text: "/autofix 9281", chat_id: 1))

    assert_equal :reply, result.action
    assert_equal "No active task #9281 — was it archived?", result.text
  end

  def test_autofix_numeric_target_accepts_leading_zeroes
    handlers = autofix_handlers([ REVIEW_ERROR_ROW ])

    result = handlers.autofix(Update.new(text: "/autofix 09281", chat_id: 1))

    assert_review_error_autofix_result(result)
  end

  def test_autofix_numeric_id_boundaries_fall_through_to_archive_hint
    handlers = autofix_handlers([ REVIEW_ERROR_ROW ])

    # id 0 (`0`/`#0`) and a Bignum id all parse as numeric ids that no
    # snapshot row matches, so each takes the id-miss path and echoes the
    # normalized id — benign, but pinned so a regex/normalization regression
    # can't silently start dispatching against the snapshot head.
    {
      "0" => "#0",
      "#0" => "#0",
      "999999999999999999999" => "#999999999999999999999"
    }.each do |target, expected|
      result = handlers.autofix(Update.new(text: "/autofix #{target}", chat_id: 1))

      assert_equal :reply, result.action, "boundary id #{target} must reply, not dispatch"
      assert_equal "No active task #{expected} — was it archived?", result.text
      assert_nil result.commands, "boundary id #{target} must not dispatch a recovery sequence"
    end
  end

  def test_autofix_hash_without_digits_stays_on_slug_path
    handlers = autofix_handlers([ REVIEW_ERROR_ROW ])

    result = handlers.autofix(Update.new(text: "/autofix #", chat_id: 1))

    assert_equal :reply, result.action
    assert_match(/Slug not found/, result.text)
  end

  def test_autofix_with_slug_matching_numeric_id_uses_slug_path
    numeric_slug_row = Row.new(project: "hive", slug: "9281-260525-abcd", id: 1111,
                               stage: "6-review", marker: "review_error", attrs: {},
                               diagnostic: { "suggested_next_action" => { "kind" => "retry" } })
    handlers = autofix_handlers([ numeric_slug_row ])

    result = handlers.autofix(Update.new(text: "/autofix 9281-260525-abcd", chat_id: 1))

    assert_equal :dispatch_commands, result.action
    assert_equal "9281-260525-abcd", result.slug
  end

  def test_details_renders_in_process_for_numeric_id
    handlers = autofix_handlers([ REVIEW_ERROR_ROW ])

    [ "9281", "#9281" ].each do |target|
      result = handlers.details(Update.new(text: "/details #{target}", chat_id: 1))

      assert_equal :reply, result.action,
                   "/details renders the row in-process (same as the inline button) rather than dispatching a subprocess"
      assert_nil result.command_argv, "in-process /details renders directly — no diagnose subprocess dispatch"
      assert_includes result.text, "stuck-260525-abcd",
                      "numeric id #{target} must resolve to its row and render that row's details"
    end
  end

  def test_details_with_missing_numeric_id_replies_with_archive_hint
    handlers = autofix_handlers([ REVIEW_ERROR_ROW ])

    [ "4242", "#4242" ].each do |target|
      result = handlers.details(Update.new(text: "/details #{target}", chat_id: 1))

      assert_equal :reply, result.action
      assert_equal "No active task #4242 — was it archived?", result.text
      assert_nil result.command_argv
    end
  end

  def test_details_numeric_target_does_not_match_nil_id_rows
    nil_id_row = Row.new(project: "hive", slug: "nil-id-260525-abcd", id: nil,
                         stage: "6-review", marker: "review_error", attrs: {},
                         diagnostic: { "suggested_next_action" => { "kind" => "retry" } })
    handlers = autofix_handlers([ nil_id_row ])

    result = handlers.details(Update.new(text: "/details 9281", chat_id: 1))

    assert_equal :reply, result.action
    assert_equal "No active task #9281 — was it archived?", result.text
  end

  def test_details_still_resolves_nil_id_row_by_slug
    nil_id_row = Row.new(project: "hive", slug: "nil-id-260525-abcd", id: nil,
                         stage: "6-review", marker: "review_error", attrs: {},
                         diagnostic: { "suggested_next_action" => { "kind" => "retry" } })
    handlers = autofix_handlers([ nil_id_row ])

    result = handlers.details(Update.new(text: "/details nil-id-260525-abcd", chat_id: 1))

    assert_equal :reply, result.action
    assert_includes result.text, "nil-id-260525-abcd",
                    "a nil-id row must still resolve by slug and render its details in-process"
  end

  def test_details_numeric_target_accepts_leading_zeroes
    handlers = autofix_handlers([ REVIEW_ERROR_ROW ])

    result = handlers.details(Update.new(text: "/details 09281", chat_id: 1))

    assert_equal :reply, result.action
    assert_includes result.text, "stuck-260525-abcd",
                    "leading-zero numeric id must resolve to its row and render in-process"
  end

  def assert_review_error_autofix_result(result)
    assert_equal :dispatch_commands, result.action
    assert_equal "hive", result.project
    assert_equal "stuck-260525-abcd", result.slug
    assert_nil result.text, "a successful autofix dispatch carries no operator reply text"
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

  def test_resolve_status_row_logs_swallowed_provider_fault
    # The broad rescue must not silently swallow a recurring snapshot-provider
    # fault: when a logger is wired it logs :status_lookup_failed before
    # degrading, so the fault stays visible in bot.log.
    logger = FakeLogger.new(events: [])
    handlers = Hive::Bot::Handlers::SlashHandlers.new(
      projects_provider: -> { [] }, pending_ideas: {}, last_project: -> { nil },
      result_class: Result, status_snapshot_provider: -> { raise "boom" }, logger: logger
    )

    handlers.details(Update.new(text: "/details any-260526-zzzz", chat_id: 1))

    logged = logger.events.find { |event| event[:name] == :status_lookup_failed }
    refute_nil logged, "a swallowed provider fault must be logged, not silently degraded"
    assert_equal "any-260526-zzzz", logged[:payload][:slug]
    assert_equal "RuntimeError", logged[:payload][:error_class]
  end

  def test_autofix_without_slug_arg_replies_with_usage_hint_and_no_dispatch
    handlers = autofix_handlers([ REVIEW_ERROR_ROW ])

    result = handlers.autofix(Update.new(text: "/autofix", chat_id: 1))

    assert_equal :reply, result.action
    assert_equal "Use /autofix <id|slug>.", result.text
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

  def test_details_replies_with_rendered_row_summary
    handlers = autofix_handlers([ REVIEW_ERROR_ROW ])

    result = handlers.details(Update.new(text: "/details stuck-260525-abcd", chat_id: 1))

    assert_equal :reply, result.action
    assert_nil result.command_argv
    assert_includes result.text, "Stuck… — hive/stuck-260525-abcd (6-review)"
    assert_includes result.text, "Action: Needs recovery"
    refute_includes result.text, "No diagnostic available"
  end

  def test_details_for_plan_waiting_slug_points_at_plan_draft
    plan_row = Row.new(
      project: "hive", slug: "plan-task-260525-abcd", stage: "3-plan", workflow: "coding",
      marker: "waiting", attrs: {}, folder: "/tmp/plan-task-260525-abcd",
      state_file: "/tmp/plan-task-260525-abcd/plan.md",
      action: "needs_input", action_label: "Needs your input", diagnostic: nil
    )
    handlers = autofix_handlers([ plan_row ])

    result = handlers.details(Update.new(text: "/details plan-task-260525-abcd", chat_id: 1))

    assert_equal :reply, result.action
    assert_includes result.text, "Plan draft: /tmp/plan-task-260525-abcd/plan.md"
    assert_includes result.text, "/approve plan-task-260525-abcd"
    refute_match(/diagnostic/i, result.text)
  end

  def test_details_for_plan_waiting_slug_still_appends_present_diagnostic
    # The nil-diagnostic case above makes refute_match(/diagnostic/i) pass
    # trivially; details_reply appends any present diagnostic regardless of
    # surface, so a plan_waiting row WITH a populated diagnostic still surfaces
    # it on the slash /details surface too.
    plan_row = Row.new(
      project: "hive", slug: "plan-task-260525-abcd", stage: "3-plan", workflow: "coding",
      marker: "waiting", attrs: {}, folder: "/tmp/plan-task-260525-abcd",
      state_file: "/tmp/plan-task-260525-abcd/plan.md",
      action: "needs_input", action_label: "Needs your input",
      diagnostic: { "summary" => "PLAN_DIAG summary", "detail" => "plan diagnostic detail" }
    )
    handlers = autofix_handlers([ plan_row ])

    result = handlers.details(Update.new(text: "/details plan-task-260525-abcd", chat_id: 1))

    assert_equal :reply, result.action
    assert_includes result.text, "Plan draft: /tmp/plan-task-260525-abcd/plan.md"
    assert_includes result.text, "PLAN_DIAG summary"
    assert_includes result.text, "plan diagnostic detail"
  end

  def test_details_for_recovery_slug_appends_diagnostic
    diagnostic_row = Row.new(
      project: "hive", slug: "stuck-260525-abcd", stage: "6-review", workflow: "coding",
      marker: "review_error", attrs: { "pass" => "2" }, folder: "/tmp/stuck-260525-abcd",
      action: "recover_review", action_label: "Needs recovery",
      diagnostic: { "summary" => "REVIEW_ERROR pass=2", "detail" => "review fix failed" }
    )
    handlers = autofix_handlers([ diagnostic_row ])

    result = handlers.details(Update.new(text: "/details stuck-260525-abcd", chat_id: 1))

    assert_equal :reply, result.action
    assert_includes result.text, "REVIEW_ERROR pass=2"
    assert_includes result.text, "review fix failed"
  end

  def test_details_degrades_and_logs_when_render_raises
    # details_reply renders OUTSIDE resolve_status_row's degrade rescue; a
    # render-time fault would escape the poll loop and skip write_last_seen,
    # leaving the operator with no reply. The row resolves cleanly (slug match)
    # but raises when rendered — degrade to the soft hint and log instead.
    raising_row = Class.new do
      def project = "hive"
      def slug = "boom-260525-abcd"
      def attrs = raise("render boom")
    end.new
    logger = FakeLogger.new(events: [])
    handlers = Hive::Bot::Handlers::SlashHandlers.new(
      projects_provider: -> { [] }, pending_ideas: {}, last_project: -> { nil },
      result_class: Result, status_snapshot_provider: -> { [ raising_row ] }, logger: logger
    )

    result = handlers.details(Update.new(text: "/details boom-260525-abcd", chat_id: 1))

    assert_equal :reply, result.action
    assert_includes result.text, "Status lookup failed"
    logged = logger.events.find { |event| event[:name] == :details_render_failed }
    refute_nil logged, "a render-time fault on /details must be logged, not a silent no-reply"
    assert_equal "hive", logged[:payload][:project]
    assert_equal "boom-260525-abcd", logged[:payload][:slug]
    assert_equal "RuntimeError", logged[:payload][:error_class]
  end

  def test_details_without_slug_arg_replies_with_usage_hint
    handlers = autofix_handlers([ REVIEW_ERROR_ROW ])

    result = handlers.details(Update.new(text: "/details", chat_id: 1))

    assert_equal :reply, result.action
    assert_equal "Use /details <id|slug>.", result.text
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

  def test_voice_without_file_id_replies_without_transcribe_action
    result = @handlers.voice(VoiceUpdate.new(chat_id: 1, voice: {}))

    assert_equal :reply, result.action
    assert_match(/Couldn't read that voice note/, result.text)
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
