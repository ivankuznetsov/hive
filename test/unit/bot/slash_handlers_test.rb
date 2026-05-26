require "test_helper"
require "hive/bot/handlers/slash_handlers"

class HiveBotSlashHandlersTest < Minitest::Test
  Result = Struct.new(:action, :text, :reply_markup, :command_argv, :commands,
                      :project, :slug, :question_n, :answer_text, :mode,
                      :intent, :alert_reset, :clear_keyboard, :format, keyword_init: true)
  Update = Struct.new(:text, :chat_id, keyword_init: true)

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

  DONE_ROW = Row.new(
    project: "hive",
    slug: "done-260525-abcd",
    stage: "9-done",
    marker: "review_error",
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

  def test_autofix_dispatches_recover_sequence_byte_identical_to_callback_path
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

  def test_autofix_no_retry_verb_for_stage_replies_cleanly
    handlers = autofix_handlers([ DONE_ROW ])

    result = handlers.autofix(Update.new(text: "/autofix done-260525-abcd", chat_id: 1))

    assert_equal :reply, result.action
    assert_match(/No retry verb for stage 9-done/, result.text)
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
end
