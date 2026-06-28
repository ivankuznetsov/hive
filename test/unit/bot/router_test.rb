require "test_helper"
require "hive/bot/router"
require "hive/bot/conversation_store"
require "hive/bot/idea_draft_store"
require "hive/bot/telegram"

class HiveBotRouterTest < Minitest::Test
  include HiveTestHelper
  def setup
    @logger = StubLogger.new
    @store = Hive::Bot::ConversationStore.new
    @draft_store = Hive::Bot::IdeaDraftStore.new
    @projects = [
      { "name" => "hive", "path" => "/tmp/hive", "hive_state_path" => "/tmp/hive/.hive-state" },
      { "name" => "writero", "path" => "/tmp/writero", "hive_state_path" => "/tmp/writero/.hive-state" }
    ]
    @router = Hive::Bot::Router.new(
      bot_config: { "chat_id_allowlist" => [ 12345 ] },
      logger: @logger,
      conversation_store: @store,
      idea_draft_store: @draft_store,
      projects_provider: -> { @projects }
    )
  end

  def update(text: nil, callback_data: nil, chat_id: 12345, reply_to_text: nil,
             photo: nil, document: nil, voice: nil, caption: nil)
    Hive::Bot::Telegram::Update.new(
      update_id: 1,
      chat_id: chat_id,
      from_id: chat_id,
      text: text,
      callback_data: callback_data,
      reply_to_text: reply_to_text,
      photo: photo,
      document: document,
      voice: voice,
      caption: caption
    )
  end

  def test_classifies_slash_commands
    assert_equal :slash_status, @router.classify(update(text: "/status"))
    assert_equal :slash_queue, @router.classify(update(text: "/queue"))
    assert_equal :slash_idea, @router.classify(update(text: "/idea fix cron"))
    assert_equal :slash_answer, @router.classify(update(text: "/answer slug"))
    assert_equal :slash_approve, @router.classify(update(text: "/approve slug"))
    assert_equal :slash_autofix, @router.classify(update(text: "/autofix slug"))
    assert_equal :slash_details, @router.classify(update(text: "/details slug"))
    assert_equal :slash_done, @router.classify(update(text: "/done"))
    assert_equal :slash_help, @router.classify(update(text: "/help"))
    assert_equal :slash_start, @router.classify(update(text: "/start")),
                 "Telegram's automatic first-contact command must be welcomed, not met with 'I did not understand'"
    start = @router.handle(update(text: "/start"))
    assert_equal :reply, start.action
    assert_match(/Connected/, start.text, "first contact must be welcomed, not handed a shrug")
  end

  def test_autofix_slash_resolves_against_default_empty_snapshot_provider
    # The router's default status_snapshot_provider returns [] so unknown
    # slugs (which is every slug, in this test setup) reply with the
    # archive hint. This covers both the default lambda body and the
    # /autofix dispatch path without needing a Supervisor instance.
    result = @router.handle(update(text: "/autofix unknown-260526-zzzz"))

    assert_equal :reply, result.action
    assert_match(/Slug not found/, result.text)
  end

  def test_details_slash_resolves_against_default_empty_snapshot_provider
    result = @router.handle(update(text: "/details unknown-260526-zzzz"))

    assert_equal :reply, result.action
    assert_match(/Slug not found/, result.text)
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

  def test_bare_text_defaults_to_idea_project_picker
    text = "add retry to webhook"

    assert_equal :idea_bare_text, @router.classify(update(text: text))

    result = @router.handle(update(text: text))

    assert_equal :reply, result.action
    assert_match(/Pick a project/, result.text)
    refute_match(/did not understand/i, result.text)
    assert_equal text, @draft_store.get(chat_id: 12345).text
  end

  def test_one_character_bare_text_defaults_to_idea_project_picker
    result = @router.handle(update(text: "k"))

    assert_equal :reply, result.action
    assert_match(/Pick a project/, result.text)
    assert_equal "k", @draft_store.get(chat_id: 12345).text
  end

  def test_forwarded_style_bare_text_defaults_to_idea_project_picker
    forwarded_text = "Forwarded: retry the webhook on timeout"

    assert_equal :idea_bare_text, @router.classify(update(text: forwarded_text))

    result = @router.handle(update(text: forwarded_text))

    assert_equal :reply, result.action
    assert_match(/Pick a project/, result.text)
    assert_equal forwarded_text, @draft_store.get(chat_id: 12345).text
  end

  def test_blank_bare_text_starts_idea_text_capture
    assert_equal :idea_bare_text, @router.classify(update(text: "   "))

    result = @router.handle(update(text: "   "))

    assert_equal :reply, result.action
    assert_match(/Send the idea text/, result.text)
    refute_match(/did not understand/i, result.text)
    draft = @draft_store.get(chat_id: 12345)
    assert_equal :awaiting_text, draft.phase
    assert_nil draft.text
  end

  def test_content_less_update_opens_idea_text_capture
    # A non-text / non-media / non-voice update (sticker, location, contact,
    # video) carries no effective_text, so it falls through to :idea_bare_text
    # and opens an awaiting_text draft asking for the idea text — rather than the
    # old "I did not understand that" reply. Contrast a rejected attachment,
    # which leaves no draft behind.
    assert_equal :idea_bare_text, @router.classify(update)

    result = @router.handle(update)

    assert_equal :reply, result.action
    assert_match(/Send the idea text/, result.text)
    refute_match(/did not understand/i, result.text)
    draft = @draft_store.get(chat_id: 12345)
    assert_equal :awaiting_text, draft.phase
    assert_nil draft.text
  end

  def test_bare_text_during_active_draft_clobbers_prior_draft
    # Most-aggressive accepted default: bare text arriving while a draft is
    # mid-flight starts a fresh idea, discarding the in-progress draft and any
    # staged attachments with no "previous idea discarded" notice. Stage a real
    # attachment first so the clobber actually exercises
    # IdeaDraftStore#start -> clear -> cleanup_draft (otherwise the
    # staging-cleanup path is never run), then pin the chosen behavior so a
    # future protect/notify change is a deliberate, test-visible decision.
    @draft_store.start(chat_id: 12345, phase: :collecting_files, text: "old idea", token: "tok")
    staging_dir = @draft_store.ensure_staging_dir(chat_id: 12345)
    File.write(File.join(staging_dir, "image-1.png"), "staged bytes")
    assert File.directory?(staging_dir), "precondition: the prior draft has a staging dir on disk"

    result = @router.handle(update(text: "new idea"))

    assert_equal :reply, result.action
    assert_match(/Pick a project/, result.text)
    draft = @draft_store.get(chat_id: 12345)
    assert_equal "new idea", draft.text
    assert_equal :awaiting_project, draft.phase
    refute_equal "tok", draft.token,
                 "the prior draft is clobbered into a fresh one, not continued"
    refute File.exist?(staging_dir),
           "clobbering the prior draft must clean up its staged attachments on disk"
  end

  def test_unknown_slash_command_stays_unknown
    assert_equal :unknown, @router.classify(update(text: "/foobar"))

    result = @router.handle(update(text: "/foobar"))

    assert_equal :reply, result.action
    assert_match(/did not understand/, result.text)
    assert_nil @draft_store.get(chat_id: 12345)
  end

  def test_unknown_slash_during_awaiting_text_draft_is_captured_as_literal_idea_text
    # With an open awaiting_text draft the awaiting_text branch wins before the
    # unknown-slash guard, so even "/foobar" is recorded as the idea's literal
    # text rather than refused as an unknown command. Pin this so a future
    # reorder of the classifier's awaiting_text vs unknown-slash checks stays a
    # deliberate, test-visible decision (contrast
    # test_unknown_slash_command_stays_unknown, where no draft is open).
    @draft_store.start(chat_id: 12345, phase: :awaiting_text, token: "tok")

    assert_equal :idea_text_capture, @router.classify(update(text: "/foobar"))

    result = @router.handle(update(text: "/foobar"))

    assert_equal :reply, result.action
    assert_match(/Pick a project/, result.text)
    assert_equal "/foobar", @draft_store.get(chat_id: 12345).text
  end

  def test_idea_project_callback_enters_file_collection
    picker = @router.handle(update(text: "/idea fix broken cron"))
    callback = picker.reply_markup.first.first[:callback_data]

    result = @router.handle(update(callback_data: callback))

    assert_equal :reply, result.action
    assert_match(/Send any files now/, result.text)
    assert_equal "Done", result.reply_markup.first.first[:text]
    assert_match(/\Aidea_done:/, result.reply_markup.first.first[:callback_data])
  end

  def test_idea_done_callback_emits_commit_intent
    picker = @router.handle(update(text: "/idea fix broken cron"))
    collect = @router.handle(update(callback_data: picker.reply_markup.first.first[:callback_data]))
    done_callback = collect.reply_markup.first.first[:callback_data]

    result = @router.handle(update(callback_data: done_callback))

    assert_equal :commit_idea, result.action
    assert_equal "hive", result.project
    assert_equal({ chat_id: 12345 }, result.attachment)
  end

  def test_idea_without_text_awaits_next_message
    result = @router.handle(update(text: "/idea"))

    assert_equal :reply, result.action
    assert_match(/Send the idea text/, result.text)
  end

  def test_free_text_while_awaiting_idea_text_shows_project_picker
    @router.handle(update(text: "/idea"))

    result = @router.handle(update(text: "fix the login bug"))

    assert_equal :reply, result.action
    assert_match(/Pick a project/, result.text)
  end

  def test_voice_update_emits_transcribe_action
    result = @router.handle(update(voice: {
      file_id: "voice-file",
      file_size: 1234
    }))

    assert_equal :transcribe_voice, result.action
    assert_equal "voice-file", result.attachment.fetch(:file_id)
    assert_equal 1234, result.attachment.fetch(:file_size)
  end

  def test_text_while_awaiting_transcript_confirm_replaces_transcript
    draft = @draft_store.start(chat_id: 12345, phase: :awaiting_transcript_confirm,
                               text: "old", token: "tok", origin: :voice)

    result = @router.handle(update(text: "corrected transcript"))

    assert_equal :reply, result.action
    assert_match(/corrected transcript/, result.text)
    assert_equal "Confirm", result.reply_markup.first.first[:text]
    assert_equal "idea_voice_confirm:tok", result.reply_markup.first.first[:callback_data]
    assert_equal "corrected transcript", @draft_store.get(chat_id: draft.chat_id).text
  end

  def test_voice_while_awaiting_transcript_confirm_retranscribes
    @draft_store.start(chat_id: 12345, phase: :awaiting_transcript_confirm,
                       text: "old", token: "tok", origin: :voice)

    result = @router.handle(update(voice: {
      file_id: "voice-two",
      file_size: 222
    }))

    # Re-transcribe is handled transparently by ensure_voice_draft (it reuses
    # the existing voice draft), so a replacement voice note routes to the
    # same :transcribe_voice action — no separate edit flag is carried.
    assert_equal :transcribe_voice, result.action
    assert_equal "voice-two", result.attachment.fetch(:file_id)
  end

  def test_voice_while_non_voice_draft_is_open_preserves_current_draft
    @draft_store.start(chat_id: 12345, phase: :collecting_files, text: "typed idea", token: "tok")

    result = @router.handle(update(voice: {
      file_id: "voice-two",
      file_size: 222
    }))

    assert_equal :reply, result.action
    assert_match(/Finish or discard the current idea draft/, result.text)
    draft = @draft_store.get(chat_id: 12345)
    assert_equal :collecting_files, draft.phase
    assert_equal "typed idea", draft.text
    assert_equal "tok", draft.token
  end

  def test_text_while_awaiting_text_after_voice_fallback_routes_to_capture
    # After a transcription failure the supervisor leaves a voice-origin draft
    # in :awaiting_text. Plain text must route to idea text capture, not the
    # unknown/help fallback — otherwise the operator's idea is dropped.
    @draft_store.start(chat_id: 12345, phase: :awaiting_text, token: "tok", origin: :voice)

    assert_equal :idea_text_capture, @router.classify(update(text: "the actual idea"))

    result = @router.handle(update(text: "the actual idea"))
    assert_equal :reply, result.action
    assert_match(/Pick a project/, result.text)
    assert_equal "the actual idea", @draft_store.get(chat_id: 12345).text
  end

  def test_active_brainstorm_conversation_wins_for_plain_text_while_transcript_awaits_confirm
    @draft_store.start(chat_id: 12345, phase: :awaiting_transcript_confirm,
                       text: "old", token: "tok", origin: :voice)
    @store.start(chat_id: 12345, project: "hive", slug: "slug-260514-abcd", question_n: 1)

    result = @router.handle(update(text: "answer body"))

    assert_equal :write_answer_then_reply, result.action
    assert_equal "answer body", result.answer_text
    assert_equal "old", @draft_store.get(chat_id: 12345).text
  end

  def test_media_without_caption_starts_file_first_draft
    result = @router.handle(update(document: {
      file_id: "doc",
      file_name: "notes.pdf",
      mime_type: "application/pdf",
      file_size: 12
    }))

    assert_equal :stage_attachment, result.action
    assert_match(/What's the idea/, result.text)
    assert_equal "doc", result.attachment.fetch(:file_id)
    assert_equal "pdf", result.attachment.fetch(:ext)
  end

  def test_media_with_caption_starts_project_picker_and_stage_action
    result = @router.handle(update(caption: "fix login", photo: {
      file_id: "photo",
      file_size: 12
    }))

    assert_equal :stage_attachment, result.action
    assert_match(/Pick a project/, result.text)
    assert_equal "photo", result.attachment.fetch(:file_id)
  end

  def test_disallowed_media_replies_without_stage_action
    result = @router.handle(update(document: {
      file_id: "doc",
      file_name: "run.exe",
      mime_type: "application/octet-stream",
      file_size: 12
    }))

    assert_equal :reply, result.action
    assert_match(/Unsupported attachment type/, result.text)
    assert_nil @draft_store.get(chat_id: 12345),
               "A rejected bare media file must not leave a phantom draft that hijacks the next message"

    # The assert_nil above is the authoritative phantom-draft guard — do not
    # delete it. The follow-up below is only a smoke check that a fresh idea
    # still works after a rejected attachment: under the bare-text-idea default
    # a leaked :awaiting_text draft and a fresh idea produce identical
    # observable output (both reply "Pick a project" with draft.text ==
    # "just chatting"), so the follow-up can no longer catch the regression on
    # its own.
    followup = @router.handle(update(text: "just chatting"))
    assert_equal :reply, followup.action
    assert_match(/Pick a project/, followup.text)
    assert_equal "just chatting", @draft_store.get(chat_id: 12345).text
  end

  def test_idea_text_capture_does_not_hijack_active_brainstorm_conversation
    @router.handle(update(text: "/idea"))
    @store.start(chat_id: 12345, project: "hive", slug: "slug-260514-abcd", question_n: 1)

    result = @router.handle(update(text: "answer body"))

    assert_equal :write_answer_then_reply, result.action
    assert_equal "answer body", result.answer_text
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

  def test_voice_inside_active_conversation_transcribes_as_answer
    @store.start(chat_id: 12345, project: "hive", slug: "slug-260514-abcd", question_n: 1)

    result = @router.handle(update(voice: {
      file_id: "voice-answer",
      file_size: 2345
    }))

    assert_equal :transcribe_voice, result.action
    assert_equal "hive", result.project
    assert_equal "slug-260514-abcd", result.slug
    assert_equal 1, result.question_n
    assert_equal :path_b, result.mode
    assert_equal :answer, result.attachment.fetch(:purpose)
    assert_equal "voice-answer", result.attachment.fetch(:file_id)
    assert_equal 2345, result.attachment.fetch(:file_size)
  end

  def test_voice_reply_can_reattach_to_slug_after_restart
    result = @router.handle(
      update(
        reply_to_text: "hive/slug-260514-abcd (2-brainstorm)",
        voice: { file_id: "voice-answer", file_size: 2345 }
      )
    )

    assert_equal :transcribe_voice, result.action
    assert_equal "hive", result.project
    assert_equal "slug-260514-abcd", result.slug
    assert_nil result.question_n
    assert_equal :path_b, result.mode
    assert_equal :answer, result.attachment.fetch(:purpose)
  end

  def test_voice_reply_can_reattach_to_legacy_answer_mode_prompt
    result = @router.handle(
      update(
        reply_to_text: "Answer mode started for slug-260514-abcd.",
        voice: { file_id: "voice-answer", file_size: 2345 }
      )
    )

    assert_equal :transcribe_voice, result.action
    assert_nil result.project
    assert_equal "slug-260514-abcd", result.slug
    assert_equal :answer, result.attachment.fetch(:purpose)
  end

  def test_unmatched_voice_reply_remains_a_new_voice_idea
    result = @router.handle(
      update(
        reply_to_text: "plain old message",
        voice: { file_id: "voice-idea", file_size: 2345 }
      )
    )

    assert_equal :transcribe_voice, result.action
    assert_nil result.slug
    assert_nil result.attachment[:purpose]
  end

  def test_free_text_inside_path_a_conversation_writes_answer_deterministically
    # The Codex draft flow was removed: a path_a conversation now writes the
    # answer directly, just like path_b, instead of spawning Codex.
    @store.start(chat_id: 12345, project: "hive", slug: "slug-260514-abcd",
                 question_n: 1, mode: :path_a)

    result = @router.handle(update(text: "clarifying answer"))

    assert_equal :write_answer_then_reply, result.action
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

  def test_answer_voice_without_context_hints_id_or_slug
    # The classifier only routes :answer_voice when answer_context is present,
    # so the defensive no-context branch is unreachable via classify. Drive it
    # directly to pin the operator hint copy: a silent revert to the old
    # `<slug>`-only phrasing must fail here.
    result = @router.send(:answer_voice, update(voice: { file_id: "voice", file_size: 1 }))

    assert_equal :reply, result.action
    assert_match(%r{/answer <id\|slug>}, result.text)
  end

  def test_slash_answer_returns_start_answer_action_not_immediate_start
    result = @router.handle(update(text: "/answer slug-260514-abcd"))

    assert_equal :start_answer, result.action
    assert_equal "slug-260514-abcd", result.slug
    assert_equal :path_b, result.mode
  end

  def test_free_text_outside_conversation_defaults_to_idea_capture
    result = @router.handle(update(text: "hello"))

    assert_equal :reply, result.action
    assert_match(/Pick a project/, result.text)
    assert_equal "hello", @draft_store.get(chat_id: 12345).text
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

  def test_bare_text_without_registered_projects_replies_gracefully
    with_tmp_global_config do
      router = Hive::Bot::Router.new(
        bot_config: { "chat_id_allowlist" => [ 12345 ] },
        logger: @logger,
        conversation_store: @store,
        idea_draft_store: @draft_store
      )

      result = router.handle(update(text: "fix broken cron"))

      assert_equal :reply, result.action
      assert_match(/No Hive projects are registered yet/, result.text)
      assert_nil @draft_store.get(chat_id: 12345),
                 "the empty-registry refusal must not leave a draft behind (start_idea checks the registry before opening a draft)"
    end
  end

  def test_blank_bare_text_without_registered_projects_still_opens_text_capture
    # Divergence from the content-bearing case above: a content-less / blank
    # update routes to :idea_bare_text -> SlashHandlers#idea -> start_text_capture,
    # which opens an awaiting_text draft WITHOUT consulting the registry. So
    # even with no projects registered it replies "Send the idea text" and
    # leaves a draft, rather than refusing with "No Hive projects are
    # registered yet" and leaving nothing behind.
    with_tmp_global_config do
      router = Hive::Bot::Router.new(
        bot_config: { "chat_id_allowlist" => [ 12345 ] },
        logger: @logger,
        conversation_store: @store,
        idea_draft_store: @draft_store
      )

      result = router.handle(update(text: "   "))

      assert_equal :reply, result.action
      assert_match(/Send the idea text/, result.text)
      refute_match(/No Hive projects are registered/, result.text)
      draft = @draft_store.get(chat_id: 12345)
      assert_equal :awaiting_text, draft.phase
      assert_nil draft.text
    end
  end

  def test_classifies_all_callback_prefixes
    cases = {
      "reject:anything" => :callback_reject,
      "approve_plan:hive:slug-260514-abcd:3-plan" => :callback_approve_plan,
      "rerun:hive:slug-260514-abcd:4-execute:develop" => :callback_rerun,
      "autofix:hive:slug-260514-abcd:6-review:REVIEW_ERROR" => :callback_autofix,
      "open_laptop:hive:slug-260514-abcd" => :callback_open_laptop,
      "details:hive:slug-260514-abcd" => :callback_show_details,
      "refresh_diagnose:hive:slug-260514-abcd:6-review" => :callback_refresh_diagnose,
      "answer:hive:slug-260514-abcd" => :callback_answer,
      "idea_voice_confirm:token" => :callback_idea_voice_confirm,
      "idea_voice_discard:token" => :callback_idea_voice_discard,
      "idea_done:token" => :callback_idea_done,
      "idea_skip:token" => :callback_idea_skip,
      "path_a_yes:hive:slug-260514-abcd" => :callback_path_a_yes,
      "path_a_type:hive:slug-260514-abcd" => :callback_path_a_just_type,
      "findings:accept_all:hive:slug-260514-abcd:6-review" => :callback_findings_accept_all,
      "findings:reject_all:hive:slug-260514-abcd:6-review" => :callback_findings_reject_all,
      "idea_project_new:token" => :callback_idea_project_new,
      # Retired Codex draft-assist callbacks no longer parse to an intent.
      "codex_write:hive:slug-260514-abcd:1" => :unknown,
      "codex_edit:hive:slug-260514-abcd:1" => :unknown,
      "codex_cancel:hive:slug-260514-abcd:1" => :unknown,
      "unknown:hive:slug-260514-abcd" => :unknown
    }

    cases.each do |callback_data, intent|
      assert_equal intent, @router.classify(update(callback_data: callback_data)), callback_data
    end
  end

  def test_unresolved_compacted_callback_classifies_as_expired_button
    # A `#`-prefixed compacted token whose registry entry is gone (bot
    # restart, or TTL/size eviction) survives resolve_callback unchanged and
    # must route to the actionable "button expired" reply rather than the
    # generic "I did not understand that".
    expired = "#approve_plan:deadbeefdeadbeef"
    assert_equal :callback_expired, @router.classify(update(callback_data: expired))

    result = @router.handle(update(callback_data: expired))
    assert_equal :reply, result.action
    assert_match(/button expired/i, result.text)
    assert_match(%r{/queue}, result.text)
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
    assert_includes result.text, "/approve <id|slug>"
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

  def test_legacy_message_update_without_effective_text_defaults_to_idea_capture
    result = @router.handle(LegacyMessageUpdate.new(update_id: 1, chat_id: 12345, text: "hello"))

    assert_equal :reply, result.action
    assert_match(/Pick a project/, result.text)
    assert_equal "hello", @draft_store.get(chat_id: 12345).text
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
