require "test_helper"
require "hive/bot/handlers/slash_handlers"

class HiveBotSlashHandlersTest < Minitest::Test
  Result = Struct.new(:action, :text, :reply_markup, :command_argv, :commands,
                      :project, :slug, :question_n, :answer_text, :mode,
                      :intent, :format, keyword_init: true)
  Update = Struct.new(:text, :chat_id, keyword_init: true)

  def setup
    @handlers = Hive::Bot::Handlers::SlashHandlers.new(
      projects_provider: -> { [] },
      pending_ideas: {},
      last_project: -> { nil },
      result_class: Result
    )
  end

  def test_status_without_project_dispatches_global_status
    result = @handlers.status(Update.new(text: "/status"))

    assert_equal :dispatch_then_reply, result.action
    assert_equal [ "hive", "status", "--json" ], result.command_argv
    assert_nil result.project
  end

  def test_status_with_project_dispatches_filtered_status
    result = @handlers.status(Update.new(text: "/status hive"))

    assert_equal :dispatch_then_reply, result.action
    assert_equal [ "hive", "status", "--json", "--project", "hive" ], result.command_argv
    assert_equal "hive", result.project
  end

  def test_status_preserves_multi_word_project_names
    result = @handlers.status(Update.new(text: "/status my project"))

    assert_equal :dispatch_then_reply, result.action
    assert_equal [ "hive", "status", "--json", "--project", "my project" ], result.command_argv
    assert_equal "my project", result.project
  end

  def test_help_documents_project_status_argument
    result = @handlers.help(Update.new(text: "/help"))

    assert_includes result.text, "/status [project]"
  end

  def test_status_with_json_flag_sets_format_json
    result = @handlers.status(Update.new(text: "/status --json"))

    assert_equal :json, result.format
    assert_nil result.project, "/status --json without a project must produce a no-project filter"
    assert_equal [ "hive", "status", "--json" ], result.command_argv
  end

  def test_status_with_json_flag_and_project_filters_and_sets_format_json
    result = @handlers.status(Update.new(text: "/status --json hive"))

    assert_equal :json, result.format
    assert_equal "hive", result.project
    assert_equal [ "hive", "status", "--json", "--project", "hive" ], result.command_argv
  end
end
