require "test_helper"
require "hive/bot/supervisor"
require "hive/commands/init"

class HiveBotSupervisorTest < Minitest::Test
  include HiveTestHelper

  ChildExit = Hive::Bot::ChildSupervisor::ChildExit
  Update = Struct.new(:chat_id, :update_id, :message_id, keyword_init: true)
  Row = Struct.new(:project, :slug, :stage, :action, :action_label, :marker, :attrs, :diagnostic,
                   keyword_init: true)
  StatusResult = Struct.new(:ok, :rows, :legacy_stage_dirs, :error, :envelope, keyword_init: true)

  FakeTelegram = Struct.new(:messages, :raise_on_send, :keyboard_clears,
                            :commands_registered, :raise_on_set_my_commands, keyword_init: true) do
    def send_message(chat_id:, text:, reply_markup: nil)
      raise raise_on_send if raise_on_send

      messages << { chat_id: chat_id, text: text, reply_markup: reply_markup }
    end

    def edit_message_reply_markup(chat_id:, message_id:, reply_markup: nil)
      (self.keyboard_clears ||= []) << { chat_id: chat_id, message_id: message_id, reply_markup: reply_markup }
    end

    def set_my_commands(commands:)
      raise raise_on_set_my_commands if raise_on_set_my_commands

      (self.commands_registered ||= []) << commands
    end
  end

  FakeLogger = Struct.new(:events, keyword_init: true) do
    def event(name, **payload)
      events << { name: name, payload: payload }
    end

    def close; end
  end

  FakeStatusWatcher = Struct.new(:result, :fetch_count, keyword_init: true) do
    def fetch
      self.fetch_count = (fetch_count || 0) + 1
      result
    end
  end


  FakeNotificationDispatcher = Struct.new(:processed, :reset_tasks, keyword_init: true) do
    def process_rows(rows)
      processed << rows
    end

    def reset_task(**kwargs)
      reset_tasks << kwargs
    end
  end

  class FakeRouter
    Result = Struct.new(:action, :text, :reply_markup, :command_argv, :commands, :project, :slug,
                        :question_n, :answer_text, :mode, :alert_reset, :clear_keyboard, :format,
                        :intent, :attachment,
                        keyword_init: true)
  end

  FakeChildSupervisor = Struct.new(:dispatch_pid, :dispatched, :completed, :reap_batches, keyword_init: true) do
    def dispatch(**kwargs)
      dispatched << kwargs
      dispatch_pid
    end

    def completed_exit(pid)
      completed[pid]
    end

    def reap_all
      reap_batches.shift || []
    end
  end

  TranscriptionResult = Struct.new(:status, :text, :language, :error_class, :message, keyword_init: true)
  FakeTranscriber = Struct.new(:results, :calls, keyword_init: true) do
    def call(bytes, filename:, content_type:)
      calls << { bytes: bytes, filename: filename, content_type: content_type }
      results.shift
    end
  end

  # Captures every dispatch-request write so tests can assert that the
  # queue-routable bot verbs (run/develop/brainstorm/plan/review/
  # open-pr/artifacts/finalize/archive/markers) no longer spawn — they
  # land here instead. `write!` returns a request_id so the supervisor's
  # logging path that includes it stays exercised.
  FakeDispatchRequestWriter = Struct.new(:writes, :sequences, :discarded_sequences,
                                         :next_request_id, :raise_on_write,
                                         :raise_on_sequence, :raise_on_discard,
                                         keyword_init: true) do
    def generate_request_id
      next_request_id || "req-#{writes.length + 1}"
    end

    def write!(project:, slug:, argv:, chat_id: nil, update_id: nil, trigger: nil, request_id: nil)
      raise raise_on_write if raise_on_write

      id = request_id || generate_request_id
      writes << {
        project: project, slug: slug, argv: argv, chat_id: chat_id,
        update_id: update_id, trigger: trigger, request_id: id
      }
      id
    end

    def write_sequence!(request_id:, remaining_argvs:)
      raise raise_on_sequence if raise_on_sequence

      (self.sequences ||= []) << { request_id: request_id, remaining_argvs: remaining_argvs }
      true
    end

    def discard_sequence!(request_id:)
      raise raise_on_discard if raise_on_discard

      (self.discarded_sequences ||= []) << request_id
      true
    end
  end

  FakeConversationStore = Struct.new(:starts, :updates, :states, :ttl_updates, keyword_init: true) do
    def start(**kwargs)
      starts << kwargs
      state = Struct.new(:question_n, :mode, :project, :draft, :history, :awaiting_confirm, keyword_init: true).new(
        question_n: kwargs[:question_n], mode: kwargs[:mode], project: kwargs[:project], history: []
      )
      states[[ kwargs[:chat_id], kwargs[:slug] ]] = state
      state
    end

    def get(chat_id:, slug:)
      states[[ chat_id, slug ]]
    end

    def update(chat_id:, slug:, **kwargs)
      updates << { chat_id: chat_id, slug: slug, values: kwargs }
      state = states[[ chat_id, slug ]] || start(
        chat_id: chat_id, slug: slug, question_n: kwargs[:question_n], mode: kwargs[:mode]
      )
      kwargs.each { |key, value| state.public_send("#{key}=", value) if state.respond_to?("#{key}=") }
      state
    end

    def update_ttl(ttl)
      ttl_updates << ttl
    end

    def clear(chat_id:, slug: nil)
      if slug
        states.delete([ chat_id, slug ])
      else
        states.delete_if { |key, _| key.first == chat_id }
      end
    end

    def pending_confirm_count(chat_id:)
      states.count { |key, state| key.first == chat_id && state.respond_to?(:awaiting_confirm) && state.awaiting_confirm }
    end
  end

  def setup
    @telegram = FakeTelegram.new(messages: [])
    @logger = FakeLogger.new(events: [])
    @status_watcher = FakeStatusWatcher.new(result: StatusResult.new(ok: true, rows: []))
    @child_supervisor = FakeChildSupervisor.new(dispatch_pid: 123, dispatched: [], completed: {}, reap_batches: [])
    @conversation_store = FakeConversationStore.new(starts: [], updates: [], states: {}, ttl_updates: [])
    @idea_draft_store = Hive::Bot::IdeaDraftStore.new
    @transcriber = FakeTranscriber.new(results: [], calls: [])
    @notification_dispatcher = FakeNotificationDispatcher.new(processed: [], reset_tasks: [])
    @dispatch_request_writer = FakeDispatchRequestWriter.new(writes: [], sequences: [], discarded_sequences: [])
    # Drive the real constructor so any future invariant added to
    # Supervisor#initialize is exercised by every test in this file. We
    # inject all collaborators so the constructor's `||=` defaults never
    # touch disk or the network.
    @config = {
      "chat_id_allowlist" => [ 42, 43 ],
      "clear_retry_grace_sec" => 1,
      "conversation_ttl_sec" => 60,
      "poll_interval_sec" => 1,
      "idea_attachment_max_bytes" => 20 * 1024 * 1024,
      "idea_attachment_max_count" => 10,
      "idea_draft_ttl_sec" => 900,
      "transcription" => { "enabled" => true }
    }
    @supervisor = Hive::Bot::Supervisor.new(
      config: @config,
      token: "test-token",
      logger: @logger,
      telegram: @telegram,
      status_watcher: @status_watcher,
      notification_dispatcher: @notification_dispatcher,
      router: FakeRouter.new,
      child_supervisor: @child_supervisor,
      conversation_store: @conversation_store,
      idea_draft_store: @idea_draft_store,
      transcriber: @transcriber,
      dry_run: false,
      dispatch_request_writer: @dispatch_request_writer
    )
  end

  def child_exit(exit_code: 0, envelope: nil, log_path: "/tmp/hive-bot.log", pid: 123,
                 project: "hive",
                 command_argv: [ "hive", "status", "--diagnose", "red-task-260518-aaaa", "--json" ])
    ChildExit.new(
      pid: pid,
      exit_code: exit_code,
      project: project,
      slug: "red-task-260518-aaaa",
      command_argv: command_argv,
      chat_id: 42,
      update_id: 99,
      started_at: Time.now,
      finished_at: Time.now,
      log_path: log_path,
      json_envelope: envelope
    )
  end

  def legacy_stage_dirs(project: "hive", project_path: "/tmp/hive")
    Hive::Bot::StatusWatcher::LegacyStageDirs.new(
      project: project,
      project_path: project_path,
      hive_state_path: File.join(project_path, ".hive-state"),
      legacy_stage_dirs: [ { "stage_dir" => "6-pr", "task_count" => 1 } ],
      legacy_migrate_command: "hive migrate"
    )
  end

  def row(project: "hive", slug: "task", stage: "3-plan", action: "ready_to_develop",
          action_label: "Develop", marker: "COMPLETE", attrs: {}, diagnostic: nil)
    Row.new(project: project, slug: slug, stage: stage, action: action,
            action_label: action_label, marker: marker, attrs: attrs, diagnostic: diagnostic)
  end


  def with_brainstorm_file(slug: "bot-task-260522-aa", content:)
    with_tmp_dir do |dir|
      project = File.join(dir, "project")
      folder = File.join(project, ".hive-state", "stages", "2-brainstorm", slug)
      FileUtils.mkdir_p(folder)
      path = File.join(folder, "brainstorm.md")
      File.write(path, content)
      yield path, project
    end
  end

  Outcome = Struct.new(:kind, :draft, :text, :reason, keyword_init: true)

  FakeCodexConversation = Struct.new(:outcome, :calls, keyword_init: true) do
    def next_turn(**kwargs)
      calls << kwargs
      outcome
    end
  end

  def test_status_tick_includes_legacy_stage_dirs_in_notification_inputs
    legacy = legacy_stage_dirs
    @status_watcher.result = StatusResult.new(ok: true, rows: [], legacy_stage_dirs: [ legacy ])

    @supervisor.status_tick

    assert_equal [ [ legacy ] ], @notification_dispatcher.processed
  end

  def test_reply_for_child_renders_status_diagnose_success_envelope
    envelope = {
      "schema" => "hive-status-diagnose",
      "ok" => true,
      "slug" => "red-task-260518-aaaa",
      "diagnostic" => {
        "summary" => "REVIEW_ERROR phase=fix pass=1",
        "detail" => "fix attempt timed out"
      },
      "path" => "/tmp/red-status.md"
    }

    @supervisor.send(:reply_for_child, child_exit(envelope: envelope))

    text = @telegram.messages.first.fetch(:text)
    assert_equal 'Diagnosis is available for "Red task…". Tap Show details to dump it here.', text
    refute_includes text, "REVIEW_ERROR"
    refute_includes text, "fix attempt timed out"
    refute_includes text, "/tmp/red-status.md"
    refute_includes text, "Command completed"
  end

  def test_reply_for_child_renders_status_diagnose_error_envelope
    envelope = {
      "schema" => "hive-status-diagnose",
      "ok" => false,
      "error_kind" => "ambiguous_slug",
      "exit_code" => Hive::ExitCodes::USAGE,
      "message" => "slug matches multiple stages"
    }

    @supervisor.send(:reply_for_child, child_exit(exit_code: Hive::ExitCodes::USAGE, envelope: envelope))

    text = @telegram.messages.first.fetch(:text)
    assert_includes text, "Diagnosis failed (ambiguous_slug): slug matches multiple stages"
    assert_includes text, "/tmp/hive-bot.log"
  end

  def test_reply_for_child_renders_empty_success_diagnostic_fallback
    envelope = { "schema" => "hive-status-diagnose", "ok" => true, "slug" => "stuck-task" }

    @supervisor.send(:reply_for_child, child_exit(envelope: envelope))

    assert_equal "No diagnostic available for stuck-task.", @telegram.messages.first.fetch(:text)
  end

  CallbackUpdate = Struct.new(:callback_query_id, :update_id, keyword_init: true) do
    def callback_query?; !callback_query_id.nil?; end
    def callback_data; "approve:plan:hive:slug:2-brainstorm"; end
  end

  def test_ack_callback_query_calls_telegram_with_callback_query_id
    captured = []
    @telegram.define_singleton_method(:answer_callback_query) do |callback_query_id:|
      captured << callback_query_id
    end

    @supervisor.send(:ack_callback_query, CallbackUpdate.new(callback_query_id: "cbq-99"))

    assert_equal [ "cbq-99" ], captured
  end

  def test_ack_callback_query_skips_when_callback_query_id_missing
    called = false
    @telegram.define_singleton_method(:answer_callback_query) do |callback_query_id:|
      called = true
    end

    @supervisor.send(:ack_callback_query, CallbackUpdate.new(callback_query_id: nil))

    refute called, "ack_callback_query must short-circuit when callback_query_id is nil"
  end

  def test_ack_callback_query_logs_send_failure_on_telegram_exception
    @telegram.define_singleton_method(:answer_callback_query) do |callback_query_id:|
      raise StandardError, "telegram down"
    end

    @supervisor.send(:ack_callback_query, CallbackUpdate.new(callback_query_id: "cbq-7"))

    failure = @logger.events.find { |e| e[:name] == :send_failure }
    refute_nil failure
    assert_equal "answer_callback_query", failure.fetch(:payload).fetch(:source)
    assert_equal "cbq-7", failure.fetch(:payload).fetch(:callback_query_id)
  end

  def test_stage_attachment_downloads_and_appends_to_draft
    @idea_draft_store.start(chat_id: 42, phase: :collecting_files, text: "fix", token: "tok")
    get_file_ids = []
    download_paths = []
    @telegram.define_singleton_method(:get_file) do |file_id:|
      get_file_ids << file_id
      { file_path: "photos/file.jpg", file_size: 5 }
    end
    @telegram.define_singleton_method(:download_file) do |file_path:|
      download_paths << file_path
      "bytes".b
    end
    result = FakeRouter::Result.new(
      action: :stage_attachment,
      text: "Attached.",
      attachment: { chat_id: 42, file_id: "photo-id", file_size: 5, ext: "jpg" }
    )

    @supervisor.send(:execute_result, result, Update.new(chat_id: 42, update_id: 1))

    assert_equal [ "photo-id" ], get_file_ids
    assert_equal [ "photos/file.jpg" ], download_paths
    draft = @idea_draft_store.get(chat_id: 42)
    assert_equal 1, draft.attachments.size
    attachment = draft.attachments.first
    assert_equal "image1", attachment.fetch(:label)
    assert_equal "bug-1.jpg", attachment.fetch(:dest_name)
    assert_equal "bytes", File.binread(attachment.fetch(:staging_path))
    assert_equal "Attached.", @telegram.messages.last.fetch(:text)
  ensure
    @idea_draft_store.clear(chat_id: 42) if @idea_draft_store
  end

  def test_stage_attachment_download_failure_preserves_draft
    @idea_draft_store.start(chat_id: 42, phase: :collecting_files, text: "fix", token: "tok")
    @telegram.define_singleton_method(:get_file) { |file_id:| { file_path: "photos/file.jpg", file_size: 5 } }
    @telegram.define_singleton_method(:download_file) do |file_path:|
      raise Hive::Bot::Telegram::DownloadError, "offline"
    end
    result = FakeRouter::Result.new(
      action: :stage_attachment,
      attachment: { chat_id: 42, file_id: "photo-id", file_size: 5, ext: "jpg" }
    )

    @supervisor.send(:execute_result, result, Update.new(chat_id: 42, update_id: 1))

    assert_equal [], @idea_draft_store.get(chat_id: 42).attachments
    assert_match(/please send it again/, @telegram.messages.last.fetch(:text))
  end

  def test_stage_attachment_replies_when_draft_expired_before_download
    result = FakeRouter::Result.new(
      action: :stage_attachment,
      attachment: { chat_id: 42, file_id: "photo-id", file_size: 5, ext: "jpg" }
    )

    @supervisor.send(:execute_result, result, Update.new(chat_id: 42, update_id: 1))

    assert_match(/draft expired/, @telegram.messages.last.fetch(:text))
  end

  def test_stage_attachment_rechecks_remote_size_before_download
    @idea_draft_store.start(chat_id: 42, phase: :collecting_files, text: "fix", token: "tok")
    downloaded = false
    @telegram.define_singleton_method(:get_file) { |file_id:| { file_path: "photos/file.jpg", file_size: 25 * 1024 * 1024 } }
    @telegram.define_singleton_method(:download_file) { |file_path:| downloaded = true }
    result = FakeRouter::Result.new(
      action: :stage_attachment,
      attachment: { chat_id: 42, file_id: "photo-id", file_size: 5, ext: "jpg" }
    )

    @supervisor.send(:execute_result, result, Update.new(chat_id: 42, update_id: 1))

    refute downloaded
    assert_match(/too large/, @telegram.messages.last.fetch(:text))
  ensure
    @idea_draft_store.clear(chat_id: 42) if @idea_draft_store
  end

  def test_transcribe_voice_sets_transcript_and_discards_audio
    @transcriber.results << TranscriptionResult.new(status: :ok, text: "voice idea", language: "en")
    @telegram.define_singleton_method(:get_file) { |file_id:| { file_path: "voice/file.oga", file_size: 5 } }
    @telegram.define_singleton_method(:download_file) { |file_path:| "audio-bytes".b }
    result = FakeRouter::Result.new(
      action: :transcribe_voice,
      attachment: { chat_id: 42, file_id: "voice-id", file_size: 5 }
    )

    @supervisor.send(:execute_result, result, Update.new(chat_id: 42, update_id: 1))

    assert_equal [ { bytes: "audio-bytes", filename: "voice.oga", content_type: "audio/ogg" } ], @transcriber.calls
    draft = @idea_draft_store.get(chat_id: 42)
    assert_equal :voice, draft.origin
    assert_equal :awaiting_transcript_confirm, draft.phase
    assert_equal "voice idea", draft.text
    assert_empty draft.attachments
    assert_match(/Transcript:\n\nvoice idea/, @telegram.messages.last.fetch(:text))
    assert_equal "Confirm", @telegram.messages.last.fetch(:reply_markup).first.first[:text]
  end

  def test_transcribe_voice_edit_replaces_existing_transcript
    @idea_draft_store.start(chat_id: 42, phase: :awaiting_transcript_confirm,
                            text: "old", token: "tok", origin: :voice)
    @transcriber.results << TranscriptionResult.new(status: :ok, text: "new transcript", language: "en")
    @telegram.define_singleton_method(:get_file) { |file_id:| { file_path: "voice/file.oga", file_size: 5 } }
    @telegram.define_singleton_method(:download_file) { |file_path:| "audio-bytes".b }
    result = FakeRouter::Result.new(
      action: :transcribe_voice,
      attachment: { chat_id: 42, file_id: "voice-id", file_size: 5 }
    )

    @supervisor.send(:execute_result, result, Update.new(chat_id: 42, update_id: 1))

    draft = @idea_draft_store.get(chat_id: 42)
    assert_equal "tok", draft.token
    assert_equal "new transcript", draft.text
    assert_match(/new transcript/, @telegram.messages.last.fetch(:text))
  end

  def test_transcribe_voice_during_non_voice_draft_does_not_clear_or_download
    @idea_draft_store.start(chat_id: 42, phase: :collecting_files, text: "typed idea", token: "tok")
    get_file_called = false
    @telegram.define_singleton_method(:get_file) do |file_id:|
      get_file_called = true
      { file_path: "voice/file.oga", file_size: 5 }
    end
    result = FakeRouter::Result.new(
      action: :transcribe_voice,
      attachment: { chat_id: 42, file_id: "voice-id", file_size: 5 }
    )

    @supervisor.send(:execute_result, result, Update.new(chat_id: 42, update_id: 1))

    refute get_file_called
    assert_empty @transcriber.calls
    draft = @idea_draft_store.get(chat_id: 42)
    assert_equal :collecting_files, draft.phase
    assert_equal "typed idea", draft.text
    assert_equal "tok", draft.token
    assert_match(/Finish or discard the current idea draft/, @telegram.messages.last.fetch(:text))
  end

  def test_transcribe_voice_no_speech_clears_draft
    @idea_draft_store.start(chat_id: 42, phase: :awaiting_transcript_confirm,
                            text: "old", token: "tok", origin: :voice)
    @transcriber.results << TranscriptionResult.new(status: :no_speech)
    @telegram.define_singleton_method(:get_file) { |file_id:| { file_path: "voice/file.oga", file_size: 5 } }
    @telegram.define_singleton_method(:download_file) { |file_path:| "audio-bytes".b }

    @supervisor.send(:execute_result,
                     FakeRouter::Result.new(action: :transcribe_voice,
                                            attachment: { chat_id: 42, file_id: "voice-id" }),
                     Update.new(chat_id: 42, update_id: 1))

    assert_nil @idea_draft_store.get(chat_id: 42)
    assert_match(/couldn't hear any speech/, @telegram.messages.last.fetch(:text))
  end

  def test_transcribe_voice_unsupported_language_clears_draft
    @idea_draft_store.start(chat_id: 42, phase: :awaiting_transcript_confirm,
                            text: "old", token: "tok", origin: :voice)
    @transcriber.results << TranscriptionResult.new(status: :unsupported_language, language: "de")
    @telegram.define_singleton_method(:get_file) { |file_id:| { file_path: "voice/file.oga", file_size: 5 } }
    @telegram.define_singleton_method(:download_file) { |file_path:| "audio-bytes".b }

    @supervisor.send(:execute_result,
                     FakeRouter::Result.new(action: :transcribe_voice,
                                            attachment: { chat_id: 42, file_id: "voice-id" }),
                     Update.new(chat_id: 42, update_id: 1))

    assert_nil @idea_draft_store.get(chat_id: 42)
    assert_match(/unsupported language/, @telegram.messages.last.fetch(:text))
  end

  def test_transcribe_voice_failed_stages_audio_and_awaits_text
    @transcriber.results << TranscriptionResult.new(status: :failed)
    @telegram.define_singleton_method(:get_file) { |file_id:| { file_path: "voice/file.oga", file_size: 5 } }
    @telegram.define_singleton_method(:download_file) { |file_path:| "audio-bytes".b }

    @supervisor.send(:execute_result,
                     FakeRouter::Result.new(action: :transcribe_voice,
                                            attachment: { chat_id: 42, file_id: "voice-id" }),
                     Update.new(chat_id: 42, update_id: 1))

    draft = @idea_draft_store.get(chat_id: 42)
    assert_equal :awaiting_text, draft.phase
    assert_nil draft.text
    assert_equal 1, draft.attachments.size
    attachment = draft.attachments.first
    assert_equal "voice-1.oga", attachment.fetch(:dest_name)
    assert_equal "oga", attachment.fetch(:ext)
    assert_equal "audio-bytes", File.binread(attachment.fetch(:staging_path))
    assert_match(/saved the audio/, @telegram.messages.last.fetch(:text))
  ensure
    @idea_draft_store.clear(chat_id: 42) if @idea_draft_store
  end

  def test_transcribe_voice_rechecks_remote_size_before_download
    downloaded = false
    @telegram.define_singleton_method(:get_file) { |file_id:| { file_path: "voice/file.oga", file_size: 25 * 1024 * 1024 } }
    @telegram.define_singleton_method(:download_file) { |file_path:| downloaded = true }

    @supervisor.send(:execute_result,
                     FakeRouter::Result.new(action: :transcribe_voice,
                                            attachment: { chat_id: 42, file_id: "voice-id" }),
                     Update.new(chat_id: 42, update_id: 1))

    refute downloaded
    assert_match(/voice note is too large/, @telegram.messages.last.fetch(:text))
    assert_nil @idea_draft_store.get(chat_id: 42)
  end

  def test_transcribe_voice_disabled_replies_without_transcribing
    disabled = Hive::Bot::Supervisor.new(
      config: @config.merge("transcription" => { "enabled" => false }),
      token: "test-token",
      logger: @logger,
      telegram: @telegram,
      status_watcher: @status_watcher,
      notification_dispatcher: @notification_dispatcher,
      router: FakeRouter.new,
      child_supervisor: @child_supervisor,
      conversation_store: @conversation_store,
      idea_draft_store: @idea_draft_store,
      transcriber: @transcriber,
      dry_run: false,
      dispatch_request_writer: @dispatch_request_writer
    )
    get_file_called = false
    @telegram.define_singleton_method(:get_file) do |file_id:|
      get_file_called = true
      { file_path: "voice/file.oga", file_size: 1 }
    end

    disabled.send(:execute_result,
                  FakeRouter::Result.new(action: :transcribe_voice,
                                         attachment: { chat_id: 42, file_id: "voice-id" }),
                  Update.new(chat_id: 42, update_id: 1))

    refute get_file_called, "disabled transcription must not reach getFile"
    assert_empty @transcriber.calls, "disabled transcription must not call the transcriber"
    assert_match(/transcription is disabled/, @telegram.messages.last.fetch(:text))
  end

  def test_commit_voice_idea_uses_transcript_without_assets
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        project = File.basename(dir)
        @idea_draft_store.start(chat_id: 42, phase: :awaiting_project,
                                text: "voice transcript", token: "tok", origin: :voice)
        @idea_draft_store.set_project(chat_id: 42, project: project)

        @supervisor.send(:execute_result,
                         FakeRouter::Result.new(action: :commit_idea, attachment: { chat_id: 42 }),
                         Update.new(chat_id: 42, update_id: 1))

        inbox = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "voice-transcript-*")]
        assert_equal 1, inbox.size
        idea = File.read(File.join(inbox.first, "idea.md"))
        assert_includes idea, "voice transcript"
        refute_path_exists File.join(inbox.first, "assets")
        assert_nil @idea_draft_store.get(chat_id: 42)
      end
    end
  end

  def test_commit_idea_uses_commands_new_with_attachments_and_cleans_draft
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        project = File.basename(dir)
        @idea_draft_store.start(chat_id: 42, phase: :collecting_files, text: "fix login", token: "tok")
        @idea_draft_store.set_project(chat_id: 42, project: project)
        staging_dir = @idea_draft_store.ensure_staging_dir(chat_id: 42)
        staging_path = File.join(staging_dir, "image-1.jpg")
        File.binwrite(staging_path, "image-bytes")
        @idea_draft_store.append_attachment(
          chat_id: 42,
          label: "image1",
          dest_name: "bug-1.jpg",
          staging_path: staging_path,
          ext: "jpg"
        )

        @supervisor.send(:execute_result,
                         FakeRouter::Result.new(action: :commit_idea, attachment: { chat_id: 42 }),
                         Update.new(chat_id: 42, update_id: 1))

        inbox = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "fix-login-*")]
        assert_equal 1, inbox.size
        assert_includes File.read(File.join(inbox.first, "idea.md")), "![](assets/bug-1.jpg)"
        assert_equal "image-bytes", File.binread(File.join(inbox.first, "assets", "bug-1.jpg"))
        assert_nil @idea_draft_store.get(chat_id: 42)
        refute_path_exists staging_dir
        assert_match(/Captured your idea/, @telegram.messages.last.fetch(:text))
      end
    end
  end

  def test_commit_idea_replies_for_missing_project_and_missing_text
    @idea_draft_store.start(chat_id: 42, phase: :collecting_files, text: "fix", token: "tok")

    @supervisor.send(:execute_result,
                     FakeRouter::Result.new(action: :commit_idea, attachment: { chat_id: 42 }),
                     Update.new(chat_id: 42, update_id: 1))
    assert_match(/Pick a project/, @telegram.messages.last.fetch(:text))

    @idea_draft_store.set_project(chat_id: 42, project: "hive")
    @idea_draft_store.set_text(chat_id: 42, text: " ")

    @supervisor.send(:execute_result,
                     FakeRouter::Result.new(action: :commit_idea, attachment: { chat_id: 42 }),
                     Update.new(chat_id: 42, update_id: 2))
    assert_match(/Send the idea text/, @telegram.messages.last.fetch(:text))
  ensure
    @idea_draft_store.clear(chat_id: 42) if @idea_draft_store
  end

  def test_commit_idea_handles_command_failure_without_clearing_draft
    @idea_draft_store.start(chat_id: 42, phase: :collecting_files, text: "fix", token: "tok")
    @idea_draft_store.set_project(chat_id: 42, project: "missing-project")

    @supervisor.send(:execute_result,
                     FakeRouter::Result.new(action: :commit_idea, attachment: { chat_id: 42 }),
                     Update.new(chat_id: 42, update_id: 1))

    refute_nil @idea_draft_store.get(chat_id: 42)
    assert_match(/Couldn't capture that idea/, @telegram.messages.last.fetch(:text))
    event = @logger.events.find { |entry| entry.fetch(:name) == :send_failure }
    assert_equal "commit_idea", event.fetch(:payload).fetch(:source)
  ensure
    @idea_draft_store.clear(chat_id: 42) if @idea_draft_store
  end

  def test_idea_body_override_renders_documents_as_links
    draft = Struct.new(:text, :attachments).new(
      "fix docs",
      [
        { ext: "jpg", dest_name: "bug-1.jpg" },
        { ext: "pdf", dest_name: "bug-2.pdf" }
      ]
    )

    body = @supervisor.send(:idea_body_override, draft)

    assert_includes body, "![](assets/bug-1.jpg)"
    assert_includes body, "[bug-2.pdf](assets/bug-2.pdf)"
  end

  def test_latest_status_rows_returns_cached_rows_when_status_tick_already_ran
    cached = [ row(slug: "cached-260526-aaaa") ]
    @supervisor.instance_variable_set(:@latest_status_rows, cached)

    assert_same cached, @supervisor.send(:latest_status_rows),
                "cache hit must NOT trigger a fresh @status_watcher.fetch subprocess"
  end

  def test_latest_status_rows_returns_nil_when_cold_without_blocking_on_a_fetch
    # Regression guard for the double-dispatch risk: latest_status_rows must
    # NOT shell out to @status_watcher.fetch on the (poll) thread that calls
    # it. A hung `hive status` there would stall the long-poll loop, after
    # which Telegram redelivers the un-acked update and /autofix double-fires.
    @status_watcher.result = StatusResult.new(ok: true, rows: [ row(slug: "fresh-260526-bbbb") ])
    @status_watcher.fetch_count = 0
    @supervisor.instance_variable_set(:@latest_status_rows, nil)

    assert_nil @supervisor.send(:latest_status_rows),
               "cold cache must return nil (status_loop populates it), not sync-fetch"
    assert_equal 0, @status_watcher.fetch_count,
                 "latest_status_rows must never call @status_watcher.fetch on the caller thread"
  end

  def test_status_tick_does_not_poison_cache_on_failed_fetch
    # status_tick only assigns @latest_status_rows on a successful fetch, so a
    # transient failure cannot leave a stale/empty snapshot poisoning the
    # cache (the slash handlers would otherwise reply "slug not found" for
    # every slug until the next successful tick).
    good = [ row(slug: "good-260526-aaaa") ]
    @status_watcher.result = StatusResult.new(ok: true, rows: good)
    @supervisor.status_tick
    assert_equal good, @supervisor.send(:latest_status_rows)

    @status_watcher.result = StatusResult.new(ok: false, rows: nil, error: "boom")
    @supervisor.status_tick

    assert_equal good, @supervisor.send(:latest_status_rows),
                 "a failed tick must leave the last good snapshot intact, not overwrite it"
  end

  def test_reload_rewires_status_snapshot_provider_into_the_rebuilt_router
    # Regression guard: reload_config_if_requested rebuilds @router, and that
    # rebuild must keep the status_snapshot_provider wiring. The original bug
    # rebuilt the Router without it, so after any `hive bot reload` /autofix
    # and /details replied "Slug not found" for every slug until restart.
    retryable = row(slug: "stuck-260526-cccc", stage: "6-review", action: "recover_review",
                    marker: "review_error", attrs: { "pass" => "2" },
                    diagnostic: { "suggested_next_action" => { "kind" => "retry" } })
    supervisor = Hive::Bot::Supervisor.new(
      config: @config, token: "test-token", logger: @logger, telegram: @telegram,
      status_watcher: @status_watcher, notification_dispatcher: @notification_dispatcher,
      router: nil, child_supervisor: @child_supervisor,
      conversation_store: @conversation_store, dry_run: false,
      dispatch_request_writer: @dispatch_request_writer
    )
    supervisor.instance_variable_set(:@latest_status_rows, [ retryable ])
    supervisor.instance_variable_set(:@reload, true)
    cfg = @config
    original = Hive::Config.method(:load_global_bot)
    Hive::Config.define_singleton_method(:load_global_bot) { |**| cfg }
    begin
      supervisor.send(:reload_config_if_requested)
    ensure
      Hive::Config.define_singleton_method(:load_global_bot, original)
    end

    update = Hive::Bot::Telegram::Update.new(
      update_id: 1, chat_id: 42, from_id: 42, message_id: 1,
      text: "/autofix stuck-260526-cccc"
    )
    supervisor.process_update(update)

    queued = @dispatch_request_writer.writes.map { |w| w[:argv] }
    assert(queued.any? { |argv| argv[0, 3] == [ "hive", "markers", "clear" ] },
           "after SIGHUP reload, /autofix must still resolve the slug and queue the " \
           "recover sequence — proving the rebuilt Router kept status_snapshot_provider")
    assert_empty @child_supervisor.dispatched,
                 "queue-routable verbs must not spawn from the bot (single-dispatcher invariant)"
  end

  def test_default_status_snapshot_provider_dispatches_recover_sequence_for_cached_row
    # Exercises the full default wiring (real Router built by the constructor)
    # end-to-end: the status_snapshot_provider lambda must reach
    # latest_status_rows, resolve the cached row, and dispatch the recover
    # sequence. Asserts the dispatched argv, not merely "some message sent",
    # so the lambda returning [] or the row failing to resolve would fail.
    retryable = row(slug: "wire-260526-aaaa", stage: "6-review", action: "recover_review",
                    marker: "review_error", attrs: { "pass" => "2" },
                    diagnostic: { "suggested_next_action" => { "kind" => "retry" } })
    supervisor = Hive::Bot::Supervisor.new(
      config: @config, token: "test-token", logger: @logger, telegram: @telegram,
      status_watcher: @status_watcher, notification_dispatcher: @notification_dispatcher,
      router: nil, child_supervisor: @child_supervisor,
      conversation_store: @conversation_store, dry_run: false,
      dispatch_request_writer: @dispatch_request_writer
    )
    supervisor.instance_variable_set(:@latest_status_rows, [ retryable ])

    update = Hive::Bot::Telegram::Update.new(
      update_id: 1, chat_id: 42, from_id: 42, message_id: 1,
      text: "/autofix wire-260526-aaaa"
    )
    supervisor.process_update(update)

    queued = @dispatch_request_writer.writes.map { |w| w[:argv] }
    assert(queued.any? { |argv| argv[0, 3] == [ "hive", "markers", "clear" ] },
           "default snapshot provider must route /autofix through latest_status_rows " \
           "to a real recover-sequence queued dispatch")
    assert_empty @child_supervisor.dispatched,
                 "queue-routable verbs must not spawn from the bot (single-dispatcher invariant)"
  end

  def test_reap_children_dispatches_reply_for_each_completed_child
    @child_supervisor.reap_batches << [ child_exit(exit_code: 0) ]

    @supervisor.reap_children

    # exit_code 0 yields nil from child_completion_text → no Telegram ack.
    # The contract under test is that reap_children iterates the batch and
    # calls reply_for_child without raising; @telegram.messages stays empty
    # because the clean-exit path is silent by design.
    assert_empty @telegram.messages,
                 "exit_code 0 must not produce a Telegram ack (child_completion_text returns nil)"
  end

  def test_reap_children_delivers_idea_capture_ack_through_the_full_reaper_path
    @child_supervisor.reap_batches << [
      child_exit(exit_code: 0, project: "writero",
                 command_argv: [ "hive", "new", "writero", "an idea", "--json" ])
    ]

    @supervisor.reap_children

    # End-to-end wiring: reap_children -> reply_for_child -> child_completion_text
    # -> @telegram.send_message. Unit tests calling child_completion_text directly
    # would miss a regression where reply_for_child stops reaching it for exit-0.
    message = @telegram.messages.last
    assert_equal 42, message.fetch(:chat_id), "the ack must go to the child's chat_id"
    assert_includes message.fetch(:text), "Captured your idea in writero"
  end

  def test_finalize_completed_brainstorm_in_dry_run_announces_without_dispatching
    supervisor = Hive::Bot::Supervisor.new(
      config: @config, token: "test-token", logger: @logger, telegram: @telegram,
      status_watcher: @status_watcher, notification_dispatcher: @notification_dispatcher,
      router: FakeRouter.new, child_supervisor: @child_supervisor,
      conversation_store: @conversation_store, dry_run: true,
      dispatch_request_writer: @dispatch_request_writer
    )
    result = FakeRouter::Result.new(slug: "done-260526-aaaa", project: "hive")
    update = Update.new(chat_id: 42, update_id: 7, message_id: 1)

    supervisor.send(:finalize_completed_brainstorm, result, update, 4)

    assert_match(/All questions answered/, @telegram.messages.last.fetch(:text))
    assert_match(/Dry-run: not dispatching/, @telegram.messages.last.fetch(:text))
    assert_empty @child_supervisor.dispatched, "dry-run must not dispatch hive run"
    assert_empty @dispatch_request_writer.writes, "dry-run must not write a dispatch request either"
  end

  def test_auto_run_after_answers_recovers_and_logs_when_queue_write_raises
    @dispatch_request_writer.raise_on_write = RuntimeError.new("write failed")
    result = FakeRouter::Result.new(slug: "x-260526-aaaa", project: "hive")
    update = Update.new(chat_id: 42, update_id: 7, message_id: 1)

    @supervisor.send(:auto_run_after_answers, result, update)

    assert_match(/Couldn't queue the request/, @telegram.messages.last.fetch(:text),
                 "a queue-write failure must surface a corrective message")
    failure = @logger.events.find { |e| e[:name] == :send_failure }
    refute_nil failure
    assert_equal "enqueue_dispatch_request", failure.fetch(:payload).fetch(:source)
  end

  # `auto_run_after_answers`'s outer rescue catches anything that
  # escapes `execute_dispatch`. The queue-write path catches
  # internally, but a writer that raises something OTHER than
  # StandardError would skip the inner rescue. Force that path by
  # stubbing `execute_dispatch` to raise directly.
  def test_auto_run_after_answers_outer_rescue_surfaces_corrective_message
    result = FakeRouter::Result.new(slug: "x-260526-aaaa", project: "hive")
    update = Update.new(chat_id: 42, update_id: 7, message_id: 1)
    @supervisor.define_singleton_method(:execute_dispatch) do |*|
      raise "spawn pipeline blew up"
    end

    @supervisor.send(:auto_run_after_answers, result, update)

    assert_match(/couldn't start the next round automatically/,
                 @telegram.messages.last.fetch(:text))
    failure = @logger.events.find { |e| e[:name] == :send_failure }
    refute_nil failure
    assert_equal "auto_run_after_answers", failure.fetch(:payload).fetch(:source)
  end

  def test_trigger_for_result_maps_intents_for_telemetry
    %i[
      slash_done callback_autofix callback_clear_and_retry callback_approve
      callback_findings_accept_all callback_findings_reject_all callback_show_details
    ].each do |intent|
      result = FakeRouter::Result.new(intent: intent)
      trigger = @supervisor.send(:trigger_for_result, result)
      assert_kind_of String, trigger, "intent #{intent} must map to a string trigger label"
      refute_empty trigger
    end
    # Unknown intent → generic label
    assert_equal "bot_dispatch", @supervisor.send(:trigger_for_result, FakeRouter::Result.new(intent: :something_new))
    # Missing intent attr → generic label (responds_to? false branch)
    assert_equal "bot_dispatch", @supervisor.send(:trigger_for_result, Object.new)
  end

  def test_auto_run_after_answers_writes_dispatch_request_not_spawn
    result = FakeRouter::Result.new(slug: "x-260526-aaaa", project: "hive")
    update = Update.new(chat_id: 42, update_id: 7, message_id: 1)

    @supervisor.send(:auto_run_after_answers, result, update)

    assert_equal 1, @dispatch_request_writer.writes.size,
                 "answer-complete must write exactly one dispatch request"
    write = @dispatch_request_writer.writes.first
    assert_equal "hive", write[:project]
    assert_equal "x-260526-aaaa", write[:slug]
    assert_equal [ "hive", "run", "x-260526-aaaa", "--json" ], write[:argv]
    assert_empty @child_supervisor.dispatched,
                 "the bot must NOT spawn `hive run` itself anymore — that's the daemon's job now"
  end

  def test_register_bot_commands_sends_full_command_list_to_telegram
    @supervisor.send(:register_bot_commands)

    registered = Array(@telegram.commands_registered)
    assert_equal 1, registered.length, "register_bot_commands must call set_my_commands exactly once"

    commands = registered.first
    assert_equal Hive::Bot::Supervisor::BOT_COMMANDS, commands
    slash_names = commands.map { |cmd| cmd.fetch(:command) }
    assert_equal %w[idea status queue answer approve autofix details done help], slash_names
    assert(commands.all? { |cmd| cmd.fetch(:description).length.between?(1, 256) },
           "every command description must be non-empty and within Telegram's 256-char cap")
  end

  def test_register_bot_commands_swallows_telegram_failure_and_logs_send_failure
    @telegram.raise_on_set_my_commands = StandardError.new("boom")

    @supervisor.send(:register_bot_commands)  # must not raise

    failure = @logger.events.find { |e| e[:name] == :send_failure }
    refute_nil failure, "a set_my_commands failure must be logged as :send_failure"
    assert_equal "set_my_commands", failure.fetch(:payload).fetch(:source)
    assert_equal "StandardError", failure.fetch(:payload).fetch(:error_class)
    assert_equal "boom", failure.fetch(:payload).fetch(:message)
  end

  def test_child_completion_text_covers_exit_statuses
    assert_equal "Already advanced by another device",
                 @supervisor.send(:child_completion_text, child_exit(exit_code: Hive::ExitCodes::WRONG_STAGE))
    assert_equal "Try again - another run holds the lock",
                 @supervisor.send(:child_completion_text, child_exit(exit_code: Hive::ExitCodes::TEMPFAIL))
    assert_nil @supervisor.send(:child_completion_text, child_exit(exit_code: 0)),
               "clean exit must not produce a Telegram ack — 'Command completed' was operational chatter"
    assert_includes @supervisor.send(:child_completion_text, child_exit(exit_code: 17)), "Command failed with exit 17"
  end

  def test_child_completion_text_acknowledges_successful_idea_capture
    text = @supervisor.send(
      :child_completion_text,
      child_exit(exit_code: 0, project: "writero",
                 command_argv: [ "hive", "new", "writero", "an idea", "--json" ])
    )

    assert_includes text, "Captured your idea",
                     "a successful `hive new` must confirm the capture so the picker doesn't look dead"
    assert_includes text, "writero", "the confirmation should name the project the idea landed in"
  end

  def test_child_completion_text_acknowledges_capture_when_hive_bin_resolved
    # ChildSupervisor#normalize_hive_bin rewrites argv[0] to a resolved
    # binary path, so detection must key on the verb at argv[1], not argv[0].
    text = @supervisor.send(
      :child_completion_text,
      child_exit(exit_code: 0, project: "writero",
                 command_argv: [ "/usr/local/bin/hive", "new", "writero", "an idea", "--json" ])
    )

    assert_includes text, "Captured your idea",
                     "capture ack must survive argv[0] being a resolved hive binary path"
  end

  def test_child_completion_text_falls_back_to_argv_project_when_child_project_nil
    text = @supervisor.send(
      :child_completion_text,
      child_exit(exit_code: 0, project: nil,
                 command_argv: [ "hive", "new", "writero", "an idea", "--json" ])
    )

    assert_includes text, "Captured your idea"
    assert_includes text, "writero",
                     "with child.project nil the ack must name the project from argv[2]"
  end

  def test_child_completion_text_omits_project_suffix_when_unknown
    text = @supervisor.send(
      :child_completion_text,
      child_exit(exit_code: 0, project: nil, command_argv: [ "hive", "new" ])
    )

    assert_equal "Captured your idea. It's in the inbox — move it to 2-brainstorm to start.", text,
                 "with no project from child or argv, the ack drops the ' in <project>' suffix"
  end

  def test_child_completion_text_stays_silent_for_short_argv
    assert_nil @supervisor.send(:child_completion_text, child_exit(exit_code: 0, command_argv: [ "hive" ])),
               "a 1-element argv has no verb at argv[1], so exit-0 stays silent"
    assert_nil @supervisor.send(:child_completion_text, child_exit(exit_code: 0, command_argv: [])),
               "an empty argv has no verb, so exit-0 stays silent"
  end

  def test_child_completion_text_stays_silent_for_non_new_success
    assert_nil @supervisor.send(
      :child_completion_text,
      child_exit(exit_code: 0, command_argv: [ "hive", "run", "some-slug", "--json" ])
    ), "exit-0 commands other than `hive new` must stay silent (signal shows in the next status row)"
  end

  def test_send_reconnect_summary_skips_empty_update_list
    @supervisor.send(:send_reconnect_summary, [])

    assert_empty @telegram.messages
    assert_empty @logger.events
  end

  def test_send_reconnect_summary_sends_plural_summary_to_allowlisted_chats
    updates = [ Update.new(chat_id: 42, update_id: 7), Update.new(chat_id: 42, update_id: 8) ]

    @supervisor.send(:send_reconnect_summary, updates)

    assert_equal [ 42, 43 ], @telegram.messages.map { |message| message.fetch(:chat_id) }
    assert @telegram.messages.all? { |message| message.fetch(:text).include?("2 messages queued") }
    assert_equal :reconnect_summary, @logger.events.first.fetch(:name)
    assert_equal 2, @logger.events.first.fetch(:payload).fetch(:queued_count)
  end

  def test_render_queue_filters_inert_rows_caps_output_and_reports_overflow
    rows = 12.times.map { |i| row(slug: "task-#{i}") }
    rows += [ row(slug: "done", action: "archived"), row(slug: "running", action: "agent_running") ]

    text = @supervisor.send(:render_queue, rows)

    assert_includes text, "12 active tasks"
    assert_includes text, "Task 0… — Plan"
    assert_includes text, "+ 2 more tasks"
    refute_includes text, "hive/task-0"
    refute_includes text, "COMPLETE"
    refute_includes text, "done"
    refute_includes text, "running"
  end

  def test_status_keyboard_has_callback_button_per_actionable_row_type
    # /status uses inline callback buttons, not text "/command <slug>" links:
    # Telegram's bot_command entity covers only the token, so a tapped text
    # link drops the slug. Each actionable row gets one button whose
    # callback_data matches the push-notification surface.
    brainstorm = row(slug: "ask-q-260526-aaaa", stage: "2-brainstorm",
                     action: "needs_input", marker: "waiting")
    ready_to_x = row(slug: "ship-it-260526-bbbb", stage: "7-artifacts",
                     action: "ready_to_finalize", marker: "complete")
    retryable_recovery = row(slug: "stuck-260526-cccc", stage: "6-review",
                             action: "recover_review", marker: "review_error",
                             attrs: { "phase" => "fix", "pass" => "2" },
                             diagnostic: { "suggested_next_action" => { "kind" => "retry" } })
    manual_recovery = row(slug: "stale-260526-dddd", stage: "4-execute",
                          action: "recover_review", marker: "execute_stale",
                          attrs: {}, diagnostic: nil)
    inert = row(slug: "agent-running-260526-eeee", action: "agent_running")

    keyboard = @supervisor.send(:status_keyboard,
                                [ brainstorm, ready_to_x, retryable_recovery, manual_recovery, inert ])
    callbacks = keyboard.flatten.map { |btn| btn[:callback_data] }

    assert_includes callbacks, "answer:hive:ask-q-260526-aaaa",
                    "brainstorm-waiting rows get an answer button"
    assert_includes callbacks, "approve:finalize:hive:ship-it-260526-bbbb:7-artifacts",
                    "ready_to_X rows get an approve button with the workflow verb"
    assert_includes callbacks, "autofix:hive:stuck-260526-cccc:6-review:review_error:pass=2",
                    "retryable recovery rows get an autofix button"
    assert_includes callbacks, "details:hive:stale-260526-dddd:4-execute",
                    "manual-only recovery rows get a details button"
    assert_equal 4, callbacks.length, "inert agent_running rows produce no button"
  end

  def test_status_keyboard_is_nil_when_no_row_is_actionable
    plain_inflight = row(slug: "in-flight-260526-aaaa", stage: "4-execute",
                         action: "developing", marker: "agent_working")

    assert_nil @supervisor.send(:status_keyboard, [ plain_inflight ]),
               "a reply with no actionable rows must stay text-only (no empty keyboard)"
  end

  def test_render_details_sorts_attrs_and_handles_missing_row
    rows = [ row(attrs: { "z" => 9, "a" => 1 }, marker: nil, action_label: nil) ]

    text = @supervisor.send(:render_details, rows, "hive", "task")

    assert_includes text, "hive/task (3-plan)"
    assert_includes text, "Action: ready_to_develop"
    assert_includes text, "Marker: none"
    assert_includes text, "Attrs: a=1 z=9"
    assert_equal "No active row found for hive/missing.", @supervisor.send(:render_details, rows, "hive", "missing")
  end

  def test_execute_dispatch_renders_status_queue_without_spawning_child
    rows = [ row(slug: "alpha") ]
    @status_watcher.result = StatusResult.new(ok: true, rows: rows)
    result = FakeRouter::Result.new(action: :dispatch_then_reply, command_argv: [ "hive", "status", "--json" ])

    pid = @supervisor.send(:execute_dispatch, result, Update.new(chat_id: 42, update_id: 10))

    assert_nil pid
    assert_empty @child_supervisor.dispatched
    assert_includes @telegram.messages.last.fetch(:text), "1 active task"
    # ready_to_develop row → an approve button on the /status reply.
    callbacks = @telegram.messages.last.fetch(:reply_markup).flatten.map { |btn| btn[:callback_data] }
    assert_includes callbacks, "approve:develop:hive:alpha:3-plan"
  end

  def test_execute_dispatch_renders_legacy_stage_dirs_in_status_queue
    @status_watcher.result = StatusResult.new(ok: true, rows: [], legacy_stage_dirs: [ legacy_stage_dirs ])
    result = FakeRouter::Result.new(action: :dispatch_then_reply, command_argv: [ "hive", "status", "--json" ])

    pid = @supervisor.send(:execute_dispatch, result, Update.new(chat_id: 42, update_id: 10))

    assert_nil pid
    assert_empty @child_supervisor.dispatched
    message = @telegram.messages.last
    assert_includes message.fetch(:text),
                    "Project hive has 1 task hidden in legacy stage dirs (6-pr) - run `hive migrate /tmp/hive`"
    assert_includes message.fetch(:text), "No active Hive tasks."
    assert_nil message[:reply_markup]
  end

  def test_execute_dispatch_filters_legacy_stage_dirs_by_project
    other_legacy = legacy_stage_dirs(project: "other", project_path: "/tmp/other")
    @status_watcher.result = StatusResult.new(
      ok: true,
      rows: [ row(project: "hive", slug: "alpha-260525-abcd") ],
      legacy_stage_dirs: [ other_legacy ]
    )
    result = FakeRouter::Result.new(
      action: :dispatch_then_reply,
      command_argv: [ "hive", "status", "--json" ],
      project: "other"
    )

    @supervisor.send(:execute_dispatch, result, Update.new(chat_id: 42, update_id: 10))

    message = @telegram.messages.last
    assert_includes message.fetch(:text),
                    "Project other has 1 task hidden in legacy stage dirs (6-pr) - run `hive migrate /tmp/other`"
    assert_includes message.fetch(:text), "No active Hive tasks."
    refute_includes message.fetch(:text), "Alpha"
    assert_nil message[:reply_markup]
  end

  def test_execute_dispatch_filters_status_by_project
    rows = [ row(project: "hive", slug: "alpha-260525-abcd"), row(project: "other", slug: "beta-260525-abcd") ]
    @status_watcher.result = StatusResult.new(ok: true, rows: rows)
    result = FakeRouter::Result.new(
      action: :dispatch_then_reply,
      command_argv: [ "hive", "status", "--json" ],
      project: "other"
    )

    @supervisor.send(:execute_dispatch, result, Update.new(chat_id: 42, update_id: 10))

    text = @telegram.messages.last.fetch(:text)
    assert_includes text, "Beta… — Plan"
    refute_includes text, "Alpha"
    # Only the project-filtered row contributes a button.
    callbacks = @telegram.messages.last.fetch(:reply_markup).flatten.map { |btn| btn[:callback_data] }
    assert_equal [ "approve:develop:other:beta-260525-abcd:3-plan" ], callbacks
  end

  def test_execute_dispatch_reports_unknown_project_with_known_list
    @status_watcher.result = StatusResult.new(ok: true, rows: [ row(project: "hive", slug: "alpha") ])
    result = FakeRouter::Result.new(
      action: :dispatch_then_reply,
      command_argv: [ "hive", "status", "--json" ],
      project: "missing"
    )

    @supervisor.send(:execute_dispatch, result, Update.new(chat_id: 42, update_id: 10))

    text = @telegram.messages.last.fetch(:text)
    assert_match(/Unknown project missing/, text)
    assert_match(/hive/, text)
  end

  def test_execute_dispatch_reports_no_tasks_for_known_but_empty_project
    with_registered_projects([ { "name" => "hive" }, { "name" => "other" } ]) do
      @status_watcher.result = StatusResult.new(ok: true, rows: [ row(project: "hive", slug: "alpha") ])
      result = FakeRouter::Result.new(
        action: :dispatch_then_reply,
        command_argv: [ "hive", "status", "--json" ],
        project: "other"
      )

      @supervisor.send(:execute_dispatch, result, Update.new(chat_id: 42, update_id: 10))

      assert_equal "No tasks for project other.", @telegram.messages.last.fetch(:text)
    end
  end

  def test_execute_dispatch_renders_status_envelope_when_format_json
    envelope = {
      "schema" => "hive-status",
      "schema_version" => 1,
      "ok" => true,
      "projects" => [
        { "name" => "hive", "tasks" => [ { "slug" => "alpha" } ] },
        { "name" => "other", "tasks" => [ { "slug" => "beta" } ] }
      ]
    }
    @status_watcher.result = StatusResult.new(ok: true, rows: [], envelope: envelope)
    result = FakeRouter::Result.new(
      action: :dispatch_then_reply,
      command_argv: [ "hive", "status", "--json" ],
      format: :json
    )

    @supervisor.send(:execute_dispatch, result, Update.new(chat_id: 42, update_id: 10))

    text = @telegram.messages.last.fetch(:text)
    parsed = JSON.parse(text)
    assert_equal "hive-status", parsed["schema"], "JSON reply must surface the raw envelope"
    project_names = parsed["projects"].map { |p| p["name"] }
    assert_equal %w[hive other], project_names
  end

  def test_execute_dispatch_renders_status_envelope_filtered_by_project_when_format_json
    envelope = {
      "schema" => "hive-status",
      "projects" => [
        { "name" => "hive", "tasks" => [ { "slug" => "alpha" } ] },
        { "name" => "other", "tasks" => [ { "slug" => "beta" } ] }
      ]
    }
    @status_watcher.result = StatusResult.new(ok: true, rows: [], envelope: envelope)
    result = FakeRouter::Result.new(
      action: :dispatch_then_reply,
      command_argv: [ "hive", "status", "--json" ],
      project: "hive",
      format: :json
    )

    @supervisor.send(:execute_dispatch, result, Update.new(chat_id: 42, update_id: 10))

    parsed = JSON.parse(@telegram.messages.last.fetch(:text))
    assert_equal [ "hive" ], parsed["projects"].map { |p| p["name"] },
                 "project filter must drop other projects from the JSON envelope"
  end

  def test_execute_dispatch_surfaces_status_fetch_failure
    @status_watcher.result = StatusResult.new(ok: false, rows: [], error: "envelope ok=false: pipeline timeout")
    result = FakeRouter::Result.new(
      action: :dispatch_then_reply,
      command_argv: [ "hive", "status", "--json" ]
    )

    @supervisor.send(:execute_dispatch, result, Update.new(chat_id: 42, update_id: 10))

    assert_equal "hive status unavailable: envelope ok=false: pipeline timeout",
                 @telegram.messages.last.fetch(:text)
  end

  def test_execute_dispatch_renders_status_details_when_slug_is_present
    rows = [ row(slug: "alpha") ]
    @status_watcher.result = StatusResult.new(ok: true, rows: rows)
    result = FakeRouter::Result.new(action: :dispatch_then_reply, command_argv: [ "hive", "status", "--json" ],
                                    project: "hive", slug: "alpha")

    @supervisor.send(:execute_dispatch, result, Update.new(chat_id: 42, update_id: 10))

    assert_includes @telegram.messages.last.fetch(:text), "hive/alpha (3-plan)"
  end

  def test_execute_dispatch_dry_run_does_not_spawn_child
    @supervisor.instance_variable_set(:@dry_run, true)
    result = FakeRouter::Result.new(
      action: :dispatch_then_reply,
      command_argv: [ "hive", "plan", "task" ],
      project: "hive",
      slug: "task"
    )

    pid = @supervisor.send(:execute_dispatch, result, Update.new(chat_id: 42, update_id: 11))

    assert_nil pid
    assert_empty @child_supervisor.dispatched
    assert_equal "Dry run: hive plan task", @telegram.messages.last.fetch(:text)
  end

  # Queue-routable command sequences write only the first request immediately.
  # The daemon promotes the stored continuation after that first command exits
  # 0, so a failed `markers clear` cannot run the retry verb.
  def test_dispatch_command_sequence_writes_first_queue_request_and_sequence_continuation
    result = FakeRouter::Result.new(
      action: :dispatch_commands,
      commands: [
        [ "hive", "markers", "clear", "task", "--name", "REVIEW_ERROR" ],
        [ "hive", "review", "task", "--from", "6-review", "--json" ]
      ],
      project: "hive",
      slug: "task",
      alert_reset: { project: "hive", slug: "task", stage: "6-review" }
    )

    @supervisor.send(:dispatch_command_sequence, result, Update.new(chat_id: 42, update_id: 12))

    assert_empty @child_supervisor.dispatched,
                 "queue-routable verbs must NOT spawn from the bot — single-dispatcher invariant"
    assert_equal 1, @dispatch_request_writer.writes.size,
                 "only `markers clear` is visible to the daemon immediately"
    assert_equal [ "hive", "markers", "clear", "task", "--name", "REVIEW_ERROR" ],
                 @dispatch_request_writer.writes[0][:argv]
    assert_equal 1, @dispatch_request_writer.sequences.size
    assert_equal @dispatch_request_writer.writes.first[:request_id],
                 @dispatch_request_writer.sequences.first[:request_id]
    assert_equal [ [ "hive", "review", "task", "--from", "6-review", "--json" ] ],
                 @dispatch_request_writer.sequences.first[:remaining_argvs]
  end

  # AC-05 (PR #241 ce-code-review): the all-queue-routable path must NOT
  # reset the alert at enqueue time. The daemon hasn't run `markers clear`
  # yet, so removing the fingerprint here would let the next status tick
  # re-fire the same alert (entry.nil? -> re-send in process_current).
  # State-driven recovery removes the alert once the daemon clears the
  # marker; leaving the fingerprint keeps the persistent dedupe intact.
  def test_dispatch_command_sequence_does_not_reset_alert_on_queue_path
    result = FakeRouter::Result.new(
      action: :dispatch_commands,
      commands: [ [ "hive", "review", "task", "--json" ] ],
      project: "hive",
      slug: "task",
      alert_reset: { project: "hive", slug: "task", stage: "6-review" }
    )

    @supervisor.send(:dispatch_command_sequence, result, Update.new(chat_id: 42, update_id: 12))

    assert_empty @notification_dispatcher.reset_tasks,
                 "queue path must not reset the alert before the daemon clears the marker (AC-05)"
    assert_equal 1, @dispatch_request_writer.writes.size
    assert_equal [ "hive", "review", "task", "--json" ],
                 @dispatch_request_writer.writes.first[:argv]
    assert_empty @child_supervisor.dispatched
  end

  # Mixed sequence: `accept-finding` (not queue-routable, spawns) +
  # retry verb (queue-routable, writes a request). The findings
  # callbacks are the one remaining mixed surface in the codebase
  # — `RecoverySequence` is now all-queue. The bot waits on the
  # accept-finding child like before; the retry verb lands in the
  # queue with no wait.
  def test_dispatch_command_sequence_mixed_spawn_and_queue_waits_then_enqueues
    @child_supervisor.dispatch_pid = 700
    @child_supervisor.completed[700] = child_exit(exit_code: 0, pid: 700)
    result = FakeRouter::Result.new(
      action: :dispatch_commands,
      commands: [
        [ "hive", "accept-finding", "--all", "--stage", "6-review",
          "--project", "hive", "task", "--json" ],
        [ "hive", "review", "task", "--from", "6-review", "--project", "hive", "--json" ]
      ],
      project: "hive",
      slug: "task",
      alert_reset: { project: "hive", slug: "task", stage: "6-review" }
    )

    @supervisor.send(:dispatch_command_sequence, result, Update.new(chat_id: 42, update_id: 12))

    assert_equal 1, @child_supervisor.dispatched.length,
                 "the non-queue-routable command (accept-finding) must spawn from the bot"
    assert_equal [ "hive", "accept-finding", "--all", "--stage", "6-review",
                   "--project", "hive", "task", "--json" ],
                 @child_supervisor.dispatched.first.fetch(:command_argv)
    assert_equal 1, @dispatch_request_writer.writes.length,
                 "the queue-routable retry verb must land in the queue"
    assert_equal [ "hive", "review", "task", "--from", "6-review", "--project", "hive", "--json" ],
                 @dispatch_request_writer.writes.first[:argv]
    assert_equal 1, @notification_dispatcher.reset_tasks.length,
                 "alert reset fires once between the two commands"
  end

  def test_dispatch_command_sequence_mixed_aborts_when_spawn_fails
    @child_supervisor.dispatch_pid = 701
    @child_supervisor.completed[701] = child_exit(exit_code: 1, pid: 701)
    result = FakeRouter::Result.new(
      action: :dispatch_commands,
      commands: [
        [ "hive", "accept-finding", "--all", "--project", "hive", "task", "--json" ],
        [ "hive", "review", "task", "--from", "6-review", "--project", "hive", "--json" ]
      ],
      project: "hive",
      slug: "task",
      alert_reset: { project: "hive", slug: "task", stage: "6-review" }
    )

    @supervisor.send(:dispatch_command_sequence, result, Update.new(chat_id: 42, update_id: 12))

    assert_equal 1, @child_supervisor.dispatched.length,
                 "only the first command spawned before the wait detected failure"
    assert_empty @dispatch_request_writer.writes,
                 "retry verb must NOT be enqueued when the spawn precursor fails"
    assert_empty @notification_dispatcher.reset_tasks,
                 "alert reset must NOT fire when the spawn precursor fails"
    assert_includes @telegram.messages.last.fetch(:text), "Stopped because the previous command failed"
  end

  # AC-05: a two-command all-queue sequence (`markers clear` + retry)
  # must not reset the alert either — same race. The fingerprint stays
  # until the daemon actually clears the marker and a later status tick
  # drives recovery.
  def test_dispatch_command_sequence_does_not_reset_alert_for_two_command_queue_sequence
    result = FakeRouter::Result.new(
      action: :dispatch_commands,
      commands: [
        [ "hive", "markers", "clear", "task", "--name", "REVIEW_ERROR" ],
        [ "hive", "review", "task", "--from", "6-review", "--json" ]
      ],
      project: "hive",
      slug: "task",
      alert_reset: { project: "hive", slug: "task", stage: "6-review" }
    )

    @supervisor.send(:dispatch_command_sequence, result, Update.new(chat_id: 42, update_id: 12))

    assert_empty @notification_dispatcher.reset_tasks,
                 "two-command queue sequence must not reset the alert at enqueue time (AC-05)"
    assert_equal 1, @dispatch_request_writer.writes.size,
                 "only the first request is enqueued immediately"
    assert_equal 1, @dispatch_request_writer.sequences.size,
                 "the retry verb must be held as a daemon-promoted continuation"
  end

  def test_dispatch_command_sequence_discards_sequence_when_first_request_fails
    @dispatch_request_writer.raise_on_write = RuntimeError.new("disk full")
    result = FakeRouter::Result.new(
      action: :dispatch_commands,
      commands: [
        [ "hive", "markers", "clear", "task", "--json" ],
        [ "hive", "review", "task", "--from", "6-review", "--json" ]
      ],
      project: "hive",
      slug: "task"
    )

    @supervisor.send(:dispatch_command_sequence, result, Update.new(chat_id: 42, update_id: 12))

    assert_equal [ "req-1" ], @dispatch_request_writer.discarded_sequences,
                 "a continuation sidecar must not survive if the first request never enqueued"
  end

  def test_dispatch_command_sequence_reports_sequence_write_failure
    @dispatch_request_writer.raise_on_sequence = RuntimeError.new("sequence disk full")
    result = FakeRouter::Result.new(
      action: :dispatch_commands,
      commands: [
        [ "hive", "markers", "clear", "task", "--json" ],
        [ "hive", "review", "task", "--from", "6-review", "--json" ]
      ],
      project: "hive",
      slug: "task"
    )

    @supervisor.send(:dispatch_command_sequence, result, Update.new(chat_id: 42, update_id: 12))

    assert_equal [ "req-1" ], @dispatch_request_writer.discarded_sequences
    assert_empty @dispatch_request_writer.writes
    assert(@logger.events.any? { |event| event[:payload][:source] == "enqueue_command_sequence" })
    assert_match(/Couldn't queue the request sequence/, @telegram.messages.last[:text])
  end

  def test_dispatch_command_sequence_logs_discard_failure
    @dispatch_request_writer.raise_on_write = RuntimeError.new("write failed")
    @dispatch_request_writer.raise_on_discard = RuntimeError.new("unlink failed")
    result = FakeRouter::Result.new(
      action: :dispatch_commands,
      commands: [
        [ "hive", "markers", "clear", "task", "--json" ],
        [ "hive", "review", "task", "--from", "6-review", "--json" ]
      ],
      project: "hive",
      slug: "task"
    )

    @supervisor.send(:dispatch_command_sequence, result, Update.new(chat_id: 42, update_id: 12))

    assert(@logger.events.any? { |event| event[:payload][:source] == "discard_sequence" })
  end

  def test_dispatch_command_sequence_skips_alert_reset_in_dry_run
    @supervisor.instance_variable_set(:@dry_run, true)
    result = FakeRouter::Result.new(
      action: :dispatch_commands,
      commands: [ [ "hive", "develop", "task", "--json" ] ],
      project: "hive",
      slug: "task",
      alert_reset: { project: "hive", slug: "task", stage: "4-execute" }
    )

    @supervisor.send(:dispatch_command_sequence, result, Update.new(chat_id: 42, update_id: 12))

    assert_empty @notification_dispatcher.reset_tasks,
                 "dry_run must not call reset_task even when alert_reset is present"
  end

  # ── ADV-1: drain daemon failure notices to Telegram ───────────────────

  def test_drain_dispatch_results_relays_failure_to_chat_and_removes
    Dir.mktmpdir("hive-dispatch-result") do |home|
      @supervisor.instance_variable_set(:@dispatch_result_state_home, home)
      Hive::Daemon::DispatchResultQueue.write!(
        chat_id: 42, update_id: 7, project: "hive", slug: "stuck-task",
        request_id: "rq000001", exit_code: 4,
        command: "hive markers clear stuck-task", state_home: home
      )

      @supervisor.send(:drain_dispatch_results)

      assert_equal 1, @telegram.messages.size, "failure notice must reach the originating chat"
      msg = @telegram.messages.first
      assert_equal 42, msg[:chat_id]
      assert_includes msg[:text], "stuck-task"
      assert_includes msg[:text], "exit 4"
      assert_empty Hive::Daemon::DispatchResultQueue.pending(state_home: home),
                   "a relayed notice must be removed so it isn't sent twice"
    end
  end

  # #263: a notice whose chat_id is not in the allowlist (chat removed
  # while a request was in-flight, or a notice forged in the 0700 dir) is
  # dropped + removed without relaying — defense-in-depth re-validation.
  def test_drain_dispatch_results_drops_notice_for_unauthorized_chat
    Dir.mktmpdir("hive-dispatch-result") do |home|
      @supervisor.instance_variable_set(:@dispatch_result_state_home, home)
      Hive::Daemon::DispatchResultQueue.write!(
        chat_id: 999, project: "hive", slug: "stuck-task",
        request_id: "rq000099", exit_code: 4,
        command: "hive markers clear stuck-task", state_home: home
      )

      @supervisor.send(:drain_dispatch_results)

      assert_empty @telegram.messages,
                   "a notice for a non-allowlisted chat must not be relayed"
      assert_empty Hive::Daemon::DispatchResultQueue.pending(state_home: home),
                   "the unauthorized notice must be removed, not left to retry forever"
      rejected = @logger.events.find { |e| e[:name] == :dispatch_result_rejected_unauthorized }
      refute_nil rejected, "the drop must be logged for an audit trail"
      assert_equal 999, rejected[:payload][:chat_id]
    end
  end

  def test_drain_dispatch_results_removes_malformed_notice
    Dir.mktmpdir("hive-dispatch-result") do |home|
      @supervisor.instance_variable_set(:@dispatch_result_state_home, home)
      dir = Hive::Daemon::DispatchResultQueue.directory(state_home: home)
      bad = File.join(dir, "20260528-bad.json")
      File.write(bad, "{not json")

      @supervisor.send(:drain_dispatch_results)

      assert_empty @telegram.messages, "a malformed notice has no chat to reply to"
      refute File.exist?(bad), "malformed notice must be removed so it can't wedge the drain"
    end
  end

  # #1: a notice is retained (retried next tick) when the relay fails —
  # never silently dropped.
  def test_drain_dispatch_results_keeps_notice_when_send_fails
    Dir.mktmpdir("hive-dispatch-result") do |home|
      @supervisor.instance_variable_set(:@dispatch_result_state_home, home)
      Hive::Daemon::DispatchResultQueue.write!(
        chat_id: 42, project: "hive", slug: "t", request_id: "rq1", exit_code: 1,
        command: "hive review t", state_home: home
      )
      @telegram.raise_on_send = IOError.new("telegram down")

      @supervisor.send(:drain_dispatch_results)

      assert_empty @telegram.messages
      refute_empty Hive::Daemon::DispatchResultQueue.pending(state_home: home),
                   "a notice must be kept for retry when the Telegram relay fails (#1)"
    end
  end

  # #4: a timeout/signal-killed child has a nil exit_code → render as a
  # kill, not "exit ".
  def test_drain_dispatch_results_renders_nil_exit_as_killed
    Dir.mktmpdir("hive-dispatch-result") do |home|
      @supervisor.instance_variable_set(:@dispatch_result_state_home, home)
      Hive::Daemon::DispatchResultQueue.write!(
        chat_id: 42, project: "hive", slug: "wedged", request_id: "rqk", exit_code: nil,
        command: "hive review wedged", state_home: home
      )

      @supervisor.send(:drain_dispatch_results)

      assert_includes @telegram.messages.first[:text], "killed (signal/timeout)"
    end
  end

  # #6: stale notices are dropped WITHOUT relaying (no hour-old spam) and
  # pruned to bound growth.
  def test_drain_dispatch_results_drops_stale_without_sending
    Dir.mktmpdir("hive-dispatch-result") do |home|
      @supervisor.instance_variable_set(:@dispatch_result_state_home, home)
      Hive::Daemon::DispatchResultQueue.write!(
        chat_id: 42, project: "hive", slug: "old", request_id: "rqold", exit_code: 1,
        command: "hive review old", state_home: home, now: Time.now - 7200
      )

      @supervisor.send(:drain_dispatch_results)

      assert_empty @telegram.messages, "a stale notice must not be relayed"
      assert_empty Hive::Daemon::DispatchResultQueue.pending(state_home: home),
                   "a stale notice must be pruned"
    end
  end

  # #6: a large backlog is capped and the tail collapsed into one summary
  # per chat so a reconnect can't flood Telegram.
  def test_drain_dispatch_results_caps_and_summarizes_overflow
    Dir.mktmpdir("hive-dispatch-result") do |home|
      @supervisor.instance_variable_set(:@dispatch_result_state_home, home)
      14.times do |i|
        Hive::Daemon::DispatchResultQueue.write!(
          chat_id: 42, project: "hive", slug: "t#{i}", request_id: "rq#{i}", exit_code: 1,
          command: "hive review t#{i}", state_home: home, now: Time.now + i
        )
      end

      @supervisor.send(:drain_dispatch_results)

      cap = Hive::Bot::Supervisor::DISPATCH_RESULT_SEND_CAP
      assert_equal cap + 1, @telegram.messages.size,
                   "#{cap} individual relays + one overflow summary"
      assert_includes @telegram.messages.last[:text], "more dispatch failures suppressed"
      assert_empty Hive::Daemon::DispatchResultQueue.pending(state_home: home),
                   "the whole backlog is cleared after a successful drain"
    end
  end

  def test_clear_inline_keyboard_swallows_telegram_errors
    @telegram.define_singleton_method(:edit_message_reply_markup) do |*|
      raise IOError, "telegram offline"
    end
    result = FakeRouter::Result.new(
      action: :dispatch_commands,
      commands: [ [ "hive", "develop", "task", "--json" ] ],
      project: "hive",
      slug: "task",
      clear_keyboard: true
    )

    @supervisor.send(:dispatch_command_sequence, result, Update.new(chat_id: 42, update_id: 12, message_id: 777))

    failure = @logger.events.find { |evt| evt[:name] == :send_failure }
    refute_nil failure, ":send_failure must be logged when edit_message_reply_markup raises"
    assert_equal "edit_message_reply_markup", failure[:payload][:source]
    # `develop` is queue-routable, so the request lands in the writer
    # rather than @child_supervisor.dispatched.
    assert_equal 1, @dispatch_request_writer.writes.length,
                 "the queue-routable command must still be enqueued even when keyboard clear fails"
    assert_empty @child_supervisor.dispatched
  end

  def test_registered_project_names_returns_empty_when_config_raises
    original = Hive::Config.method(:registered_projects)
    Hive::Config.define_singleton_method(:registered_projects) do
      raise Hive::ConfigError, "synthetic"
    end

    assert_equal [], @supervisor.send(:registered_project_names),
                 "config load errors during registered_project_names must yield []"
  ensure
    Hive::Config.define_singleton_method(:registered_projects, original) if original
  end

  def test_dispatch_command_sequence_clears_inline_keyboard_when_requested
    result = FakeRouter::Result.new(
      action: :dispatch_commands,
      commands: [ [ "hive", "review", "task", "--json" ] ],
      project: "hive",
      slug: "task",
      clear_keyboard: true
    )

    @supervisor.send(:dispatch_command_sequence, result, Update.new(chat_id: 42, update_id: 12, message_id: 777))

    assert_equal 1, @telegram.keyboard_clears.size, "edit_message_reply_markup must be called once"
    clear = @telegram.keyboard_clears.first
    assert_equal 42, clear.fetch(:chat_id)
    assert_equal 777, clear.fetch(:message_id)
    assert_nil clear.fetch(:reply_markup), "reply_markup must be nil to remove the inline keyboard"
  end

  def test_dispatch_command_sequence_does_not_clear_keyboard_without_flag
    result = FakeRouter::Result.new(
      action: :dispatch_commands,
      commands: [ [ "hive", "develop", "task", "--json" ] ],
      project: "hive",
      slug: "task"
    )

    @supervisor.send(:dispatch_command_sequence, result, Update.new(chat_id: 42, update_id: 12, message_id: 777))

    assert_nil @telegram.keyboard_clears, "edit_message_reply_markup must not be called when clear_keyboard is false/nil"
  end

  def test_queued_updates_filters_by_last_seen_and_allowlist
    with_tmp_dir do |dir|
      state_file = File.join(dir, "last_seen")
      File.write(state_file, "10")
      @supervisor.instance_variable_get(:@config)["last_seen_state_file"] = state_file
      updates = [
        Update.new(chat_id: 42, update_id: 10),
        Update.new(chat_id: 99, update_id: 11),
        Update.new(chat_id: 43, update_id: 12)
      ]

      queued = @supervisor.send(:queued_updates, updates)

      assert_equal [ 12 ], queued.map(&:update_id)
    end
  end

  def test_last_seen_state_returns_nil_on_invalid_and_write_creates_parent
    with_tmp_dir do |dir|
      state_file = File.join(dir, "nested", "last_seen")
      @supervisor.instance_variable_get(:@config)["last_seen_state_file"] = state_file
      assert_nil @supervisor.send(:read_last_seen_update_id)

      @supervisor.send(:write_last_seen_update_id, 44)
      assert_equal 44, @supervisor.send(:read_last_seen_update_id)

      File.write(state_file, "not-an-integer")
      assert_nil @supervisor.send(:read_last_seen_update_id)
    end
  end

  def test_start_answer_replies_when_no_unanswered_question_exists
    result = FakeRouter::Result.new(action: :start_answer, slug: "missing", project: "hive", mode: :path_b)

    @supervisor.send(:start_answer, result, Update.new(chat_id: 42, update_id: 13))

    assert_empty @conversation_store.starts,
                 "no conversation must be opened when there is nothing to answer"
    assert_includes @telegram.messages.last.fetch(:text), "No unanswered questions"
  end

  def test_start_answer_includes_question_text_in_first_prompt
    with_brainstorm_file(content: "## Round 1\n### Q1. Should we use SQLite or Postgres?\n### A1.\n") do |path, project|
      @supervisor.define_singleton_method(:brainstorm_path_for) { |_slug, project: nil| path }
      result = FakeRouter::Result.new(action: :start_answer, slug: "bot-task-260522-aa",
                                      project: File.basename(project), mode: :path_b)

      @supervisor.send(:start_answer, result, Update.new(chat_id: 42, update_id: 13))

      text = @telegram.messages.last.fetch(:text)
      assert_includes text, "Q1: Should we use SQLite or Postgres?",
                      "first prompt must include the actual question text so operators don't have to fetch it elsewhere"
      assert_includes text, "Reply with your answer"
    end
  end

  def test_execute_answer_write_handles_missing_slug_and_no_unanswered_question
    result = FakeRouter::Result.new(
      action: :write_answer_then_reply, slug: "missing", project: "hive", answer_text: "answer"
    )
    @supervisor.send(:execute_answer_write, result, Update.new(chat_id: 42, update_id: 14))
    assert_equal "Slug not found, was it archived?", @telegram.messages.last.fetch(:text)

    @supervisor.define_singleton_method(:brainstorm_path_for) { |_slug, project: nil| "/tmp/brainstorm.md" }
    @supervisor.define_singleton_method(:next_unanswered_question_n) { |_path| nil }
    result = FakeRouter::Result.new(
      action: :write_answer_then_reply, slug: "done", project: "hive", answer_text: "answer"
    )
    @supervisor.send(:execute_answer_write, result, Update.new(chat_id: 42, update_id: 15))
    assert_equal "No unanswered questions remain for done.", @telegram.messages.last.fetch(:text)
  end
  def test_request_shutdown_and_reload_set_loop_flags
    @supervisor.request_shutdown!
    @supervisor.request_reload!

    assert_equal true, @supervisor.instance_variable_get(:@shutdown)
    assert_equal true, @supervisor.instance_variable_get(:@reload)
  end

  def test_process_update_executes_reply_and_persists_last_seen
    with_tmp_dir do |dir|
      state_file = File.join(dir, "last_seen")
      @supervisor.instance_variable_get(:@config)["last_seen_state_file"] = state_file
      router = Object.new
      router.define_singleton_method(:handle) do |_update|
        FakeRouter::Result.new(action: :reply, text: "hello", reply_markup: { inline_keyboard: [] })
      end
      @supervisor.instance_variable_set(:@router, router)

      @supervisor.process_update(Update.new(chat_id: 42, update_id: 77))

      assert_equal "hello", @telegram.messages.last.fetch(:text)
      assert_equal "77", File.read(state_file)
    end
  end

  def test_execute_result_rejects_unknown_action
    error = assert_raises(RuntimeError) do
      @supervisor.send(:execute_result, FakeRouter::Result.new(action: :surprise), Update.new(chat_id: 42, update_id: 1))
    end

    assert_match(/unknown action/, error.message)
  end

  def test_safe_send_message_logs_telegram_failures
    @telegram.raise_on_send = RuntimeError.new("offline")

    assert_nil @supervisor.send(:safe_send_message, chat_id: 42, text: "hello")

    event = @logger.events.last
    assert_equal :send_failure, event.fetch(:name)
    assert_equal "offline", event.fetch(:payload).fetch(:message)
  end

  def test_status_tick_processes_rows_only_when_status_is_ok
    failure = StatusResult.new(ok: false, rows: [ row(slug: "ignored") ])
    @status_watcher.result = failure

    assert_same failure, @supervisor.status_tick
    assert_empty @notification_dispatcher.processed

    success = StatusResult.new(ok: true, rows: [ row(slug: "active") ])
    @status_watcher.result = success

    assert_same success, @supervisor.status_tick
    assert_equal [ [ row(slug: "active") ] ], @notification_dispatcher.processed
  end

  def test_wait_for_child_success_reaps_and_replies_for_completed_child
    child = child_exit(exit_code: 0, pid: 456)
    @child_supervisor.reap_batches << [ child ]

    ok = @supervisor.send(:wait_for_child_success, 456, deadline: Time.now + 1)

    assert_equal true, ok
    assert_empty @telegram.messages,
                 "clean exit must not produce a Telegram ack — 'Command completed' was operational chatter"
  end

  def test_wait_for_child_success_times_out_without_completed_child
    ok = @supervisor.send(:wait_for_child_success, 999, deadline: Time.now - 1)

    assert_equal false, ok
  end

  def test_project_and_brainstorm_paths_resolve_registered_project
    with_tmp_global_config do
      with_brainstorm_file(content: "## Round 1\n### Q1. Scope?\n### A1.\n") do |path, project|
        Hive::Config.register_project(name: "proj", path: project)

        assert_equal project, @supervisor.send(:project_path_for, "proj")
        assert_equal path, @supervisor.send(:brainstorm_path_for, "bot-task-260522-aa", project: "proj")
      end
    end
  end

  def test_reload_config_success_rebuilds_runtime_collaborators
    new_config = @supervisor.instance_variable_get(:@config).merge("conversation_ttl_sec" => 123)
    original = Hive::Config.method(:load_global_bot)
    Hive::Config.define_singleton_method(:load_global_bot) do |require_runtime:|
      raise "reload must require runtime" unless require_runtime

      new_config
    end

    @supervisor.request_reload!
    @supervisor.send(:reload_config_if_requested)

    assert_equal new_config, @supervisor.instance_variable_get(:@config)
    assert_equal [ 123 ], @conversation_store.ttl_updates
    assert_equal :config_reloaded, @logger.events.last.fetch(:name)
    assert_equal false, @supervisor.instance_variable_get(:@reload)
  ensure
    Hive::Config.define_singleton_method(:load_global_bot, original) if original
  end

  def test_reload_config_failure_keeps_existing_config
    old_config = @supervisor.instance_variable_get(:@config)
    original = Hive::Config.method(:load_global_bot)
    Hive::Config.define_singleton_method(:load_global_bot) do |require_runtime:|
      raise Hive::ConfigError, "bad bot config"
    end

    @supervisor.request_reload!
    @supervisor.send(:reload_config_if_requested)

    assert_same old_config, @supervisor.instance_variable_get(:@config)
    assert_equal false, @supervisor.instance_variable_get(:@reload)
    assert_equal :fatal, @logger.events.last.fetch(:name)
    assert_match(/bad bot config/, @logger.events.last.fetch(:payload).fetch(:message))
  ensure
    Hive::Config.define_singleton_method(:load_global_bot, original) if original
  end

  def test_interruptible_sleep_returns_when_shutdown_or_reload_is_requested
    @supervisor.request_shutdown!
    started = Time.now
    @supervisor.send(:interruptible_sleep, 5)
    assert_operator Time.now - started, :<, 1

    @supervisor.instance_variable_set(:@shutdown, false)
    @supervisor.request_reload!
    started = Time.now
    @supervisor.send(:interruptible_sleep, 5)
    assert_operator Time.now - started, :<, 1
  end

  def test_execute_answer_write_appends_real_answer_and_advances_conversation
    content = "## Round 1\n### Q1. Scope?\n### A1.\n\n### Q2. Cadence?\n### A2.\n"
    with_brainstorm_file(content: content) do |path, _project|
      @conversation_store.start(chat_id: 42, slug: "task", question_n: 1, mode: :path_b, project: "hive")
      @supervisor.define_singleton_method(:brainstorm_path_for) { |_slug, project: nil| path }
      result = FakeRouter::Result.new(
        action: :write_answer_then_reply,
        slug: "task",
        project: "hive",
        question_n: 1,
        answer_text: "Build the real thing"
      )

      @supervisor.send(:execute_answer_write, result, Update.new(chat_id: 42, update_id: 20))

      assert_includes File.read(path), "Build the real thing"
      text = @telegram.messages.last.fetch(:text)
      assert_match(/Got Q1\./, text)
      assert_match(/Q2: Cadence\?/, text,
                   "auto-advance must include the next unanswered question text in the same reply")
      assert_match(/Reply with your answer/, text)
      assert_equal 2, @conversation_store.updates.last.fetch(:values).fetch(:question_n)
    end
  end

  def test_execute_answer_write_reports_already_answered_and_missing_question
    with_brainstorm_file(content: "## Round 1\n### Q1. Scope?\n### A1.
  Done.\n") do |path, _project|
      @supervisor.define_singleton_method(:brainstorm_path_for) { |_slug, project: nil| path }
      answered = FakeRouter::Result.new(
        action: :write_answer_then_reply,
        slug: "task",
        project: "hive",
        question_n: 1,
        answer_text: "new answer"
      )

      @supervisor.send(:execute_answer_write, answered, Update.new(chat_id: 42, update_id: 21))
      assert_equal "Question 1 was already answered by another device", @telegram.messages.last.fetch(:text)

      missing = FakeRouter::Result.new(
        action: :write_answer_then_reply,
        slug: "task",
        project: "hive",
        question_n: 99,
        answer_text: "new answer"
      )
      @supervisor.send(:execute_answer_write, missing, Update.new(chat_id: 42, update_id: 22))
      assert_equal "Question 99 was not found.", @telegram.messages.last.fetch(:text)
    end
  end






  def test_poll_loop_logs_process_update_failure_and_advances_update_id
    update = Update.new(chat_id: 42, update_id: 77)
    supervisor = @supervisor
    poll_args = []
    @supervisor.instance_variable_set(:@next_update_id, nil)
    @supervisor.instance_variable_get(:@config)["long_poll_timeout_sec"] = 0
    @telegram.define_singleton_method(:poll_updates) do |timeout:, since_update_id:|
      poll_args << [ timeout, since_update_id ]
      supervisor.request_shutdown!
      [ update ]
    end
    @supervisor.define_singleton_method(:process_update) { |_incoming| raise "process blew up" }

    @supervisor.send(:poll_loop)

    assert_equal [ [ 0, nil ] ], poll_args
    assert_equal 78, @supervisor.instance_variable_get(:@next_update_id)
    event = @logger.events.find { |entry| entry.fetch(:payload)[:source] == "process_update" }
    assert_equal :fatal, event.fetch(:name)
    assert_equal "process blew up", event.fetch(:payload).fetch(:message)
  end

  def test_poll_loop_logs_poll_failure_and_sleeps_interruptibly
    supervisor = @supervisor
    @supervisor.instance_variable_get(:@config)["long_poll_timeout_sec"] = 0
    slept = []
    @telegram.define_singleton_method(:poll_updates) do |timeout:, since_update_id:|
      supervisor.request_shutdown!
      raise "telegram offline"
    end
    @supervisor.define_singleton_method(:interruptible_sleep) { |seconds| slept << seconds }

    @supervisor.send(:poll_loop)

    event = @logger.events.find { |entry| entry.fetch(:payload)[:source] == "poll_loop" }
    assert_equal :fatal, event.fetch(:name)
    assert_equal "telegram offline", event.fetch(:payload).fetch(:message)
    assert_equal [ 1 ], slept
  end

  def test_status_loop_logs_tick_failures
    supervisor = @supervisor
    @supervisor.define_singleton_method(:status_tick) do
      supervisor.request_shutdown!
      raise "status exploded"
    end
    @supervisor.define_singleton_method(:interruptible_sleep) { |_seconds| }

    @supervisor.send(:status_loop)

    event = @logger.events.find { |entry| entry.fetch(:payload)[:source] == "status_loop" }
    assert_equal :fatal, event.fetch(:name)
    assert_equal "status exploded", event.fetch(:payload).fetch(:message)
  end

  def test_status_loop_invokes_update_nudge_push
    supervisor = @supervisor
    pushed = false
    @supervisor.define_singleton_method(:status_tick) { supervisor.request_shutdown! }
    @supervisor.define_singleton_method(:push_update_nudge) { pushed = true }
    @supervisor.define_singleton_method(:interruptible_sleep) { |_seconds| }

    @supervisor.send(:status_loop)

    assert pushed, "status_loop must invoke push_update_nudge each iteration"
  end

  def test_reaper_loop_drains_dispatch_results_each_iteration
    supervisor = @supervisor
    @supervisor.define_singleton_method(:reap_children) { supervisor.request_shutdown! }
    drained = false
    @supervisor.define_singleton_method(:drain_dispatch_results) { drained = true }
    @supervisor.define_singleton_method(:sleep) { |_seconds| }

    @supervisor.send(:reaper_loop)

    assert drained, "reaper_loop must drain the daemon's dispatch-result notice channel (ADV-1)"
  end

  def test_reaper_loop_logs_reap_failures
    supervisor = @supervisor
    @supervisor.define_singleton_method(:reap_children) do
      supervisor.request_shutdown!
      raise "reap exploded"
    end
    @supervisor.define_singleton_method(:sleep) { |_seconds| }

    @supervisor.send(:reaper_loop)

    event = @logger.events.find { |entry| entry.fetch(:payload)[:source] == "reaper_loop" }
    assert_equal :fatal, event.fetch(:name)
    assert_equal "reap exploded", event.fetch(:payload).fetch(:message)
  end

  def test_execute_result_routes_compound_actions_to_helpers
    calls = []
    @supervisor.define_singleton_method(:dispatch_command_sequence) { |result, update| calls << [ :sequence, result, update ] }
    @supervisor.define_singleton_method(:start_answer) { |result, update| calls << [ :start_answer, result, update ] }
    @supervisor.define_singleton_method(:execute_answer_write) { |result, update| calls << [ :answer_write, result, update ] }
    update = Update.new(chat_id: 42, update_id: 88)

    [
      [ :dispatch_commands, :sequence ],
      [ :start_answer, :start_answer ],
      [ :write_answer_then_reply, :answer_write ]
    ].each do |action, expected_call|
      result = FakeRouter::Result.new(action: action)
      @supervisor.send(:execute_result, result, update)
      assert_equal expected_call, calls.last.first
      assert_same result, calls.last[1]
      assert_same update, calls.last[2]
    end
  end

  def test_wait_for_child_success_sleeps_until_child_completes
    child = child_exit(exit_code: 0, pid: 456)
    @child_supervisor.reap_batches << [] << [ child ]
    sleeps = []
    @supervisor.define_singleton_method(:sleep) { |seconds| sleeps << seconds }

    ok = @supervisor.send(:wait_for_child_success, 456, deadline: Time.now + 1)

    assert_equal true, ok
    assert_equal [ 0.1 ], sleeps
    assert_empty @telegram.messages,
                 "clean exit must not produce a Telegram ack — 'Command completed' was operational chatter"
  end

  def test_execute_answer_write_reports_lock_busy
    with_brainstorm_file(content: "## Round 1\n### Q1. Scope?\n### A1.\n") do |path, _project|
      @supervisor.define_singleton_method(:brainstorm_path_for) { |_slug, project: nil| path }
      result = FakeRouter::Result.new(
        action: :write_answer_then_reply,
        slug: "task",
        project: "hive",
        question_n: 1,
        answer_text: "Build it"
      )

      with_replaced_singleton_method(Hive::Bot::BrainstormAnswerWriter, :append!, ->(**_kwargs) { :lock_busy }) do
        @supervisor.send(:execute_answer_write, result, Update.new(chat_id: 42, update_id: 23))
      end

      assert_equal "Try again - another run holds the lock", @telegram.messages.last.fetch(:text)
    end
  end

  # `:answer_slot_missing` is a distinct result from
  # `:question_not_found` — the question IS in brainstorm.md but no
  # fillable A-slot was locatable. Supervisor must render a message
  # that says so (not the legacy "Question N was not found", which is
  # misleading when Q{n} actually exists). Observed 2026-05-28 on
  # explore-the-simplest-way-to-260528-2503 where the brainstorm
  # agent emitted `### A2.` directly after `### Q1.`.
  def test_execute_answer_write_reports_answer_slot_missing_distinctly
    with_brainstorm_file(content: "## Round 1\n### Q1. Scope?\n### A1.\n") do |path, _project|
      @supervisor.define_singleton_method(:brainstorm_path_for) { |_slug, project: nil| path }
      result = FakeRouter::Result.new(
        action: :write_answer_then_reply,
        slug: "task",
        project: "hive",
        question_n: 1,
        answer_text: "Build it"
      )

      with_replaced_singleton_method(Hive::Bot::BrainstormAnswerWriter, :append!,
                                     ->(**_kwargs) { :answer_slot_missing }) do
        @supervisor.send(:execute_answer_write, result, Update.new(chat_id: 42, update_id: 24))
      end

      text = @telegram.messages.last.fetch(:text)
      assert_match(/answer slot is missing or malformed/, text,
                   "must distinguish from `Question N was not found`")
      assert_match(/### A1\./, text, "must name the expected header to add")
      refute_match(/was not found\.\z/, text,
                   "must not fall through to the legacy not-found copy")
    end
  end




  def test_next_unanswered_question_n_parses_brainstorm_file
    with_brainstorm_file(content: "## Round 1\n### Q1. Scope?\n### A1.\n") do |path, _project|
      assert_equal 1, @supervisor.send(:next_unanswered_question_n, path)
    end
  end

  def with_registered_projects(projects)
    original = Hive::Config.method(:registered_projects)
    Hive::Config.define_singleton_method(:registered_projects) { projects }
    yield
  ensure
    Hive::Config.define_singleton_method(:registered_projects, original)
  end

  def test_interruptible_sleep_sleeps_until_flag_changes
    supervisor = @supervisor
    sleeps = []
    @supervisor.define_singleton_method(:sleep) do |seconds|
      sleeps << seconds
      supervisor.request_shutdown!
    end

    @supervisor.send(:interruptible_sleep, 5)

    assert_equal [ 0.5 ], sleeps
  end
end
