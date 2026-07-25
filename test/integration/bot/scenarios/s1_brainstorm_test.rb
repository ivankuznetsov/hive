require "test_helper"
require "json"
require "hive/bot/supervisor"
require "hive/bot/telegram"
require "hive/bot/brainstorm_parser"
require "hive/daemon/dispatch_request_queue"

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
    # After plan 2026-05-28-002, `hive run` is queue-routable: the bot
    # writes a dispatch-request file under <HIVE_HOME>/dispatch_requests/
    # instead of spawning a child. The daemon picks the request up.
    assert_empty child.commands,
                 "hive run must no longer spawn from the bot — it's the daemon's job now"
    request_files = Dir.glob(File.join(@home, "dispatch_requests", "*.json"))
    assert_equal 1, request_files.size, "exactly one dispatch request must have landed in the queue"
    payload = JSON.parse(File.read(request_files.first))
    assert_match(/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/, payload["request_id"])
    assert_equal [ "hive", "run", slug, "--json" ], payload["argv"]
    assert_equal "hive", payload["project"]
    assert_equal slug, payload["slug"]
    assert_equal "bot", payload["requestor"]
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
      dispatch_request_writer: QueueOnlyDispatchRequestWriter,
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

  # This scenario asserts the request-file contract. Durable foreground
  # admission has dedicated DispatchRequestWriter coverage; delegating only to
  # write! here prevents an actual detached worker racing the scenario teardown.
  module QueueOnlyDispatchRequestWriter
    module_function

    def write!(**kwargs)
      Hive::Bot::DispatchRequestWriter.write!(**kwargs)
    end

    def generate_request_id
      Hive::Bot::DispatchRequestWriter.generate_request_id
    end
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
