require "test_helper"
require "json"
require "hive/commands/brainstorm_suggestion"
require "hive/brainstorm_suggestions/envelope"
require "hive/brainstorm_suggestions/store"
require_relative "../../fixtures/brainstorm_suggestions/pre_feature_parser"

class HiveCommandsBrainstormSuggestionTest < Minitest::Test
  include HiveTestHelper

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

  def test_cleanup_restores_the_exact_pre_feature_parser_view
    Dir.mktmpdir do |root|
      task = File.join(root, "2-brainstorm", "task-1")
      FileUtils.mkdir_p(task)
      baseline = <<~MARKDOWN
        ## Round 1
        ### Q1. Unanswered?
        ### A1.
        ### Q2. Answered?
        ### A2.
        Operator answer
        <!-- WAITING -->
      MARKDOWN
      envelope = Hive::BrainstormSuggestions::Envelope.render(
        binding: "d" * 64, text: "Advisory candidate"
      )
      polluted = baseline.sub("### A1.\n", "### A1.\n#{envelope}")
      path = File.join(task, "brainstorm.md")
      File.write(path, polluted)
      Hive::BrainstormSuggestions::Store.new(task).write("records" => [])

      expected = PreFeatureBrainstormParser.parse_text(baseline)
      before_cleanup = PreFeatureBrainstormParser.parse_text(polluted)
      refute_equal expected.map(&:answer), before_cleanup.map(&:answer)

      receipt = Hive::Commands::BrainstormSuggestion.new(
        "cleanup", task_roots: [ task ], json: true, output: StringIO.new
      ).call
      actual = PreFeatureBrainstormParser.parse_text(File.read(path))

      assert receipt.fetch("safe_to_disable")
      assert_equal expected.map(&:answer), actual.map(&:answer)
      assert_equal expected.all?(&:answered?), actual.all?(&:answered?)
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

  def test_usage_validation_rejects_bad_actions_and_incomplete_candidate_requests
    assert_raises(Hive::UsageError) do
      Hive::Commands::BrainstormSuggestion.new("retry", question: "bad")
    end
    assert_raises(Hive::UsageError) do
      Hive::Commands::BrainstormSuggestion.new("unknown", task_roots: []).call
    end
    assert_raises(Hive::UsageError) do
      Hive::Commands::BrainstormSuggestion.new("retry", task_roots: []).call
    end
    assert_raises(Hive::InvalidTaskPath) do
      Hive::Commands::BrainstormSuggestion.new(
        "retry", target: "missing", task_roots: [], question: 1,
        binding: "a" * 64, json: true, output: StringIO.new
      ).call
    end
  end

  def test_invalid_state_plain_output_and_candidate_lock_contention_are_advisory
    Dir.mktmpdir do |root|
      task = File.join(root, "2-brainstorm", "task-1")
      FileUtils.mkdir_p(task)
      File.write(File.join(task, "brainstorm.md"), "### Q1. Choose?\n### A1.\n")
      store = Hive::BrainstormSuggestions::Store.new(task)
      store.write("records" => [ fresh_record.merge("dismissed" => true) ])

      invalid = action("dismiss", task, binding: "b" * 64)
      assert_equal "invalid_state", invalid.fetch("status")

      output = StringIO.new
      restored = Hive::Commands::BrainstormSuggestion.new(
        "restore", target: task, task_roots: [ task ], question: 1,
        binding: "b" * 64, output: output
      ).call
      assert_equal "updated", restored.fetch("status")
      assert_includes output.string, "suggestion restore: updated"

      busy = Hive::Lock.with_task_lock(task, op: "operator") do
        action("retry", task, binding: "b" * 64)
      end
      assert_equal "lock_busy", busy.fetch("status")
    end
  end

  def test_cleanup_without_brainstorm_has_plain_receipt_and_sidecar_unlink_is_idempotent
    Dir.mktmpdir do |root|
      task = File.join(root, "task-1")
      FileUtils.mkdir_p(task)
      store = Hive::BrainstormSuggestions::Store.new(task)
      store.write("records" => [])
      output = StringIO.new

      receipt = Hive::Commands::BrainstormSuggestion.new(
        "cleanup", task_roots: [ task ], output: output
      ).call
      assert receipt.fetch("safe_to_disable")
      assert receipt.dig("tasks", 0, "parser_verified")
      assert_includes output.string, "cleanup: safe"

      store.write("records" => [])
      command = Hive::Commands::BrainstormSuggestion.new("cleanup", task_roots: [ task ])
      with_replaced_singleton_method(File, :unlink, ->(*) { raise Errno::ENOENT }) do
        refute command.send(:remove_sidecar, task)
      end
    end
  end

  def test_registered_task_discovery_filters_projects_and_ignores_races
    Dir.mktmpdir do |root|
      state = File.join(root, ".hive-state")
      task = File.join(state, "stages", "2-brainstorm", "task-1")
      raced = File.join(state, "stages", "2-brainstorm", "raced")
      FileUtils.mkdir_p(task)
      entry = { "name" => "demo", "hive_state_path" => state }
      other = { "name" => "other", "hive_state_path" => state }
      command = Hive::Commands::BrainstormSuggestion.new("cleanup", project: "demo")
      original_lstat = File.method(:lstat)

      with_replaced_singleton_method(Hive::Config, :registered_projects, -> { [ other, entry ] }) do
        with_replaced_singleton_method(Dir, :glob, ->(*) { [ task, raced ] }) do
          replacement = lambda do |path|
            raise Errno::ENOENT, "raced" if path == raced

            original_lstat.call(path)
          end
          with_replaced_singleton_method(File, :lstat, replacement) do
            assert_equal [ task ], command.send(:registered_task_roots)
            assert_equal [ task ], command.send(:discover_task_roots)
          end
        end
      end
    end
  end

  def test_cleanup_reports_an_unsafe_brainstorm_target
    Dir.mktmpdir do |root|
      task = File.join(root, "task-1")
      FileUtils.mkdir_p(task)
      target = File.join(root, "outside.md")
      File.write(target, "## Round 1\n")
      File.symlink(target, File.join(task, "brainstorm.md"))

      receipt = Hive::Commands::BrainstormSuggestion.new(
        "cleanup", task_roots: [ task ], json: true, output: StringIO.new
      ).call

      assert_equal "unsafe", receipt.dig("tasks", 0, "status")
      refute receipt.fetch("safe_to_disable")
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
