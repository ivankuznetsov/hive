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
                      :intent, :alert_reset, :clear_keyboard, keyword_init: true)
  FakeLogger = Struct.new(:events, keyword_init: true) do
    def event(name, **payload)
      events << { name: name, payload: payload }
    end
  end

  def setup
    @pending_ideas = {}
    @last_projects = []
    @logger = FakeLogger.new(events: [])
    @handlers = Hive::Bot::Handlers::CallbackHandlers.new(
      pending_ideas: @pending_ideas,
      set_last_project: ->(project) { @last_projects << project },
      conversation_store: nil,
      result_class: Result,
      logger: @logger
    )
  end

  def update(callback_data)
    Struct.new(:callback_data).new(callback_data)
  end

  def test_simple_reply_callbacks_return_operator_facing_text
    cases = {
      callback_reject: [ "reject:anything", "Left unchanged." ],
      callback_open_laptop: [ "open_laptop:hive:slug", "Open laptop for this one." ],
      callback_codex_edit: [ "codex_edit:hive:slug:1", "Send the edited answer as a message." ],
      callback_codex_cancel: [ "codex_cancel:hive:slug:1", "Draft cancelled." ],
      unknown: [ "unknown:hive:slug", "Bot got confused - please retry from /queue." ]
    }

    cases.each do |intent, (data, text)|
      result = @handlers.handle(intent, update(data))
      assert_equal :reply, result.action
      assert_equal text, result.text
    end
  end

  def test_answer_and_path_callbacks_start_expected_answer_modes
    answer = @handlers.handle(:callback_answer, update("answer:hive:brainstorm-task"))
    path_a = @handlers.handle(:callback_path_a_yes, update("path_a:hive:brainstorm-task"))
    path_b = @handlers.handle(:callback_path_a_just_type, update("path_b:hive:brainstorm-task"))

    assert_equal :start_answer, answer.action
    assert_equal :path_b, answer.mode
    assert_equal :start_codex, path_a.action
    assert_equal :path_a, path_a.mode
    assert_equal :reply, path_b.action
    assert_equal "Send the answer as a message.", path_b.text
  end

  def test_idea_project_new_deletes_pending_token_and_replies_with_scope_message
    @pending_ideas["tok"] = "build this"

    result = @handlers.handle(:callback_idea_project_new, update("idea_project_new:tok"))

    refute @pending_ideas.key?("tok")
    assert_equal :reply, result.action
    assert_match(/out of MVP scope/, result.text)
  end

  def test_idea_project_expired_token_replies_without_dispatch
    result = @handlers.handle(:callback_idea_project_pick, update("idea_project:hive:missing"))

    assert_equal :reply, result.action
    assert_match(/picker expired/, result.text)
  end

  def test_idea_project_dispatches_new_command_and_remembers_project
    @pending_ideas["tok"] = { text: "ship the thing" }

    result = @handlers.handle(:callback_idea_project_pick, update("idea_project:hive:tok"))

    assert_equal [ "hive" ], @last_projects
    assert_equal :dispatch_then_reply, result.action
    assert_equal "hive", result.project
    assert_equal [ "hive", "new", "hive", "ship the thing", "--json" ], result.command_argv
    refute @pending_ideas.key?("tok")
  end

  def test_codex_write_validates_question_number
    ok = @handlers.handle(:callback_codex_write_draft, update("codex_write:hive:slug:12"))
    bad = @handlers.handle(:callback_codex_write_draft, update("codex_write:hive:slug:not-int"))

    assert_equal :confirm_codex_draft, ok.action
    assert_equal 12, ok.question_n
    assert_equal :reply, bad.action
    assert_match(/bot got confused/i, bad.text)
    assert_equal :callback_malformed, @logger.events.last.fetch(:name)
    assert_equal "non_integer_question_n", @logger.events.last.fetch(:payload).fetch(:reason)
  end

  def test_findings_accept_all_dispatches_toggle_then_retry
    result = @handlers.handle(:callback_findings_accept_all, update("findings_accept_all:any:hive:slug:6-review"))

    assert_equal :dispatch_commands, result.action
    assert_equal [
      [ "hive", "accept-finding", "slug", "--all", "--stage", "6-review", "--project", "hive", "--json" ],
      [ "hive", "review", "slug", "--from", "6-review", "--project", "hive", "--json" ]
    ], result.commands
  end

  def test_findings_reject_all_without_retry_stage_only_toggles_findings
    result = @handlers.handle(:callback_findings_reject_all, update("findings_reject_all:any:hive:slug:unknown-stage"))

    assert_equal :dispatch_commands, result.action
    assert_equal [
      [ "hive", "reject-finding", "slug", "--all", "--stage", "unknown-stage", "--project", "hive", "--json" ]
    ], result.commands
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
    result = @handlers.handle(
      :callback_refresh_diagnose,
      update("refresh_diagnose:alpha:red-task-260518-bbbb:6-review")
    )

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

  def test_clear_and_retry_passes_marker_match_attr_when_present
    result = @handlers.handle(
      :callback_clear_and_retry,
      update("clear_retry:alpha:red-task-260518-cccc:6-review:REVIEW_ERROR:pass=2")
    )

    assert_equal(
      [ "hive", "markers", "clear", "red-task-260518-cccc", "--name",
        "REVIEW_ERROR", "--project", "alpha", "--match-attr", "pass=2", "--json" ],
      result.commands.first
    )
    assert_equal({ project: "alpha", slug: "red-task-260518-cccc", stage: "6-review" }, result.alert_reset)
  end

  def test_clear_and_retry_none_marker_skips_marker_clear_and_runs_stage
    result = @handlers.handle(
      :callback_clear_and_retry,
      update("clear_retry:alpha:plan-task-260519-abcd:3-plan:NONE")
    )

    assert_equal :dispatch_commands, result.action
    assert_equal(
      [ [ "hive", "plan", "plan-task-260519-abcd", "--from", "3-plan", "--project", "alpha", "--json" ] ],
      result.commands,
      "markerless synthetic errors must retry the stage directly instead of clearing a non-existent ERROR marker"
    )
  end

  def test_autofix_marker_dispatches_clear_then_retry
    result = @handlers.handle(
      :callback_autofix,
      update("autofix:alpha:red-task-260518-cccc:6-review:REVIEW_ERROR:pass=2")
    )

    assert_equal :dispatch_commands, result.action
    assert_equal(
      [
        [ "hive", "markers", "clear", "red-task-260518-cccc", "--name",
          "REVIEW_ERROR", "--project", "alpha", "--match-attr", "pass=2", "--json" ],
        [ "hive", "review", "red-task-260518-cccc", "--from", "6-review", "--project", "alpha", "--json" ]
      ],
      result.commands
    )
    assert_equal({ project: "alpha", slug: "red-task-260518-cccc", stage: "6-review" }, result.alert_reset)
    assert_equal true, result.clear_keyboard,
                 "Autofix must request keyboard removal to prevent double-tap dispatch."
  end

  def test_autofix_execute_stale_replies_without_dispatch
    result = @handlers.handle(
      :callback_autofix,
      update("autofix:alpha:exec-task-260519-abcd:4-execute:EXECUTE_STALE")
    )

    assert_equal :reply, result.action
    assert_match(/no automatic recovery/i, result.text)
  end

  def test_autofix_none_marker_dispatches_retry_only
    result = @handlers.handle(
      :callback_autofix,
      update("autofix:alpha:plan-task-260519-abcd:3-plan:NONE")
    )

    assert_equal(
      [ [ "hive", "plan", "plan-task-260519-abcd", "--from", "3-plan", "--project", "alpha", "--json" ] ],
      result.commands
    )
    assert_equal({ project: "alpha", slug: "plan-task-260519-abcd", stage: "3-plan" }, result.alert_reset)
  end

  def test_autofix_agent_working_marker_dispatches_retry_only
    result = @handlers.handle(
      :callback_autofix,
      update("autofix:alpha:exec-task-260519-abcd:4-execute:AGENT_WORKING")
    )

    assert_equal(
      [ [ "hive", "develop", "exec-task-260519-abcd", "--from", "4-execute", "--project", "alpha", "--json" ] ],
      result.commands
    )
  end

  def test_autofix_unknown_stage_replies_without_dispatch
    result = @handlers.handle(
      :callback_autofix,
      update("autofix:alpha:done-task-260519-abcd:9-done:ERROR")
    )

    assert_equal :reply, result.action
    assert_equal "No retry verb for stage 9-done.", result.text
  end

  def test_autofix_empty_stage_reply_labels_stage_as_empty
    result = @handlers.handle(
      :callback_autofix,
      update("autofix:alpha:some-task-260519-abcd::ERROR")
    )

    assert_equal :reply, result.action
    assert_equal "No retry verb for stage (empty).", result.text,
                 "empty stage must be labelled (empty) rather than leaving a blank in the reply"
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
