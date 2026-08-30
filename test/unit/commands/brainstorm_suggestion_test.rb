require "test_helper"
require "json"
require "hive/commands/brainstorm_suggestion"
require "hive/brainstorm_suggestions/envelope"
require "hive/brainstorm_suggestions/store"

class HiveCommandsBrainstormSuggestionTest < Minitest::Test
  def test_cleanup_is_idempotent_and_preserves_parser_visible_answers
    Dir.mktmpdir do |root|
      task = File.join(root, "2-brainstorm", "task-1")
      FileUtils.mkdir_p(task)
      binding = "d" * 64
      path = File.join(task, "brainstorm.md")
      File.write(path, <<~MARKDOWN)
        ## Round 1
        ### Q1. Unanswered?
        ### A1.
        #{Hive::BrainstormSuggestions::Envelope.render(binding: binding, text: "Candidate")}
        ### Q2. Answered?
        ### A2.
        Operator answer
        <!-- WAITING -->
      MARKDOWN
      store = Hive::BrainstormSuggestions::Store.new(task)
      store.write("records" => [])
      before = Hive::BrainstormParser.parse(path).map(&:answer)
      output = StringIO.new

      receipt = Hive::Commands::BrainstormSuggestion.new(
        "cleanup", task_roots: [ task ], json: true, output: output
      ).call
      second = Hive::Commands::BrainstormSuggestion.new(
        "cleanup", task_roots: [ task ], json: true, output: StringIO.new
      ).call

      assert_equal true, receipt.fetch("safe_to_disable")
      assert_equal 1, receipt.fetch("envelopes_removed")
      assert_equal before, Hive::BrainstormParser.parse(path).map(&:answer)
      refute File.exist?(store.path)
      refute_includes File.read(path), "hive-suggestion:v1"
      assert_equal 0, second.fetch("envelopes_removed")
      assert_equal receipt.fetch("schema"), JSON.parse(output.string).fetch("schema")
    end
  end

  def test_cleanup_reports_lock_contention_as_unsafe
    Dir.mktmpdir do |root|
      task = File.join(root, "task-1")
      FileUtils.mkdir_p(task)
      File.write(File.join(task, "brainstorm.md"), "## Round 1\n")

      receipt = Hive::Lock.with_task_lock(task, op: "test") do
        Hive::Commands::BrainstormSuggestion.new(
          "cleanup", task_roots: [ task ], json: true, output: StringIO.new
        ).call
      end

      assert_equal false, receipt.fetch("safe_to_disable")
      assert_equal "lock_busy", receipt.fetch("tasks").first.fetch("status")
    end
  end
end
