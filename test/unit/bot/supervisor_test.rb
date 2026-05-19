require "test_helper"
require "hive/bot/supervisor"

class HiveBotSupervisorTest < Minitest::Test
  ChildExit = Hive::Bot::ChildSupervisor::ChildExit

  FakeTelegram = Struct.new(:messages, keyword_init: true) do
    def send_message(chat_id:, text:, reply_markup: nil)
      messages << { chat_id: chat_id, text: text, reply_markup: reply_markup }
    end
  end

  def setup
    @telegram = FakeTelegram.new(messages: [])
    @supervisor = Hive::Bot::Supervisor.allocate
    @supervisor.instance_variable_set(:@telegram, @telegram)
  end

  def child_exit(exit_code: 0, envelope: nil, log_path: "/tmp/hive-bot.log")
    ChildExit.new(
      pid: 123,
      exit_code: exit_code,
      project: "hive",
      slug: "red-task-260518-aaaa",
      command_argv: [ "hive", "status", "--diagnose", "red-task-260518-aaaa", "--json" ],
      chat_id: 42,
      update_id: 99,
      started_at: Time.now,
      finished_at: Time.now,
      log_path: log_path,
      json_envelope: envelope
    )
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
    assert_includes text, "REVIEW_ERROR phase=fix pass=1"
    assert_includes text, "fix attempt timed out"
    assert_includes text, "Path: /tmp/red-status.md"
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
end
