require "test_helper"
require "hive/bot/handlers/slash_handlers"

class HiveBotSlashHandlersTest < Minitest::Test
  Result = Struct.new(:action, :text, :reply_markup, :command_argv, :commands,
                      :project, :slug, :question_n, :answer_text, :mode,
                      :intent, :format, keyword_init: true)
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
