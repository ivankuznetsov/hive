require "test_helper"
require "hive/bot/supervisor"
require "hive/commands/init"

class HiveBotScenarioVoiceIdeaTest < Minitest::Test
  include HiveTestHelper

  TranscriptionResult = Struct.new(:status, :text, :language, :error_class, :message, keyword_init: true)

  FakeTranscriber = Struct.new(:results, :calls, keyword_init: true) do
    def call(bytes, filename:, content_type:)
      calls << { bytes: bytes, filename: filename, content_type: content_type }
      results.shift
    end
  end

  class FakeTelegram
    attr_reader :messages, :callback_acks
    attr_accessor :download_bytes

    def initialize
      @messages = []
      @callback_acks = []
      @download_bytes = "audio-bytes".b
    end

    def send_message(chat_id:, text:, reply_markup: nil)
      @messages << { chat_id: chat_id, text: text, reply_markup: reply_markup }
    end

    def get_file(file_id:)
      { file_path: "voice/#{file_id}.oga", file_size: download_bytes.bytesize }
    end

    def download_file(file_path:)
      download_bytes
    end

    def answer_callback_query(callback_query_id:, text: nil, show_alert: false)
      @callback_acks << { callback_query_id: callback_query_id, text: text, show_alert: show_alert }
    end

    def edit_message_reply_markup(chat_id:, message_id:, reply_markup: nil); end
    def set_my_commands(commands:); end
  end

  class StubLogger
    attr_reader :events

    def initialize
      @events = []
    end

    def event(name, **attrs)
      @events << [ name, attrs ]
    end

    def close; end
  end

  def setup_project
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        yield dir, File.basename(dir)
      end
    end
  end

  def supervisor(transcriber:, telegram:)
    Hive::Bot::Supervisor.new(
      config: {
        "chat_id_allowlist" => [ 12345 ],
        "conversation_ttl_sec" => 60,
        "poll_interval_sec" => 1,
        "idea_attachment_max_bytes" => 20 * 1024 * 1024,
        "idea_attachment_max_count" => 10,
        "idea_draft_ttl_sec" => 900,
        "transcription" => { "enabled" => true }
      },
      token: "test-token",
      logger: StubLogger.new,
      telegram: telegram,
      status_watcher: Struct.new(:ok) { def fetch = Struct.new(:ok, :rows).new(true, []) }.new,
      notification_dispatcher: Struct.new(:processed) { def process_rows(_rows); end }.new,
      child_supervisor: Struct.new(:in_flight_count) do
        def reap_all = []
        def terminate_all(grace_sec:); end
      end.new(0),
      dry_run: false,
      transcriber: transcriber
    )
  end

  def message_update(text: nil, voice: nil)
    Hive::Bot::Telegram::Update.new(update_id: next_update_id, chat_id: 12345, from_id: 12345,
                                    message_id: next_update_id, text: text, voice: voice)
  end

  def callback_update(data)
    Hive::Bot::Telegram::Update.new(update_id: next_update_id, chat_id: 12345, from_id: 12345,
                                    message_id: next_update_id, callback_data: data,
                                    callback_query_id: "cbq-#{@update_id}")
  end

  def next_update_id
    @update_id = (@update_id || 0) + 1
  end

  def voice_payload(file_id = "voice-id")
    { file_id: file_id, file_size: 10, mime_type: "audio/ogg", duration: 3 }
  end

  def callback_named(message, name)
    message.fetch(:reply_markup).flatten.detect { |button| button[:text] == name }.fetch(:callback_data)
  end

  def pick_project_callback(telegram, project)
    picker = telegram.messages.reverse.detect { |message| message[:reply_markup] }
    picker.fetch(:reply_markup).flatten.detect { |button| button[:callback_data].include?("idea_project:#{project}:") }
          .fetch(:callback_data)
  end

  def inbox_dirs(project_root)
    Dir[File.join(project_root, ".hive-state", "stages", "1-inbox", "*")]
  end

  def test_voice_happy_path_captures_transcript_only
    setup_project do |dir, project|
      telegram = FakeTelegram.new
      transcriber = FakeTranscriber.new(
        results: [ TranscriptionResult.new(status: :ok, text: "voice transcript", language: "en") ],
        calls: []
      )
      bot = supervisor(transcriber: transcriber, telegram: telegram)

      bot.process_update(message_update(voice: voice_payload))
      bot.process_update(callback_update(callback_named(telegram.messages.last, "Confirm")))
      bot.process_update(callback_update(pick_project_callback(telegram, project)))

      inbox = inbox_dirs(dir)
      assert_equal 1, inbox.size
      assert_includes File.read(File.join(inbox.first, "idea.md")), "voice transcript"
      refute_path_exists File.join(inbox.first, "assets")
    end
  end

  def test_voice_text_edit_captures_corrected_transcript
    setup_project do |dir, project|
      telegram = FakeTelegram.new
      transcriber = FakeTranscriber.new(
        results: [ TranscriptionResult.new(status: :ok, text: "wrong transcript", language: "en") ],
        calls: []
      )
      bot = supervisor(transcriber: transcriber, telegram: telegram)

      bot.process_update(message_update(voice: voice_payload))
      bot.process_update(message_update(text: "corrected transcript"))
      bot.process_update(callback_update(callback_named(telegram.messages.last, "Confirm")))
      bot.process_update(callback_update(pick_project_callback(telegram, project)))

      idea = File.read(File.join(inbox_dirs(dir).first, "idea.md"))
      assert_includes idea, "corrected transcript"
      refute_includes idea, "wrong transcript"
    end
  end

  def test_voice_edit_by_second_voice_captures_second_transcript
    setup_project do |dir, project|
      telegram = FakeTelegram.new
      transcriber = FakeTranscriber.new(
        results: [
          TranscriptionResult.new(status: :ok, text: "first transcript", language: "en"),
          TranscriptionResult.new(status: :ok, text: "second transcript", language: "en")
        ],
        calls: []
      )
      bot = supervisor(transcriber: transcriber, telegram: telegram)

      bot.process_update(message_update(voice: voice_payload("first")))
      bot.process_update(message_update(voice: voice_payload("second")))
      bot.process_update(callback_update(callback_named(telegram.messages.last, "Confirm")))
      bot.process_update(callback_update(pick_project_callback(telegram, project)))

      idea = File.read(File.join(inbox_dirs(dir).first, "idea.md"))
      assert_includes idea, "second transcript"
      refute_includes idea, "first transcript"
    end
  end

  def test_voice_transcription_failure_retains_audio_attachment
    setup_project do |dir, project|
      telegram = FakeTelegram.new
      telegram.download_bytes = "raw-audio".b
      transcriber = FakeTranscriber.new(
        results: [ TranscriptionResult.new(status: :failed) ],
        calls: []
      )
      bot = supervisor(transcriber: transcriber, telegram: telegram)

      bot.process_update(message_update(voice: voice_payload))
      bot.process_update(message_update(text: "fallback idea text"))
      bot.process_update(callback_update(pick_project_callback(telegram, project)))
      done = callback_named(telegram.messages.last, "Done")
      bot.process_update(callback_update(done))

      inbox = inbox_dirs(dir)
      assert_equal 1, inbox.size
      idea = File.read(File.join(inbox.first, "idea.md"))
      assert_includes idea, "fallback idea text"
      assert_includes idea, "[voice-1.oga](assets/voice-1.oga)"
      assert_equal "raw-audio", File.binread(File.join(inbox.first, "assets", "voice-1.oga"))
    end
  end

  def test_voice_discard_captures_nothing
    setup_project do |dir, _project|
      telegram = FakeTelegram.new
      transcriber = FakeTranscriber.new(
        results: [ TranscriptionResult.new(status: :ok, text: "discard me", language: "en") ],
        calls: []
      )
      bot = supervisor(transcriber: transcriber, telegram: telegram)

      bot.process_update(message_update(voice: voice_payload))
      bot.process_update(callback_update(callback_named(telegram.messages.last, "Discard")))

      assert_empty inbox_dirs(dir)
      assert_match(/Discarded/, telegram.messages.last.fetch(:text))
    end
  end
end
