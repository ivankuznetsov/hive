require "test_helper"
require "hive/bot/supervisor"
require "hive/bot/telegram"
require "hive/bot/brainstorm_parser"

class HiveBotScenarioBrainstormTest < Minitest::Test
  include HiveTestHelper

  def setup
    @old_home = ENV["HIVE_HOME"]
    @home = Dir.mktmpdir("hive-bot-s1")
    ENV["HIVE_HOME"] = @home
  end

  def teardown
    FileUtils.remove_entry(@home) if @home && File.exist?(@home)
    ENV["HIVE_HOME"] = @old_home
  end

  def test_s1_answers_four_questions_in_thread_and_done_dispatches_run
    project = File.join(@home, "project")
    slug = "mobile-bot-260514-abcd"
    brainstorm = File.join(project, ".hive-state", "stages", "2-brainstorm", slug, "brainstorm.md")
    FileUtils.mkdir_p(File.dirname(brainstorm))
    File.write(brainstorm, <<~MARKDOWN)
      ## Round 2

      ### Q1. One?

      ### A1.

      ### Q2. Two?

      ### A2.

      ### Q3. Three?

      ### A3.

      ### Q4. Four?

      ### A4.

      <!-- WAITING -->
    MARKDOWN
    File.write(File.join(@home, "config.yml"), {
      "registered_projects" => [
        { "name" => "hive", "path" => project, "hive_state_path" => File.join(project, ".hive-state") }
      ],
      "bot" => { "chat_id_allowlist" => [ 12345 ] }
    }.to_yaml)

    supervisor = supervisor_for
    supervisor.process_update(update(text: "/answer #{slug}", update_id: 1))
    4.times do |idx|
      supervisor.process_update(update(text: "Answer #{idx + 1}", update_id: idx + 2))
    end
    supervisor.process_update(update(text: "/done", update_id: 10))

    answers = Hive::Bot::BrainstormParser.parse(brainstorm).map(&:answer)
    assert_equal [ "Answer 1", "Answer 2", "Answer 3", "Answer 4" ], answers
    assert_equal [ "hive", "run", slug, "--json" ], child.commands.last
  end

  private

  def supervisor_for
    @telegram = FakeTelegram.new
    @child = FakeChildSupervisor.new
    Hive::Bot::Supervisor.new(
      config: bot_config,
      token: "token",
      logger: FakeLogger.new,
      telegram: @telegram,
      status_watcher: FakeStatusWatcher.new,
      notification_dispatcher: FakeNotificationDispatcher.new,
      child_supervisor: @child,
      dry_run: false
    )
  end

  def child
    @child
  end

  def bot_config
    Hive::Config.load_global_bot.merge(
      "chat_id_allowlist" => [ 12345 ],
      "poll_interval_sec" => 30,
      "long_poll_timeout_sec" => 25,
      "notification_dedupe_window_sec" => 300,
      "conversation_ttl_sec" => 3600,
      "shutdown_grace_sec" => 1,
      "last_seen_state_file" => File.join(@home, ".bot.last_seen_update_id")
    )
  end

  def update(text:, update_id:)
    Hive::Bot::Telegram::Update.new(update_id: update_id, chat_id: 12345,
                                    from_id: 12345, text: text)
  end

  class FakeLogger
    def event(_name, **_attrs); end
    def close; end
  end

  class FakeTelegram
    attr_reader :messages
    def initialize = @messages = []
    def send_message(chat_id:, text:, reply_markup: nil, parse_mode: :markdown)
      @messages << { chat_id: chat_id, text: text, reply_markup: reply_markup, parse_mode: parse_mode }
    end

    def edit_message_reply_markup(chat_id:, message_id:, reply_markup: nil); end
  end

  class FakeStatusWatcher
    Result = Struct.new(:ok, :rows, :error, keyword_init: true)
    def fetch = Result.new(ok: true, rows: [], error: nil)
  end

  class FakeNotificationDispatcher
    def process_rows(_rows); end
    def record_dispatch(project:, slug:); end
  end

  class FakeChildSupervisor
    attr_reader :commands
    def initialize = @commands = []
    def dispatch(command_argv:, **_opts)
      @commands << command_argv
      1234
    end
    def reap_all = []
    def terminate_all(grace_sec:); end
    def in_flight_count = 0
  end
end
