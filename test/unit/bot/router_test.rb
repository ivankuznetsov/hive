require "test_helper"
require "hive/bot/router"
require "hive/bot/conversation_store"
require "hive/bot/telegram"

class HiveBotRouterTest < Minitest::Test
  def setup
    @logger = StubLogger.new
    @store = Hive::Bot::ConversationStore.new
    @projects = [
      { "name" => "hive", "path" => "/tmp/hive", "hive_state_path" => "/tmp/hive/.hive-state" },
      { "name" => "writero", "path" => "/tmp/writero", "hive_state_path" => "/tmp/writero/.hive-state" }
    ]
    @router = Hive::Bot::Router.new(
      bot_config: { "chat_id_allowlist" => [ 12345 ] },
      logger: @logger,
      conversation_store: @store,
      projects_provider: -> { @projects }
    )
  end

  def update(text: nil, callback_data: nil, chat_id: 12345)
    Hive::Bot::Telegram::Update.new(
      update_id: 1,
      chat_id: chat_id,
      from_id: chat_id,
      text: text,
      callback_data: callback_data
    )
  end

  def test_classifies_slash_commands
    assert_equal :slash_status, @router.classify(update(text: "/status"))
    assert_equal :slash_queue, @router.classify(update(text: "/queue"))
    assert_equal :slash_idea, @router.classify(update(text: "/idea fix cron"))
    assert_equal :slash_answer, @router.classify(update(text: "/answer slug"))
    assert_equal :slash_approve, @router.classify(update(text: "/approve slug"))
    assert_equal :slash_done, @router.classify(update(text: "/done"))
    assert_equal :slash_help, @router.classify(update(text: "/help"))
  end

  def test_unauthorized_update_returns_noop_and_logs_once
    result = @router.handle(update(text: "/status", chat_id: 999))
    @router.handle(update(text: "/status", chat_id: 999))

    assert_equal :noop, result.action
    assert_equal 1, @logger.events.count { |event, _| event == :update_rejected_unauthorized }
  end

  def test_status_returns_dispatch_descriptor
    result = @router.handle(update(text: "/status"))

    assert_equal :dispatch_then_reply, result.action
    assert_equal [ "hive", "status", "--json" ], result.command_argv
  end

  def test_idea_returns_project_picker_keyboard
    result = @router.handle(update(text: "/idea fix broken cron"))

    assert_equal :reply, result.action
    assert_match(/Pick a project/, result.text)
    assert_equal "hive", result.reply_markup.first.first[:text]
    assert_match(/\Aidea_project:hive:/, result.reply_markup.first.first[:callback_data])
  end

  def test_idea_project_callback_dispatches_hive_new
    picker = @router.handle(update(text: "/idea fix broken cron"))
    callback = picker.reply_markup.first.first[:callback_data]

    result = @router.handle(update(callback_data: callback))

    assert_equal :dispatch_then_reply, result.action
    assert_equal [ "hive", "new", "hive", "fix broken cron" ], result.command_argv
  end

  def test_free_text_inside_active_conversation_writes_current_question
    @router.handle(update(text: "/answer slug-260514-abcd"))

    result = @router.handle(update(text: "answer body"))

    assert_equal :write_answer_then_reply, result.action
    assert_equal "slug-260514-abcd", result.slug
    assert_equal 1, result.question_n
    assert_equal "answer body", result.answer_text
  end

  def test_free_text_outside_conversation_gets_help_hint
    result = @router.handle(update(text: "hello"))

    assert_equal :reply, result.action
    assert_match(/\/help/, result.text)
  end

  def test_approve_callback_dispatches_workflow_verb
    result = @router.handle(
      update(callback_data: "approve:plan:hive:slug-260514-abcd:2-brainstorm")
    )

    assert_equal :dispatch_then_reply, result.action
    assert_equal [ "hive", "plan", "slug-260514-abcd", "--from", "2-brainstorm",
                   "--project", "hive", "--json" ], result.command_argv
  end

  def test_clear_retry_callback_dispatches_marker_clear_then_retry
    result = @router.handle(
      update(callback_data: "clear_retry:hive:slug-260514-abcd:5-review:review_error")
    )

    assert_equal :dispatch_commands, result.action
    assert_equal [ "hive", "markers", "clear", "slug-260514-abcd", "--name",
                   "REVIEW_ERROR", "--project", "hive", "--json" ], result.commands.first
    assert_equal [ "hive", "review", "slug-260514-abcd", "--from", "5-review",
                   "--project", "hive", "--json" ], result.commands.last
  end

  def test_done_refuses_when_pending_codex_confirm_exists
    @store.start(chat_id: 12345, slug: "slug", question_n: 1)
    @store.update(chat_id: 12345, slug: "slug", awaiting_confirm: true)

    result = @router.handle(update(text: "/done"))

    assert_equal :reply, result.action
    assert_match(/awaiting confirm/, result.text)
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
