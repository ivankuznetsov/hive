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

  def test_binding_checked_dismiss_restore_and_retry_are_advisory_only
    Dir.mktmpdir do |root|
      task = File.join(root, "2-brainstorm", "task-1")
      FileUtils.mkdir_p(task)
      brainstorm = File.join(task, "brainstorm.md")
      File.write(brainstorm, "## Round 1\n### Q1. Choose?\n### A1.\n<!-- WAITING -->\n")
      before = Hive::BrainstormParser.parse(brainstorm).map(&:answer)
      store = Hive::BrainstormSuggestions::Store.new(task)
      store.write("records" => [ fresh_record ])

      dismissed = action("dismiss", task, binding: "b" * 64)
      assert_equal "updated", dismissed.fetch("status")
      assert Hive::BrainstormSuggestions::Store.new(task).read.dig("records", 0, "dismissed")

      restored = action("restore", task, binding: "b" * 64)
      assert_equal "updated", restored.fetch("status")
      refute Hive::BrainstormSuggestions::Store.new(task).read.dig("records", 0, "dismissed")

      retried = action("retry", task, binding: "b" * 64)
      record = Hive::BrainstormSuggestions::Store.new(task).read.fetch("records").first
      assert_equal "updated", retried.fetch("status")
      assert_equal "stale", record.fetch("state")
      assert_nil record.fetch("text")
      assert_equal before, Hive::BrainstormParser.parse(brainstorm).map(&:answer)
      assert_includes File.read(brainstorm), "<!-- WAITING -->"
    end
  end

  def test_candidate_action_rejects_stale_binding_without_mutation
    Dir.mktmpdir do |root|
      task = File.join(root, "2-brainstorm", "task-1")
      FileUtils.mkdir_p(task)
      File.write(File.join(task, "brainstorm.md"), "## Round 1\n### Q1. Choose?\n### A1.\n")
      store = Hive::BrainstormSuggestions::Store.new(task)
      store.write("records" => [ fresh_record ])
      before = File.binread(store.path)

      result = action("retry", task, binding: "f" * 64)

      assert_equal "stale", result.fetch("status")
      assert_equal "binding_mismatch", result.fetch("reason")
      assert_equal before, File.binread(store.path)
    end
  end

  private

  def action(name, task, binding:)
    Hive::Commands::BrainstormSuggestion.new(
      name,
      target: task,
      task_roots: [ task ],
      question: 1,
      binding: binding,
      json: true,
      output: StringIO.new,
      clock: -> { Time.utc(2026, 8, 30, 12, 0, 0) }
    ).call
  end

  def fresh_record
    {
      "question_id" => "question-1",
      "ordinal" => 1,
      "round" => 1,
      "question_number" => 1,
      "question_fingerprint" => "a" * 64,
      "input_binding" => "a" * 64,
      "suggestion_binding" => "b" * 64,
      "state" => "fresh",
      "text" => "Advisory candidate",
      "rationale" => "Repository evidence supports it.",
      "provenance" => [ "repository" ],
      "safe_reason" => nil,
      "retryable" => true,
      "dismissed" => false,
      "attempt_id" => "attempt-1",
      "candidate_id" => "candidate-1",
      "requested_at" => "2026-08-30T11:59:00Z",
      "updated_at" => "2026-08-30T11:59:00Z",
      "next_retry_at" => nil,
      "automatic_attempts" => 1,
      "input_epoch" => "a" * 64,
      "error_code" => nil
    }
  end
end
