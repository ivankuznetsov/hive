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
      set_last_project: ->(_) { },
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

  def test_show_details_passes_stage_when_callback_carries_it
    result = @handlers.handle(:callback_show_details, update("details:alpha:red-task-260518-stage:6-review"))

    assert_equal(
      [ "hive", "status", "--diagnose", "red-task-260518-stage",
        "--project", "alpha", "--stage", "6-review", "--json" ],
      result.command_argv,
      "show_details must pass --stage so duplicate slugs in the same project resolve"
    )
  end

  def test_refresh_diagnose_dispatches_diagnose_write_for_fresh_agent_verdict
    # Bot-side parity of the TUI R keystroke (issue #91). The Refresh
    # diagnosis button must spawn the configured execute AgentProfile
    # via --write, not just re-read the cached artifact. The argv
    # shape is pinned so a future tweak cannot silently turn the
    # write-path back into a read-only fetch.
    result = @handlers.handle(:callback_refresh_diagnose, update("refresh_diagnose:alpha:red-task-260518-bbbb:6-review"))

    assert_equal :dispatch_then_reply, result.action
    assert_equal "alpha", result.project
    assert_equal "red-task-260518-bbbb", result.slug
    assert_equal(
      [ "hive", "status", "--diagnose", "red-task-260518-bbbb",
        "--project", "alpha", "--stage", "6-review", "--write", "--force", "--json" ],
      result.command_argv,
      "refresh_diagnose must invoke --diagnose --write --force so the LLM verdict refreshes"
    )
  end

  def test_refresh_diagnose_keeps_legacy_callback_shape_supported
    result = @handlers.handle(:callback_refresh_diagnose, update("refresh_diagnose:alpha:red-task-260518-legacy"))

    assert_equal(
      [ "hive", "status", "--diagnose", "red-task-260518-legacy",
        "--project", "alpha", "--write", "--force", "--json" ],
      result.command_argv,
      "existing Telegram buttons without a stage must keep working until they expire"
    )
  end

  def test_clear_and_retry_uses_current_review_stage_name
    result = @handlers.handle(
      :callback_clear_and_retry,
      update("clear_retry:alpha:red-task-260518-cccc:6-review:REVIEW_ERROR")
    )

    assert_equal(
      [ "hive", "review", "red-task-260518-cccc", "--from", "6-review", "--project", "alpha", "--json" ],
      result.commands.last,
      "clear-and-retry must dispatch the current review-stage verb, not a retired stage map"
    )
  end

  def test_refresh_diagnose_rejects_malformed_callback_data
    # Defense against malformed callback round-trips. Any non-3-part
    # callback (legacy data, manual postback fuzzing) should fall back
    # to the friendly "bot got confused" reply rather than raising.
    result = @handlers.handle(:callback_refresh_diagnose, update("refresh_diagnose:alpha"))

    assert_equal :reply, result.action
    assert_match(/bot got confused/i, result.text)
  end
end
