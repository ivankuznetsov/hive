require "test_helper"
require "hive/bot/handlers/callback_handlers"

# Pins the dispatch shape emitted by CallbackHandlers for callbacks that
# fan out to `hive` subprocess invocations. The router exposes one Result
# struct per callback; this test exercises the per-callback methods so
# changes to argv shape (e.g., row 24 — show_details switching to
# --diagnose) cannot regress silently.
class HiveBotCallbackHandlersTest < Minitest::Test
  Result = Struct.new(:action, :text, :reply_markup, :command_argv, :commands,
                      :project, :slug, :question_n, :answer_text, :mode,
                      :intent, keyword_init: true)

  def setup
    @handlers = Hive::Bot::Handlers::CallbackHandlers.new(
      pending_ideas: {},
      set_last_project: ->(_) {},
      conversation_store: nil,
      result_class: Result
    )
  end

  def update(callback_data)
    Struct.new(:callback_data).new(callback_data)
  end

  def test_show_details_dispatches_status_diagnose_for_targeted_envelope
    # The Show-details button previously ran a full `hive status --json`
    # and replied with the entire snapshot. PR #84 review row 24 narrows
    # it to `hive status --diagnose <slug> --project <project> --json`
    # so the bot reply renders the bounded summary + detail instead of
    # dumping the whole status payload.
    result = @handlers.handle(:callback_show_details, update("details:alpha:red-task-260518-aaaa"))

    assert_equal :dispatch_then_reply, result.action
    assert_equal "alpha", result.project
    assert_equal "red-task-260518-aaaa", result.slug
    assert_equal(
      [ "hive", "status", "--diagnose", "red-task-260518-aaaa", "--project", "alpha", "--json" ],
      result.command_argv,
      "show_details must invoke `hive status --diagnose` so the reply renders the bounded envelope"
    )
  end
end
