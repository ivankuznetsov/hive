require "test_helper"
require "hive/bot/router"
require "hive/bot/conversation_store"
require "hive/bot/telegram"

class HiveBotRouterTest < Minitest::Test
  include HiveTestHelper
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

  def update(text: nil, callback_data: nil, chat_id: 12345, reply_to_text: nil)
    Hive::Bot::Telegram::Update.new(
      update_id: 1,
      chat_id: chat_id,
      from_id: chat_id,
      text: text,
      callback_data: callback_data,
      reply_to_text: reply_to_text
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
    assert_equal [ "hive", "new", "hive", "fix broken cron", "--json" ], result.command_argv
  end

  def test_free_text_inside_active_conversation_writes_current_question
    @store.start(chat_id: 12345, project: "hive", slug: "slug-260514-abcd", question_n: 1)

    result = @router.handle(update(text: "answer body"))

    assert_equal :write_answer_then_reply, result.action
    assert_equal "hive", result.project
    assert_equal "slug-260514-abcd", result.slug
    assert_equal 1, result.question_n
    assert_equal "answer body", result.answer_text
  end

  def test_free_text_inside_path_a_conversation_continues_codex
    @store.start(chat_id: 12345, project: "hive", slug: "slug-260514-abcd",
                 question_n: 1, mode: :path_a)

    result = @router.handle(update(text: "clarifying answer"))

    assert_equal :start_codex, result.action
    assert_equal "hive", result.project
    assert_equal "slug-260514-abcd", result.slug
    assert_equal "clarifying answer", result.answer_text
  end

  def test_free_text_reply_can_reattach_to_slug_after_restart
    result = @router.handle(
      update(text: "offline answer", reply_to_text: "hive/slug-260514-abcd (2-brainstorm)")
    )

    assert_equal :write_answer_then_reply, result.action
    assert_equal "hive", result.project
    assert_equal "slug-260514-abcd", result.slug
    assert_nil result.question_n
  end

  def test_slash_answer_returns_start_answer_action_not_immediate_start
    result = @router.handle(update(text: "/answer slug-260514-abcd"))

    assert_equal :start_answer, result.action
    assert_equal "slug-260514-abcd", result.slug
    assert_equal :path_b, result.mode
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

  def test_compacted_callback_is_resolved_before_dispatch
    long_slug = "slug-" + ("a" * 80)
    token = Hive::Bot::NotificationBuilders.compact_callback("approve:plan:hive:#{long_slug}:2-brainstorm")

    result = @router.handle(update(callback_data: token))

    assert_equal :dispatch_then_reply, result.action
    assert_equal [ "hive", "plan", long_slug, "--from", "2-brainstorm",
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

  def test_default_projects_provider_reads_registered_projects
    with_tmp_global_config do
      router = Hive::Bot::Router.new(
        bot_config: { "chat_id_allowlist" => [ 12345 ] },
        logger: @logger,
        conversation_store: @store
      )

      result = router.handle(update(text: "/idea fix broken cron"))

      assert_equal :reply, result.action
      assert_match(/No Hive projects are registered yet/, result.text)
    end
  end

  def test_classifies_all_callback_prefixes
    cases = {
      "reject:anything" => :callback_reject,
      "autofix:hive:slug-260514-abcd:6-review:REVIEW_ERROR" => :callback_autofix,
      "open_laptop:hive:slug-260514-abcd" => :callback_open_laptop,
      "details:hive:slug-260514-abcd" => :callback_show_details,
      "refresh_diagnose:hive:slug-260514-abcd:6-review" => :callback_refresh_diagnose,
      "answer:hive:slug-260514-abcd" => :callback_answer,
      "path_a_yes:hive:slug-260514-abcd" => :callback_path_a_yes,
      "path_a_type:hive:slug-260514-abcd" => :callback_path_a_just_type,
      "codex_write:hive:slug-260514-abcd:1" => :callback_codex_write_draft,
      "codex_edit:hive:slug-260514-abcd:1" => :callback_codex_edit,
      "codex_cancel:hive:slug-260514-abcd:1" => :callback_codex_cancel,
      "findings:accept_all:hive:slug-260514-abcd:6-review" => :callback_findings_accept_all,
      "findings:reject_all:hive:slug-260514-abcd:6-review" => :callback_findings_reject_all,
      "idea_project_new:token" => :callback_idea_project_new,
      "unknown:hive:slug-260514-abcd" => :unknown
    }

    cases.each do |callback_data, intent|
      assert_equal intent, @router.classify(update(callback_data: callback_data)), callback_data
    end
  end

  def test_slash_approve_dispatches_approve_command
    result = @router.handle(update(text: "/approve slug-260514-abcd"))

    assert_equal :dispatch_then_reply, result.action
    assert_equal [ "hive", "approve", "slug-260514-abcd", "--json" ], result.command_argv
  end

  def test_slash_help_returns_commands_reply
    result = @router.handle(update(text: "/help"))

    assert_equal :reply, result.action
    assert_includes result.text, "/status"
    assert_includes result.text, "/approve <slug>"
  end

  def test_legacy_callback_update_without_with_still_dispatches
    legacy = LegacyCallbackUpdate.new(
      update_id: 1,
      chat_id: 12345,
      callback_data: "reject:anything"
    )

    assert_equal :callback_reject, @router.classify(legacy)
    result = @router.handle(legacy)

    assert_equal :reply, result.action
    assert_equal "Left unchanged.", result.text
  end

  def test_legacy_message_update_without_reply_to_text_gets_help_hint
    result = @router.handle(LegacyMessageUpdate.new(update_id: 1, chat_id: 12345, text: "hello"))

    assert_equal :reply, result.action
    assert_match(/\/help/, result.text)
  end

  def test_handle_rejects_impossible_classifier_intent
    @router.define_singleton_method(:classify) { |_update| :not_an_intent }

    error = assert_raises(RuntimeError) { @router.handle(update(text: "/status")) }

    assert_match(/unknown intent :not_an_intent/, error.message)
  end

  def test_handle_rejects_disallowed_result_action
    @router.define_singleton_method(:dispatch) do |_intent, _update|
      Hive::Bot::Router::Result.new(action: :teleport)
    end

    error = assert_raises(RuntimeError) { @router.handle(update(text: "/status")) }

    assert_match(/action :teleport is not allowed/, error.message)
  end

  def test_done_refuses_when_pending_codex_confirm_exists
    @store.start(chat_id: 12345, slug: "slug", question_n: 1)
    @store.update(chat_id: 12345, slug: "slug", awaiting_confirm: true)

    result = @router.handle(update(text: "/done"))

    assert_equal :reply, result.action
    assert_match(/awaiting confirm/, result.text)
  end

  LegacyCallbackUpdate = Struct.new(:update_id, :chat_id, :callback_data, keyword_init: true) do
    def callback_query?
      true
    end
  end

  LegacyMessageUpdate = Struct.new(:update_id, :chat_id, :text, keyword_init: true) do
    def callback_query?
      false
    end
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
